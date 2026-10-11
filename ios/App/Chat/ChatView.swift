import FluxKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Chat destination: 1 thread of what happens between this iPhone and
/// the computers in scope, with the newest at the bottom. The computers
/// write on the leading side: agents, approvals, pair requests, received
/// files, and the last clip. What this iPhone sent shows on the trailing
/// side. An agent that waits shows its choices, and an approval shows Deny
/// and Approve, in the thread. The dock under it shows the clipboard of
/// this iPhone with Send, the tools, and a field for text or a link. A
/// choice that rejects the action of an agent turns the field into a reply
/// to that agent. It follows the Chat of Flux for Android.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var filesTarget: DeviceSnapshot?
    @State private var pickingFiles = false
    @State private var photosTarget: DeviceSnapshot?
    @State private var pickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    /// A reply that went to an agent: the computer, the pane, and the number
    /// of the last reply of the computer before it. A refused reply shows as a message.
    @State private var told: Told?
    @State private var menu = ThumbMenu()
    /// True after the chat showed once that a swipe leads to the other tabs.
    @AppStorage("swipeHinted") private var swipeHinted = false
    @State private var nudge: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Told: Equatable {
        var deviceId: String
        var pane: String
        var seq: Int
    }

    var body: some View {
        let all = model.inboxItems()
        let scoped = Inbox.inScope(all, scope: model.scope)
        let entries = model.chatEntries(all: all)
        let sent: [SentItem] = entries.compactMap { if case .sent(let s) = $0 { return s } else { return nil } }
        let running: [FileTransfer] = entries.compactMap {
            if case .file(let t) = $0, t.state == .running, t.size > 0 { return t } else { return nil }
        }
        let paired = model.state.devices.contains { $0.paired }
        let online = model.state.devices.filter { $0.paired && $0.online }.map(\.id)
        let herdr = model.core.plugin(HerdrPlugin.self)
        let toldReply = told.flatMap { herdr?.model.replies[$0.deviceId] }
        VStack(spacing: 0) {
            ProgressLine {
                if !running.isEmpty {
                    let size = running.reduce(Int64(0)) { $0 + $1.size }
                    let done = running.reduce(Int64(0)) { $0 + $1.bytes }
                    LineFill(fraction: Double(done) / Double(max(size, 1)), color: tn.accent)
                }
            }
            // A swipe on the thread leads to the next tab. The dock takes no swipe, so the field keeps its drags.
            if !model.state.enabled || !paired {
                ChatEmpty()
                    .tabSwipe()
            } else {
                ChatThread(entries: entries, scoped: scoped, all: all)
                    .tabSwipe()
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        ChatDock(sent: sent, menu: menu, onText: sendText, onReply: sendReply)
                    }
            }
        }
        // The thumb menu lies over the thread and the dock. The key and the items have their frames in this space,
        // so the space holds the overlay too.
        .overlay {
            if model.state.enabled && paired { ThumbMenuOverlay(menu: menu, sections: sections) }
        }
        .coordinateSpace(.named(thumbMenuSpace))
        .offset(x: nudge)
        .destinationRoot("Chat", context: paired ? ChatTexts.context(model, needs: Inbox.needsYou(scoped)) : "")
        // Chat has no tab bar. The thumb menu, the dots, and a swipe lead to the other tabs.
        // Before the first pairing, the chat has no dock, so the tab bar stays.
        .toolbar(model.state.enabled && paired ? .hidden : .automatic, for: .tabBar)
        .onChange(of: model.tab) { _, _ in menu.close() }
        .onChange(of: model.chatReply) { _, _ in menu.close() }
        // Once, the chat moves a little to the side and back, to show that a swipe leads to the other tabs.
        .task {
            guard !swipeHinted, !reduceMotion, paired else { return }
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            withAnimation(.easeOut(duration: 0.35)) { nudge = -56 }
            // A cancel during the move still brings the chat back.
            do { try await Task.sleep(for: .milliseconds(380)) } catch {
                nudge = 0
                return
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { nudge = 0 }
            swipeHinted = true
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if paired { ScopeChip() }
                Menu {
                    Button { pickPhotos() } label: { Label("Send photos", systemImage: "photo.on.rectangle") }
                    Button { open(canCamera, "Send from the camera to") { .cameraMode($0, .signature) } } label: {
                        Label(CameraMode.signature.label, systemImage: CameraMode.signature.systemImage)
                    }
                    Button { open(SendTools.canShare(model), "Show the queue and the transfers of") { .share($0) } } label: {
                        Label("Queue and transfers", systemImage: "tray.full")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More ways to send")
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            guard let d = filesTarget else { return }
            switch result {
            case .success(let urls): ShareFeature.send(picked: urls, to: d, model: model)
            case .failure(let error): model.show("Cannot open the files: \(error.localizedDescription)")
            }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, matching: .any(of: [.images, .videos]))
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            if let d = photosTarget { ShareFeature.send(photos: picked, to: d, model: model) }
            photos = []
        }
        .onChange(of: all.map(\.key), initial: true) {
            model.inboxChanged(all: all)
        }
        // The computers send their changes. Each visit asks again for the agents.
        .task(id: online) {
            guard !model.demo else { return }
            for d in model.state.devices where d.paired && d.online && d.accepts(PacketType.fluxHerdr) {
                herdr?.request(d.id)
            }
        }
        .onChange(of: toldReply) { _, r in
            guard let t = told, let r, r.pane == t.pane, r.action == "prompt", r.seq > t.seq, !r.sending else { return }
            if let error = r.error { model.show(error) }
            told = nil
        }
    }

    /// The sections of the thumb menu: the tools, and the other tabs nearest the thumb.
    private var sections: [ThumbSection] {
        [
            ThumbSection(title: "Files and camera", items: tools.map { ThumbItem(icon: $0.icon, label: $0.label, name: $0.name, enabled: $0.enabled, run: $0.action) }),
            ThumbSection(title: "Go to", items: [
                ThumbItem(icon: "slider.horizontal.3", label: "Control", name: "Go to Control") { model.select(.control) },
                ThumbItem(icon: "laptopcomputer", label: "Computers", name: "Go to Computers") { model.select(.computers) },
            ], wide: true),
        ]
    }

    /// The 6 tools of the thumb menu.
    private var tools: [ChatDockTool] {
        let share = SendTools.canShare(model)
        let browse = canBrowse
        let camera = canCamera
        return [
            ChatDockTool(icon: "doc.badge.arrow.up", label: "Send files", name: "Send files", enabled: TargetRun.enabled(model, can: share)) {
                TargetRun.run(model, can: share, title: "Send files to") { d in
                    filesTarget = d
                    pickingFiles = true
                }
            },
            ChatDockTool(icon: "folder", label: "Get files", name: "Get files from the computer", enabled: TargetRun.enabled(model, can: browse)) {
                open(browse, "Get files from") { .browse($0) }
            },
            ChatDockTool(icon: CameraMode.photo.systemImage, label: "Photo", name: CameraMode.photo.hint, enabled: TargetRun.enabled(model, can: camera)) {
                open(camera, "Send from the camera to") { .cameraMode($0, .photo) }
            },
            ChatDockTool(icon: CameraMode.document.systemImage, label: "Scan", name: CameraMode.document.hint, enabled: TargetRun.enabled(model, can: camera)) {
                open(camera, "Send from the camera to") { .cameraMode($0, .document) }
            },
            ChatDockTool(icon: CameraMode.text.systemImage, label: "Text", name: CameraMode.text.hint, enabled: TargetRun.enabled(model, can: camera)) {
                open(camera, "Send from the camera to") { .cameraMode($0, .text) }
            },
            ChatDockTool(icon: CameraMode.qr.systemImage, label: "QR", name: CameraMode.qr.hint, enabled: TargetRun.enabled(model, can: camera)) {
                open(camera, "Send from the camera to") { .cameraMode($0, .qr) }
            },
        ]
    }

    private func pickPhotos() {
        TargetRun.run(model, can: SendTools.canShare(model), title: "Send photos to") { d in
            photosTarget = d
            pickingPhotos = true
        }
    }

    /// Sends text or a link from the field. A web link opens in the browser
    /// of the computer, and other text goes to its clipboard.
    private func sendText(_ text: String) {
        TargetRun.run(model, can: SendTools.canShare(model), title: "Send to") { d in
            if model.demo {
                model.show(DemoMode.sendsNothing)
                return
            }
            guard text.utf8.count <= ShareQueue.maxTextBytes else {
                model.show("The text is larger than 1 MB. Send it as a file")
                return
            }
            model.core.plugin(SharePlugin.self)?.send(text: text, to: d.id)
        }
    }

    /// Sends the reply of the dock to its agent, after Face ID or the
    /// passcode: the choice that rejects the action, then the text as the
    /// next prompt, see `HerdrPlugin.tell`. A new question in the time of
    /// the check takes no reply that the user wrote for the old one.
    private func sendReply(_ text: String) {
        guard let r = model.chatReply else { return }
        if model.demo {
            model.show(DemoMode.sendsNothing)
            model.chatReply = nil
            return
        }
        ReplyLock.run(reason: "Answer agents on \(r.computer).", action: {
            guard let plugin = model.core.plugin(HerdrPlugin.self) else { return }
            guard model.chatReply == r, plugin.model.prompt(r.deviceId, pane: r.pane)?.lines == r.lines else {
                model.chatReply = nil
                model.show("The question changed. Read it, then answer again.")
                return
            }
            told = Told(deviceId: r.deviceId, pane: r.pane, seq: plugin.model.replies[r.deviceId]?.seq ?? 0)
            ChatAnswers.shared.sent(text, r.deviceId, pane: r.pane, lines: r.lines)
            plugin.tell(r.deviceId, pane: r.pane, keys: r.choice.keys, text: text)
            model.chatReply = nil
        }, onError: { model.show($0) })
    }

    /// The computers that open their files, see `BrowseTile`.
    private var canBrowse: (DeviceSnapshot) -> Bool {
        let has = model.core.plugin(BrowsePlugin.self) != nil
        return { has && $0.accepts(PacketType.sftpRequest) }
    }

    /// The computers that take the camera modes, see `CameraTile`.
    private var canCamera: (DeviceSnapshot) -> Bool {
        return { $0.accepts(PacketType.share) }
    }

    /// Opens the screen of `route` for the computer of the tool.
    private func open(_ can: (DeviceSnapshot) -> Bool, _ title: String, _ route: @escaping (String) -> FeatureRoute) {
        TargetRun.run(model, can: can, title: title) { d in
            model.chatPath.append(.feature(route(d.id)))
        }
    }
}

