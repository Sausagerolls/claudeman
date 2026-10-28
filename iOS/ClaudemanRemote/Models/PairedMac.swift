import Foundation
import Security

/// A Mac this device has paired with. The bearer token lives in the Keychain, keyed by `id`.
struct PairedMac: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: UInt16

    var baseURL: URL? {
        // Bracket IPv6 literals so they form a valid URL authority.
        let authority = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(authority):\(port)")
    }

    var address: String { "\(host):\(port)" }
}

enum Keychain {
    private static let service = "com.sausagerolls.claudeman.remote.token"

    static func token(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for id: UUID) {
        deleteToken(for: id)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func deleteToken(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class MacStore: ObservableObject {
    @Published private(set) var macs: [PairedMac] = [] {
        didSet { save() }
    }

    private let key = "pairedMacs"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([PairedMac].self, from: data) {
            macs = decoded
        }
        #if DEBUG
        seedFromLaunchArguments()
        #endif
    }

    #if DEBUG
    /// Development aid: `-seedMac <name> <host> <port> <token>` pre-pairs a Mac (debug builds only).
    private func seedFromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-seedMac"), args.count > index + 4,
              let port = UInt16(args[index + 3]) else { return }
        let mac = PairedMac(name: args[index + 1], host: args[index + 2], port: port)
        if !macs.contains(where: { $0.address == mac.address }) { add(mac, token: args[index + 4]) }
    }
    #endif

    func add(_ mac: PairedMac, token: String) {
        Keychain.setToken(token, for: mac.id)
        macs.append(mac)
    }

    func update(_ mac: PairedMac) {
        guard let index = macs.firstIndex(where: { $0.id == mac.id }) else { return }
        macs[index] = mac
    }

    func remove(_ mac: PairedMac) {
        Keychain.deleteToken(for: mac.id)
        macs.removeAll { $0.id == mac.id }
    }

    func client(for mac: PairedMac) -> RemoteClient? {
        guard let url = mac.baseURL else { return nil }
        return RemoteClient(baseURL: url, token: Keychain.token(for: mac.id))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(macs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
