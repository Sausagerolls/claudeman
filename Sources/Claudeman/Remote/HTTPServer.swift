import ClaudemanKit
import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // lower-cased names
    let body: Data

    var bearerToken: String? {
        guard let value = headers["authorization"], value.lowercased().hasPrefix("bearer ") else { return nil }
        return String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }
}

struct HTTPResponse {
    var status: Int
    var body: Data
    var contentType = "application/json"
    /// Images are immutable per id, so clients may cache them.
    var cacheable = false

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let data = (try? encoder.encode(value)) ?? Data()
        return HTTPResponse(status: status, body: data)
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        json(["error": message], status: status)
    }

    var reason: String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        default: "Error"
        }
    }
}

private let encoder = RemoteAPI.makeEncoder()

/// Minimal HTTP/1.1 server on Network.framework: one request per connection, small JSON bodies.
/// It also advertises itself over Bonjour so the iOS app can find it on the local network.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    enum State: Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 64 * 1024
    private static let maxUploadBytes = RemoteAPI.maxAttachmentBytes

    private let queue = DispatchQueue(label: "claudeman.remote.server")
    private var listener: NWListener?
    private let handler: Handler
    private let onStateChange: @Sendable (State) -> Void

    init(handler: @escaping Handler, onStateChange: @escaping @Sendable (State) -> Void) {
        self.handler = handler
        self.onStateChange = onStateChange
    }

    func start(port: UInt16, serviceName: String) {
        stop()
        onStateChange(.starting)
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                onStateChange(.failed("Invalid port \(port)."))
                return
            }
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.service = NWListener.Service(name: serviceName, type: RemoteAPI.bonjourType)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.onStateChange(.listening(port: listener.port?.rawValue ?? port))
                case .failed(let error):
                    self?.onStateChange(.failed(error.localizedDescription))
                    listener.cancel()
                case .cancelled:
                    break
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onStateChange(.failed(error.localizedDescription))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onStateChange(.stopped)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
        // Drop connections that never send a full request (generous enough for photo uploads).
        queue.asyncAfter(deadline: .now() + 90) { [weak connection] in
            if let connection, connection.state != .cancelled { connection.cancel() }
        }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch Self.parse(buffer) {
            case .complete(let request):
                Task {
                    let response = await self.handler(request)
                    self.send(response, on: connection)
                }
            case .tooLarge:
                self.send(.error("Request too large.", status: 413), on: connection)
            case .invalid:
                self.send(.error("Malformed request.", status: 400), on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += response.cacheable ? "Cache-Control: private, max-age=604800\r\n" : "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private enum ParseResult {
        case incomplete, invalid, tooLarge
        case complete(HTTPRequest)
    }

    private static func parse(_ buffer: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            return buffer.count > maxHeaderBytes ? .tooLarge : .incomplete
        }
        guard headerEnd.lowerBound <= maxHeaderBytes,
              let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let rawPath = String(requestLine[1])
        let pathAndQuery = rawPath.split(separator: "?", maxSplits: 1).map(String.init)
        let path = pathAndQuery.first ?? rawPath

        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        guard length <= (path.hasSuffix("/attachments") ? maxUploadBytes : maxBodyBytes) else { return .tooLarge }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= length else { return .incomplete }

        var query: [String: String] = [:]
        if pathAndQuery.count == 2 {
            for item in URLComponents(string: "?" + pathAndQuery[1])?.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }
        }
        return .complete(HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: path,
            query: query,
            headers: headers,
            body: buffer.subdata(in: bodyStart..<(bodyStart + length))
        ))
    }
}
