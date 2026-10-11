import FluxKit
import SwiftUI
import UserNotifications

/// The texts of the chat about the computers in scope.
@MainActor
enum ChatTexts {
    /// The name of the computer in scope, or nil for all computers.
    static func scopeName(_ model: AppModel) -> String? {
        model.scope.flatMap { model.device($0)?.name }
    }

    /// The context line of the chat, such as "omarchy · 2 need you". With
    /// all computers in scope, the scope chip names the scope, so the line
    /// gives only the count.
    static func context(_ model: AppModel, needs: Int) -> String {
        let count = needs > 0 ? "\(needs) need you" : "nothing needs you"
        return scopeName(model).map { "\($0) · \(count)" } ?? count
    }

    /// The title of the computers in scope while the links connect.
    nonisolated static func connecting(_ reach: InboxReach) -> String {
        reach.offline.count == 1 ? "Connecting to \(reach.offline[0].name)" : "Connecting to your computers"
    }

    /// The line for the computers in scope that are not reachable.
    nonisolated static func offlineLine(_ reach: InboxReach) -> String {
        if reach.offline.count == 1, let d = reach.offline.first {
            return "\(d.name) is not reachable. Its agents do not show here."
        }
        return "\(reach.offline.count) computers are not reachable. Their agents do not show here."
    }

    /// True when the chat tells that computers in scope are not reachable.
    /// While the links connect after a start, the chat does not say it.
    static func offlineShows(_ model: AppModel) -> Bool {
        !model.connecting && !Inbox.reach(scope: model.scope, devices: model.state.devices).offline.isEmpty
    }

    /// The name of the computer that paired last, while the chat shows it.
    static func newlyPaired(_ model: AppModel) -> String? {
        guard let id = model.newlyPairedId, model.scope == nil || model.scope == id else { return nil }
        return model.device(id)?.name
    }
}

/// What the chat tells under its entries: that the links connect, a new
/// pairing, the items on other computers that need the user, the computers
/// in scope that are not reachable, and the notifications.
struct ChatNotices: View {
    let scoped: [InboxItem]
    let all: [InboxItem]
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @AppStorage("inbox.notificationsHidden") private var notificationsHidden = false

    var body: some View {
        let elsewhere = Inbox.needsYou(all) - Inbox.needsYou(scoped)
        let reach = Inbox.reach(scope: model.scope, devices: model.state.devices)
        let status = NotificationAccess.shared.status
        let asks = !model.demo && !notificationsHidden && model.state.devices.contains { $0.paired }
        VStack(alignment: .leading, spacing: 4) {
            if model.connecting && reach.noneOnline {
                HStack(spacing: 10) {
                    FluxSpinner(size: 16)
                    Text(ChatTexts.connecting(reach))
                        .font(.footnote)
                        .foregroundStyle(tn.sub)
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
            }
            if let name = ChatTexts.newlyPaired(model) {
                Notice(mark: .paired, text: "\(name) is paired. What waits for you on \(name) shows here first.", strong: true) {
                    EmptyView()
                }
            }
            if elsewhere > 0 {
                Notice(mark: .needs, text: elsewhere == 1 ? "1 item on another computer needs you"
                    : "\(elsewhere) items on other computers need you", strong: true) {
                    Button("Show all computers") { model.setScope(nil) }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
            if ChatTexts.offlineShows(model) {
                Notice(mark: .offline, text: ChatTexts.offlineLine(reach), strong: false) {
                    Button("Retry") { model.retry() }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
            if asks && status == .notDetermined {
                Notice(mark: .bell, text: "Allow notifications, so that Flux can show when an agent needs you.", strong: false) {
                    Button("Allow") { NotificationAccess.shared.ask() }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                    Button("Hide") { notificationsHidden = true }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            } else if asks && status == .denied {
                Notice(mark: .bell, text: "Notifications are off for Flux, so sudo approvals and agent alerts do not reach this iPhone. Turn them on in the Settings app.", strong: false) {
                    Button("Open Settings") { NotificationAccess.shared.turnOn(model: model) }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                    Button("Hide") { notificationsHidden = true }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
        }
    }
}

/// The mark of a notice.
enum NoticeMark {
    case paired, needs, offline, bell
}

/// 1 notice: a mark, the text, and the actions under the text. The actions
/// go under each other at a large text size.
struct Notice<Actions: View>: View {
    let mark: NoticeMark
    let text: String
    /// True for `text`, false for `sub`.
    let strong: Bool
    @ViewBuilder let actions: Actions
    @Environment(\.tn) private var tn

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            markView
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(strong ? tn.text : tn.sub)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) { actions }
                    VStack(alignment: .leading, spacing: 0) { actions }
                }
                // The text of the first button lines up with the text above.
                .padding(.leading, -12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .paired:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(tn.green).accessibilityHidden(true)
        case .needs:
            Circle().fill(tn.red).frame(width: 8, height: 8).accessibilityHidden(true)
        case .offline:
            LinkDot(online: false)
        case .bell:
            Image(systemName: "bell.badge").foregroundStyle(tn.yellow).accessibilityHidden(true)
        }
    }
}
