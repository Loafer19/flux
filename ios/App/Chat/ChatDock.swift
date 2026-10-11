import FluxKit
import SwiftUI
import UIKit

/// A tool of the dock of the chat. `name` is the label for VoiceOver.
struct ChatDockTool: Identifiable {
    let icon: String
    let label: String
    let name: String
    var enabled = true
    let action: () -> Void

    var id: String { label }
}

/// The dock of the chat: the clipboard of this iPhone with Send, and the field for text or a link with the + key, the mic
/// key, and the send key. The + key opens the thumb `menu`. iOS asks before
/// an app reads the clipboard, so the dock shows only the kind of the copy,
/// and the text of a copy that went out from here. While a reply to an
/// agent is open, a row with Cancel takes the place of the clipboard, the +
/// key hides, and the field writes to the agent. `sent` tells whether the
/// copy went out already.
struct ChatDock: View {
    let sent: [SentItem]
    let menu: ThumbMenu
    let onText: (String) -> Void
    let onReply: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    /// The change count of the clipboard and the kind of the copy.
    @State private var clip = PhoneClip(count: 0, kind: .empty)
    @State private var voice = VoiceTyping()
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        let reply = model.chatReply
        VStack(spacing: 10) {
            if let reply {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(tn.accent)
                        .accessibilityHidden(true)
                    Text("Reply to \(reply.agent)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(tn.text)
                        .lineLimit(1)
                    if !reply.project.isEmpty {
                        Text("· \(reply.project)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(tn.sub)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Cancel") { model.chatReply = nil }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(tn.accent)
                        .buttonStyle(.borderless)
                        .frame(minHeight: 44)
                        .accessibilityHint("Closes the reply to the agent")
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 32)
            } else {
                clipRow
            }
            composer(reply)
            VoiceStatus(voice: voice)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .dockFrame()
        .onAppear { clip = PhoneClip.now() }
        .task { await voice.load() }
        // The field is gone, so the words of a dictation have no place.
        .onDisappear { voice.cancel() }
        .sheet(isPresented: $editing) {
            FieldEditor(title: reply.map { "Reply to \($0.agent)" } ?? "Text or a link", text: $text, actionLabel: "Send",
                        actionEnabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, onAction: send)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { clip = PhoneClip.now() } }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in clip = PhoneClip.now() }
        .task {
            // iOS posts no notice for a copy in another app, so the dock checks the change count while it shows.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let next = PhoneClip.now()
                if next != clip { clip = next }
            }
        }
        // A new reply starts with an empty field that has the focus.
        .onChange(of: reply) { _, r in
            text = ""
            focused = r != nil
        }
    }

    /// The clipboard of this iPhone and its Send key, 44 pt high. The box
    /// tells where the copy is, and shows its text on 1 line. After a send,
    /// the key shows Sent.
    private var clipRow: some View {
        let last = sent.last { clip.count != 0 && $0.clipStamp == clip.count && ($0.kind == .clip || $0.kind == .clipImage) }
        let canClip = TargetRun.enabled(model, can: SendTools.canClipboard(model)) && clip.kind != .empty
        let shown = last.map { !$0.text.isEmpty } ?? false
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(clipMeta(last))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tn.cyan)
                    .lineLimit(1)
                Text(clipText(last))
                    .font(shown ? .caption.monospaced() : .caption)
                    .foregroundStyle(shown ? tn.text : tn.sub)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tn.bg))
            .accessibilityElement(children: .combine)
            Button {
                if let last {
                    model.show("The clip is on \(model.device(last.deviceId)?.name ?? "the computer") already")
                } else {
                    SendTools.sendClipboard(model)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: last != nil ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 15, weight: .medium))
                    Text(last != nil ? "Sent" : "Send")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(last != nil ? tn.text : tn.onAccent)
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(last != nil ? tn.line : tn.accent))
            }
            .buttonStyle(.plain)
            .disabled(!canClip)
            .opacity(canClip ? 1 : TiledMetrics.disabledAlpha)
            .accessibilityLabel("Send the clipboard")
        }
        .frame(height: 44)
    }

    /// The + key, the field, the mic key, and the send key. While the field
    /// has the focus, the + key hides, so the field takes its width and
    /// grows to 6 lines. With text, the field shows the key of the large
    /// editor. While a reply is open, the field has the accent border and
    /// writes to the agent. The words of a dictation go at the end of the
    /// text.
    private func composer(_ reply: ChatReply?) -> some View {
        let can = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let placeholder: String = {
            if let reply { return "Tell \(reply.agent) what to do differently" }
            if let d = TargetRun.single(model) { return "Text or a link for \(d.name)" }
            return "Text or a link"
        }()
        return HStack(alignment: .bottom, spacing: 8) {
            if reply == nil && !focused && !voice.active {
                ThumbKey(menu: menu)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 0) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(focused ? 1...6 : 1...4)
                    .font(.subheadline)
                    .foregroundStyle(tn.text)
                    .textInputAutocapitalization(reply != nil ? TextInputAutocapitalization.sentences : TextInputAutocapitalization.never)
                    .autocorrectionDisabled(reply == nil)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .focused($focused)
                    .padding(.vertical, 13)
                // Only the key of the large editor shows, so the text keeps the width. The editor has Clear.
                if !text.isEmpty { ExpandKey(isPresented: $editing).padding(.bottom, 6) }
            }
            .padding(.leading, 16)
            .padding(.trailing, text.isEmpty ? 16 : 4)
            .frame(minHeight: 48)
            .background(Capsule().fill(tn.bg))
            .overlay(Capsule().strokeBorder(reply != nil || focused ? tn.accent : tn.lineHi, lineWidth: 1))
            if voice.available {
                Button {
                    voice.toggle(model.core) { spoken in text = DictationText.append(text, spoken) }
                } label: {
                    Image(systemName: voice.active ? "stop.fill" : "mic")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(voice.active ? tn.onAccent : tn.text)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(voice.active ? tn.green : tn.line))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voice.active ? "Stop the dictation" : "Dictate")
            }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(can ? tn.onAccent : tn.sub)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(can ? tn.accent : tn.line))
            }
            .buttonStyle(.plain)
            .disabled(!can)
            .accessibilityLabel("Send")
        }
        .animation(.snappy(duration: 0.2), value: focused)
        .animation(.snappy(duration: 0.2), value: voice.active)
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        editing = false
        // A reply keeps its text until it goes out, because Face ID can stop it. The end of the reply clears the field.
        if model.chatReply != nil {
            onReply(t)
        } else {
            onText(t)
            text = ""
        }
    }

    private func clipMeta(_ last: SentItem?) -> String {
        if let last { return "Clipboard · sent at \(ThreadTime.clock(last.at))" }
        switch clip.kind {
        case .empty: return "Clipboard on this iPhone · empty"
        case .text, .image: return "Clipboard on this iPhone"
        }
    }

    private func clipText(_ last: SentItem?) -> String {
        if let last, !last.text.isEmpty { return last.text }
        switch clip.kind {
        case .empty: return "Copy text or an image on this iPhone"
        case .image: return "An image"
        case .text: return "Text. Tap Send to paste it on the computer"
        }
    }
}

/// The kind of the copy on the clipboard of this iPhone, and its change
/// count. The checks do not read the copy, so iOS does not ask.
struct PhoneClip: Equatable {
    enum Kind: Equatable { case empty, text, image }

    let count: Int
    let kind: Kind

    @MainActor
    static func now() -> PhoneClip {
        let pb = UIPasteboard.general
        let kind: Kind = pb.hasImages && !pb.hasStrings ? .image : (pb.hasStrings || pb.hasURLs ? .text : .empty)
        return PhoneClip(count: pb.changeCount, kind: kind)
    }
}
