import AppKit
import FluxKit
import SwiftUI
import UniformTypeIdentifiers

/// Chat: 1 thread of what happens between this Mac and the computers in
/// scope, with the newest entry at the bottom. The computers write on the
/// left: agents, approvals, pair requests, received files, the last clip,
/// and the answers to approvals. What this Mac sent shows on the right. An
/// agent that waits shows its choices in the thread, and an approval shows
/// Deny and Approve. The dock under the thread shows the clipboard of this
/// Mac with Send, the tools, and a field for text or a link. Files, text,
/// and links that you drop on the page go to the computer too. Before the
/// first pairing, the page shows the pairing guide.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var ask: TargetAsk?
    @State private var dropping = false

    var body: some View {
        let share = model.core.plugin(SharePlugin.self)
        let herdr = model.core.plugin(HerdrPlugin.self)
        let scope = model.scope
        let all = model.inboxItems()
        let scoped = Inbox.inScope(all, scope: scope)
        let status = ChatStatus.make(model, all: all, scoped: scoped)
        let transfers = share?.model.transfers ?? []
        let running = transfers.filter { $0.state == .running && $0.size > 0 && (scope == nil || $0.deviceId == scope) }
        let entries = Chat.entries(
            sent: share?.model.sent ?? [],
            transfers: transfers,
            clip: model.core.plugin(ClipboardPlugin.self)?.model.last,
            answers: model.core.plugin(ApprovePlugin.self)?.model.history ?? [],
            items: all,
            since: { herdr?.model.agentSince(device: $0, pane: $1) },
            seen: model.chatSeen(all),
            scope: scope
        )
        let online = model.connectedPaired.map(\.id)
        VStack(spacing: 0) {
            ProgressLine {
                if !running.isEmpty {
                    let size = running.reduce(Int64(0)) { $0 + $1.size }
                    let done = running.reduce(Int64(0)) { $0 + min($1.bytes, $1.size) }
                    LineFill(fraction: size > 0 ? Double(done) / Double(size) : 0, color: tn.accent)
                }
            }
            if model.paired.isEmpty {
                ScrollView {
                    ChatPairGuide()
                        .pageColumn(top: 12, bottom: 16)
                }
            } else {
                ChatThread(entries: entries, status: status) { share?.model.clearFinished() }
                ChatDock(ask: $ask)
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
                    .strokeBorder(tn.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: $dropping) { providers in
            guard let share, let id = ShareActions.target(model) else { return false }
            ShareActions.drop(providers, to: id, share: share)
            return true
        }
        .targetPicker($ask)
        .navigationSubtitle(model.paired.isEmpty ? "" : status.context)
        .destinationRoot(.chat)
        // The chat asks each computer that comes online for its agents.
        .task(id: online) {
            for id in online { herdr?.request(id) }
        }
    }
}

/// The entries with the day over each new day, the newest at the bottom,
/// and the notices under them. The view follows a new entry while it shows
/// the end. When the user scrolls up, it stays there, unless this Mac sent
/// the new entry. The column is at most the content width, so that the
/// cards stay easy to read in a wide window.
private struct ChatThread: View {
    let entries: [ChatEntry]
    let status: ChatStatus
    let clearFinished: () -> Void
    @Environment(\.tn) private var tn
    /// True while the end of the thread is on screen.
    @State private var atEnd = true

    var body: some View {
        GeometryReader { geo in
            let column = max(240, min(geo.size.width, TiledMetrics.maxContentWidth) - 28)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        Spacer(minLength: 0)
                        if entries.isEmpty {
                            Text("Agents that need you, approvals, and files from your computers show here. So do the links, text, and files that you send. To send files from Finder, drop them on this page or on the Dock icon, or select Services > Send to Flux.")
                                .font(.system(size: 12))
                                .foregroundStyle(tn.sub)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 24)
                        }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                            if i == 0 || !Calendar.current.isDate(entries[i - 1].at, inSameDayAs: e.at) {
                                Text(dayText(e.at))
                                    .font(.system(size: 11))
                                    .foregroundStyle(tn.sub)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 2)
                            }
                            ChatEntryView(entry: e, clearFinished: clearFinished)
                        }
                        ChatNotices(status: status)
                        Color.clear.frame(height: 1).id("end")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: ChatEndKey.self, value: g.frame(in: .named("chat")).minY)
                            })
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 16)
                    .environment(\.chatColumn, column)
                    .frame(maxWidth: TiledMetrics.maxContentWidth)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .bottom)
                }
                .coordinateSpace(name: "chat")
                .defaultScrollAnchor(.bottom)
                .onPreferenceChange(ChatEndKey.self) { y in atEnd = y <= geo.size.height + 48 }
                .onChange(of: entries.last?.id) {
                    let mine: Bool
                    if case .sent = entries.last { mine = true } else if case .file(let t) = entries.last { mine = !t.incoming } else { mine = false }
                    if atEnd || mine { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }
}