// MARK: Thread

/// The entries of the chat with the day over each new day, the newest at
/// the bottom, and the notices under them. The view starts at the newest
/// entry and follows a new entry while it shows the end. When the user
/// scrolls up, it stays there, unless this iPhone sent the new entry.
/// Without entries, a line tells what shows here.
private struct ChatThread: View {
    let entries: [ChatEntry]
    let scoped: [InboxItem]
    let all: [InboxItem]
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    /// True while the end of the thread is on screen.
    @State private var atEnd = true

    var body: some View {
        let many = model.scope == nil && model.paired.count > 1
        GeometryReader { geo in
            // The width of the content, inside the side space of 12 pt.
            let inner = max(0, min(geo.size.width, TiledMetrics.maxContentWidth) - 24)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        if entries.isEmpty {
                            Text("Agents that need you, approvals, and files from your computers show here. So do the links, text, and files that you send.")
                                .font(.footnote)
                                .foregroundStyle(tn.sub)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                        }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                            if i == 0 || !Calendar.current.isDate(entries[i - 1].at, inSameDayAs: entry.at) {
                                Text(ThreadTime.day(entry.at))
                                    .font(.caption)
                                    .foregroundStyle(tn.sub)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 2)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ChatRow(entry: entry, width: inner, many: many)
                        }
                        ChatNotices(scoped: scoped, all: all)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                            .background(GeometryReader { g in
                                Color.clear.preference(key: ChatEndKey.self, value: g.frame(in: .named("chat")).minY)
                            })
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .padding(.bottom, 14)
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

/// 1 entry of the chat. `width` is the width of the content of the thread.
private struct ChatRow: View {
    let entry: ChatEntry
    let width: CGFloat
    let many: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let name: (String) -> String = { id in model.device(id)?.name ?? "the computer" }
        switch entry {
        case .sent(let s):
            if s.kind == .clipImage {
                SentFileCard(icon: "photo", name: "Image", meta: SendMeta.sent(s, many: many, name: name), state: .done, fraction: nil)
            } else {
                SentBubble(text: s.text.isEmpty ? "A private clip" : s.text, meta: SendMeta.sent(s, many: many, name: name), width: width)
            }
        case .file(let t):
            if t.incoming {
                ReceivedFileCard(transfer: t, width: width)
            } else {
                SentFileCard(icon: SendMeta.fileIcon(t.name), name: t.name, meta: SendMeta.file(t, many: many, name: name), state: t.state, fraction: t.fraction)
            }
        case .clip(let c):
            ClipCard(clip: c, width: width)
        case .answer(let r):
            AnswerCard(record: r, width: width)
        case .event(let item, let at):
            switch item.content {
            case .agent(let deviceId, let agent, let control):
                ChatAgentCard(item: item, deviceId: deviceId, agent: agent, control: control, at: at, width: width, many: many)
            case .approval(let r):
                ApprovalCard(item: item, request: r, at: at, width: width)
            case .pair(let deviceId):
                PairCard(item: item, deviceId: deviceId, at: at, width: width)
            }
        }
    }
}
