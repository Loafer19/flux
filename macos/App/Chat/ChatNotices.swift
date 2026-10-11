import Accessibility
import AppKit
import FluxKit
import SwiftUI

/// The texts of the context line and the notices of the chat.
struct ChatStatus: Equatable {
    /// The items in scope that need the user.
    let needs: Int
    /// The items out of scope that need the user.
    let elsewhere: Int
    /// The computer in scope, or nil for all computers.
    let scopeName: String?
    /// The computers in scope that are not reachable, while Flux does not connect.
    let offline: [String]
    /// The computer that Flux connects to, or "" for more computers, while
    /// no computer in scope is online. It is nil when Flux does not connect.
    let connecting: String?
    /// The computer that paired in the last 6 seconds, when the scope shows it.
    let pairedName: String?

    /// "omarchy-xps · 2 need you". With all computers in scope, only the
    /// count shows, because the scope menu names the scope.
    var context: String {
        let count = needs > 0 ? "\(needs) need you" : "nothing needs you"
        return contextLine([scopeName ?? "", count])
    }

    /// "omarchy is not reachable. Its agents do not show here." or the form for more computers.
    var offlineLine: String? {
        switch offline.count {
        case 0: return nil
        case 1: return "\(offline[0]) is not reachable. Its agents do not show here."
        default: return "\(offline.count) computers are not reachable. Their agents do not show here."
        }
    }

    @MainActor
    static func make(_ model: AppModel, all: [InboxItem], scoped: [InboxItem]) -> ChatStatus {
        let reach = Inbox.reach(scope: model.scope, devices: model.state.devices)
        let needs = Inbox.needsYou(scoped)
        var paired: String?
        if let id = model.newlyPairedId, model.scope == nil || model.scope == id {
            paired = model.pairedDevice(id)?.name
        }
        var connecting: String?
        if reach.noneOnline && model.connecting {
            connecting = reach.offline.count == 1 ? reach.offline[0].name : ""
        }
        return ChatStatus(
            needs: needs,
            elsewhere: Inbox.needsYou(all) - needs,
            scopeName: model.pairedDevice(model.scope)?.name,
            offline: model.connecting ? [] : reach.offline.map(\.name),
            connecting: connecting,
            pairedName: paired
        )
    }
}

/// The notices under the entries of the chat: that Flux connects, a new
/// pairing, the items on other computers that need the user, the computers
/// that are not reachable, and the Local Network permission. Flux for macOS
/// has no notification notice.
struct ChatNotices: View {
    let status: ChatStatus
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let localNetworkOff = model.state.localNetworkDenied && !model.state.devices.contains(where: \.online)
        VStack(spacing: TiledMetrics.gap) {
            if let name = status.connecting {
                HStack(spacing: 10) {
                    FluxSpinner(size: 14)
                    Text(name.isEmpty ? "Connecting to your computers" : "Connecting to \(name)")
                        .font(.system(size: 12))
                        .foregroundStyle(tn.sub)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .accessibilityElement(children: .combine)
            }
            if let name = status.pairedName {
                NoticeRow(icon: "checkmark.circle", ink: tn.green, text: "\(name) is paired. What waits for you on \(name) shows here first.")
                    .onAppear {
                        let text: String = "\(name) is paired. What waits for you on \(name) shows here first."
                        AccessibilityNotification.Announcement(text).post()
                    }
            }
            if status.elsewhere > 0 {
                NoticeRow(dot: tn.red, text: status.elsewhere == 1
                    ? "1 item on another computer needs you"
                    : "\(status.elsewhere) items on other computers need you") {
                    Button("Show all computers") { model.setScope(nil) }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
            if let offline = status.offlineLine {
                NoticeRow(ring: true, text: offline) {
                    Button("Retry") { model.retry() }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
            if localNetworkOff {
                NoticeRow(icon: "wifi.exclamationmark", ink: tn.yellow, text: LocalNetworkNotice.text) {
                    Button("Open System Settings") { NSWorkspace.shared.open(LocalNetworkNotice.settings) }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
        }
    }
}

/// 1 notice: a mark, the text, and the actions at the end of the row.
private struct NoticeRow<Actions: View>: View {
    var icon: String?
    var ink: Color?
    var dot: Color?
    var ring = false
    let text: String
    let actions: Actions
    @Environment(\.tn) private var tn

    init(icon: String? = nil, ink: Color? = nil, dot: Color? = nil, ring: Bool = false, text: String,
         @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.ink = ink
        self.dot = dot
        self.ring = ring
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(ink ?? tn.sub)
                } else if let dot {
                    Circle().fill(dot).frame(width: 8, height: 8)
                } else if ring {
                    LinkDot(online: false)
                }
            }
            .frame(width: 18)
            .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tn.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous).fill(tn.offTile))
        .overlay(RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous).strokeBorder(tn.line, lineWidth: 1))
    }
}

extension NoticeRow where Actions == EmptyView {
    init(icon: String? = nil, ink: Color? = nil, dot: Color? = nil, ring: Bool = false, text: String) {
        self.init(icon: icon, ink: ink, dot: dot, ring: ring, text: text) { EmptyView() }
    }
}
