import SwiftUI

struct SessionTabBar: View {
    @EnvironmentObject private var model: AppModel
    let project: Project
    let sessions: [TerminalSession]
    let selectedID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sessions) { session in
                    SessionTab(session: session, isSelected: session.id == selectedID)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

private struct SessionTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    @State private var isHovering = false
    @State private var confirmClose = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            if session.remoteControlName != nil {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Remote Control on: continue this session in the Claude app as “\(session.remoteControlName ?? "")”")
            }
            Text(label)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
            Button {
                if session.isRunning && UserDefaults.standard.confirmCloseRunning { confirmClose = true } else { model.close(session) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close Session")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : (isHovering ? Color.primary.opacity(0.06) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(session) }
        .onHover { isHovering = $0 }
        .help(session.title.isEmpty ? session.name : session.title)
        .alert("End this session?", isPresented: $confirmClose) {
            Button("End Session", role: .destructive) { model.close(session) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Claude Code is still running in \(session.name).")
        }
    }

    private var label: String {
        let title = session.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? session.name : "\(session.name) · \(title)"
    }
}
