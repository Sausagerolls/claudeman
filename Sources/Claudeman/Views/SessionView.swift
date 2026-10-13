import SwiftUI

struct SessionView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: TerminalSession

    var body: some View {
        TerminalHostView(session: session)
            .overlay(alignment: .bottom) {
                if !session.isRunning {
                    endedBar
                        .padding(16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.isRunning)
    }

    private var endedBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "stop.circle")
            Text(endedMessage)
            Spacer()
            ForEach(LaunchMode.allCases) { mode in
                Button(mode.title) { model.restart(session, mode: mode) }
                    .keyboardShortcut(mode == .new ? .defaultAction : nil)
            }
            Button("Close") { model.close(session) }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
    }

    private var endedMessage: String {
        if let code = session.exitCode, code != 0 {
            return "Session ended (exit code \(code))"
        }
        return "Session ended"
    }
}