/// The top of the end mark of the thread in the coordinate space of the scroll view.
private struct ChatEndKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 1 entry of the chat.
private struct ChatEntryView: View {
    let entry: ChatEntry
    let clearFinished: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let many = model.scope == nil && model.paired.count > 1
        switch entry {
        case .sent(let s):
            if s.kind == .clipImage {
                SentFileCard(icon: "photo", name: "Image", meta: sentMeta(s, many: many), state: .done)
            } else {
                SentBubble(text: s.text.isEmpty ? "A private clip" : s.text, meta: sentMeta(s, many: many))
            }
        case .file(let f):
            if f.incoming {
                ReceivedFileCard(transfer: f, computer: name(f.deviceId), clearFinished: clearFinished)
            } else {
                SentFileCard(icon: fileSymbol(f.name), name: f.name, meta: fileMeta(f, many: many), state: f.state,
                             fraction: f.fraction, file: f.file, clearFinished: clearFinished)
            }
        case .clip(let c):
            ReceivedClipCard(clip: c)
        case .answer(let r):
            AnswerCard(record: r)
        case .event(let item, let at):
            EventCard(item: item, at: at)
        }
    }

    private func name(_ deviceId: String) -> String {
        model.state.devices.first { $0.id == deviceId }?.name ?? "the computer"
    }

    /// The line under a link, a text, or a clip, such as "Link · opened in the browser · 13:20".
    /// With `many` computers in scope, it names the computer.
    private func sentMeta(_ s: SentItem, many: Bool) -> String {
        let time = clockTime(s.at)
        switch s.kind {
        case .link: return many ? "Link · opened on \(name(s.deviceId)) · \(time)" : "Link · opened in the browser · \(time)"
        case .text: return many ? "Text · on the clipboard of \(name(s.deviceId)) · \(time)" : "Text · on the clipboard · \(time)"
        case .scan: return many ? "Scan · saved on \(name(s.deviceId)) · \(time)" : "Scan · saved as a text file · \(time)"
        case .clip, .clipImage: return many ? "Clipboard · to \(name(s.deviceId)) · \(time)" : "Clipboard · \(time)"
        }
    }

    /// The line under a file that went out, such as "Sending · 22% of 18 KB" or "Sent · 13:41".
    private func fileMeta(_ f: FileTransfer, many: Bool) -> String {
        let to = name(f.deviceId)
        let pct = f.fraction.map { "\(Int($0 * 100))% of \(byteText(f.size))" } ?? "\(byteText(f.bytes)) so far"
        let time = clockTime(f.ended ?? f.started)
        switch f.state {
        case .running: return (many ? "Sending to \(to)" : "Sending") + " · \(pct)"
        case .done: return (many ? "Sent to \(to)" : "Sent") + " · \(time)"
        case .failed: return "Not sent · \(time)"
        }
    }

    /// The symbol of a file: an image, or a document.
    private func fileSymbol(_ name: String) -> String {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        return type?.conforms(to: .image) == true ? "photo" : "doc.text"
    }
}
