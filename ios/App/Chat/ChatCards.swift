import FluxKit
import Observation
import SwiftUI

// The cards of the chat: the cards of the computers on the leading side,
// and the bubbles and file cards of this iPhone on the trailing side. They
// follow the Inbox Send 3b design and the Chat of Flux for Android.

// MARK: Card of a computer

/// The text action at the bottom of a card, such as Open thread. Without
/// `run`, the label only tells a state, such as "Writing a reply below".
struct ChatCardAction {
    let label: String
    var run: (() -> Void)?
}

/// A card from a computer, on the leading side: the mark and the state in
/// `color`, the source in mono, and the time at the end. The title and the
/// detail follow, then the progress bar, `extra`, and the action. A card
/// that needs the user (`ask`) takes the full `width` and a red border of
/// 2 pt. The other cards take 88% of it. `mono` sets the title in mono,
/// for a file name or a clip. VoiceOver reads the top row as 1 line.
struct ChatCard<Mark: View, Extra: View>: View {
    let state: String
    let color: Color
    let source: String
    let time: Date
    let title: String
    let mono: Bool
    let detail: String
    let ask: Bool
    let progress: Double?
    let action: ChatCardAction?
    let titleLines: Int?
    let width: CGFloat
    let mark: Mark
    let extra: Extra
    @Environment(\.tn) private var tn

    init(state: String, color: Color, source: String, time: Date, title: String, mono: Bool = false, detail: String = "",
         ask: Bool = false, progress: Double? = nil, action: ChatCardAction? = nil, titleLines: Int? = nil, width: CGFloat,
         @ViewBuilder mark: () -> Mark, @ViewBuilder extra: () -> Extra) {
        self.state = state
        self.color = color
        self.source = source
        self.time = time
        self.title = title
        self.mono = mono
        self.detail = detail
        self.ask = ask
        self.progress = progress
        self.action = action
        self.titleLines = titleLines
        self.width = width
        self.mark = mark()
        self.extra = extra()
    }

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 4, bottomTrailingRadius: 14, topTrailingRadius: 14, style: .continuous)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    mark
                    Text(state)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                    if !source.isEmpty {
                        Text("· " + source)
                            .font(.caption.monospaced())
                            .foregroundStyle(tn.sub)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(ThreadTime.clock(time))
                        .font(.caption2.monospaced())
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([state, source, ThreadTime.clock(time)].filter { !$0.isEmpty }.joined(separator: ", "))
                Text(title)
                    .font(mono ? .subheadline.monospaced().weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(tn.text)
                    .lineLimit(titleLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(tn.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let progress {
                    ZStack(alignment: .leading) {
                        Capsule().fill(tn.line)
                        LineFill(fraction: progress, color: tn.accent).clipShape(Capsule())
                    }
                    .frame(height: 3)
                    .padding(.top, 2)
                }
                extra
                if let action {
                    // The action reaches into the padding of the card, as in the design, and takes taps on 44 pt.
                    Group {
                        if let run = action.run {
                            Button(action: run) {
                                Text(action.label)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(action.label).frame(minHeight: 44)
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tn.accent)
                    .padding(.top, -6)
                    .padding(.bottom, -12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: ask ? width : width * 0.88, alignment: .leading)
            .background(shape.fill(tn.tile))
            .overlay(shape.strokeBorder(ask ? tn.red : tn.line, lineWidth: ask ? 2 : 1))
            Spacer(minLength: 0)
        }
    }
}

extension ChatCard where Extra == EmptyView {
    init(state: String, color: Color, source: String, time: Date, title: String, mono: Bool = false, detail: String = "",
         ask: Bool = false, progress: Double? = nil, action: ChatCardAction? = nil, titleLines: Int? = nil, width: CGFloat,
         @ViewBuilder mark: () -> Mark) {
        self.init(state: state, color: color, source: source, time: time, title: title, mono: mono, detail: detail, ask: ask,
                  progress: progress, action: action, titleLines: titleLines, width: width, mark: mark) { EmptyView() }
    }
}

/// A button of a card that needs the user, 48 pt high: `primary` has the
/// accent fill, the other the tonal fill.
private struct CardButton: View {
    let label: String
    var icon: String?
    let primary: Bool
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.body)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(primary ? tn.onAccent : tn.text)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(tileShape(12).fill(primary ? tn.accent : tn.line))
            .contentShape(tileShape(12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Agent

/// An agent: what it waits for, what it works on, or that it is done.
///
/// The one-tap rule: a choice never answers a question that the user did
/// not see. The card reads the output when it shows, and only an output
/// that came after that read shows choices. The question keeps the lines
/// nearest the choices, because they hold the command that a choice
/// approves, and the card never cuts them. Each answer asks for Face ID or
/// the passcode first. After an answer, the choices stay off until a new
/// output comes, so that a second tap does not answer the next question. A
/// choice that rejects the action opens a reply in the dock. `at` is the
/// start of the status.
struct ChatAgentCard: View {
    let item: InboxItem
    let deviceId: String
    let agent: HerdrAgent
    let control: Bool
    let at: Date
    let width: CGFloat
    let many: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.scenePhase) private var scenePhase
    /// True after this card asked the computer for the output.
    @State private var didRead = false
    /// The output that the last answer answered.
    @State private var answered: HerdrOutput?
    @State private var lockError: String?
    /// The number of the last reply before this card answered. The card
    /// shows only the replies that it sent.
    @State private var sentAfter: Int?
    /// True after Flux left the screen, until it comes back. The Face ID
    /// prompt makes Flux inactive, so only the background counts.
    @State private var wasAway = false
    /// Counts the returns of Flux to the screen.
    @State private var visit = 0

    private struct ReadKey: Equatable {
        var key: String
        var visit: Int
    }

    var body: some View {
        let plugin = model.core.plugin(HerdrPlugin.self)
        let out: HerdrOutput? = model.demo ? DemoMode.output(pane: agent.pane, review: false) : plugin?.model.prompt(deviceId, pane: agent.pane)
        let blocked = agent.status == .blocked
        let working = agent.status == .working
        let fresh = model.demo || (didRead && out?.loading == false && out?.error == nil)
        let replying = model.chatReply.map { $0.deviceId == deviceId && $0.pane == agent.pane } ?? false
        let choices: [AgentChoice] = blocked && fresh && !replying ? out?.choices ?? [] : []
        let texts = out?.lines.map(\.text)
        let ask = texts.flatMap { AgentAsk.find($0, maxLines: 4) }
        let prompt = ask == nil ? texts.map { Inbox.agentPrompt($0, maxLines: 4) } ?? "" : ""
        let thread = !blocked && fresh ? texts.map(AgentThread.parse) : nil
        let reply = ownReply(plugin)
        let sending = reply?.sending == true
        let since = model.demo ? DemoMode.since(pane: agent.pane) : plugin?.model.agentSince(device: deviceId, pane: agent.pane)
        let source = (item.sourceParts + (many ? [item.computer] : [])).joined(separator: " · ")
        let openThread = ChatCardAction(label: "Open thread", run: { model.chatPath.append(.feature(.agent(deviceId, agent.pane))) })
        let action: ChatCardAction? = replying ? ChatCardAction(label: "Writing a reply below") : (choices.isEmpty ? openThread : nil)
        // A working agent shows its time, so its card draws again each second.
        TimelineView(.periodic(from: .now, by: working ? 1 : 3600)) { context in
            ChatCard(state: item.stateWord, color: tn.tone(item.tone), source: source, time: at, title: item.title,
                     detail: detail(thread: thread, since: since, now: context.date), ask: blocked, action: action, width: width) {
                StatusMark(status: agent.status)
            } extra: {
                if blocked {
                    question(out: out, fresh: fresh, ask: ask, prompt: prompt)
                    actions(out: out, choices: choices, problem: lockError ?? reply?.error, sending: sending)
                }
            }
        }
        // The card reads the output when it shows, and again when Flux comes
        // back from the background, because the question can change. A
        // working agent shows its step from the output.
        .task(id: ReadKey(key: item.key, visit: visit)) {
            guard blocked || working, !model.demo else { return }
            model.core.plugin(HerdrPlugin.self)?.readPrompt(deviceId, pane: agent.pane)
            didRead = true
        }
        .onChange(of: agent.status, initial: true) { _, status in
            ChatAnswers.shared.status(status, deviceId, pane: agent.pane)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { wasAway = true }
            if phase == .active, wasAway {
                wasAway = false
                visit += 1
            }
        }
    }

    /// The question of a waiting agent: an error, lines while the output
    /// loads, or the question and the command. The command has no line
    /// limit, because a choice approves it.
    @ViewBuilder
    private func question(out: HerdrOutput?, fresh: Bool, ask: AgentAsk?, prompt: String) -> some View {
        if let error = out?.error, out?.loading == false {
            Text(error)
                .font(.caption)
                .foregroundStyle(tn.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if !fresh {
            LineSkeleton(widths: [0.8, 0.55], label: "Reading the question")
                .padding(.vertical, 3)
        } else if let ask {
            if !ask.command && !ask.question.isEmpty {
                Text(ask.question)
                    .font(.footnote)
                    .foregroundStyle(tn.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !ask.lines.isEmpty {
                Text(ask.lines.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(tn.sub)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !prompt.isEmpty {
            Text(prompt)
                .font(.caption.monospaced())
                .foregroundStyle(tn.sub)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The choices of a waiting agent, a problem, the note about
    /// herdr_control, and the state of a reply that goes out.
    @ViewBuilder
    private func actions(out: HerdrOutput?, choices: [AgentChoice], problem: String?, sending: Bool) -> some View {
        if !choices.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(choices.enumerated()), id: \.element.id) { i, c in
                    AskChoiceButton(choice: c, primary: i == 0, enabled: control && !sending && out != answered && out?.lines != ChatAnswers.shared.told(deviceId, pane: agent.pane), minHeight: 44) {
                        answer(c, out: out)
                    }
                }
            }
            .padding(.top, 6)
        }
        if let problem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(tn.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !control {
            Text("To answer from this iPhone, set herdr_control = true on \(item.computer).")
                .font(.caption)
                .foregroundStyle(tn.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        if sending {
            HStack(spacing: 8) {
                RingSpinner(size: 14)
                Text("Sending")
                    .font(.caption)
                    .foregroundStyle(tn.sub)
            }
        }
    }

    /// The line under the title: the answer that the chat sent, the step,
    /// and the time of a working agent. A finished agent reads no output, so
    /// it shows its work time only in the demo.
    private func detail(thread: AgentThread?, since: Date?, now: Date) -> String {
        switch agent.status {
        case .blocked:
            return ""
        case .working:
            let answer = ChatAnswers.shared.answer(deviceId, pane: agent.pane).map { "You answered: \($0)" } ?? ""
            let elapsed = since.map { AgentTime.when(.working, since: $0, now: now) } ?? thread?.elapsed ?? ""
            let line = [answer, thread?.step ?? "", elapsed].filter { !$0.isEmpty }.joined(separator: " · ")
            return line.isEmpty ? "Working" : line
        default:
            let done = doneText(thread?.worked ?? "")
            return done == "Done" ? "Waits for the next prompt" : done
        }
    }

    /// The last reply to the agent, when this card sent it.
    private func ownReply(_ plugin: HerdrPlugin?) -> HerdrReply? {
        guard let after = sentAfter, let r = plugin?.model.reply(deviceId, pane: agent.pane), r.seq > after else { return nil }
        return r
    }

    /// Sends the keys of the choice, after Face ID or the passcode. A choice
    /// that rejects the action opens a reply in the dock in its place.
    private func answer(_ choice: AgentChoice, out: HerdrOutput?) {
        if Chat.isTellChoice(choice) {
            model.chatReply = ChatReply(deviceId: deviceId, pane: agent.pane, agent: agent.agent,
                                        project: agent.project.isEmpty ? agent.workspace : agent.project,
                                        computer: item.computer, choice: choice, lines: out?.lines ?? [])
            return
        }
        if model.demo {
            model.show(DemoMode.sendsNothing)
            return
        }
        lockError = nil
        let pane = agent.pane
        let id = deviceId
        ReplyLock.run(reason: "Answer agents on \(item.computer).", action: {
            guard let plugin = model.core.plugin(HerdrPlugin.self) else { return }
            // The check can take some seconds. A new question in that time
            // takes no answer that the user gave to the old one.
            guard let shown = out, plugin.model.prompt(id, pane: pane)?.lines == shown.lines else {
                lockError = "The question changed. Read it, then answer again."
                return
            }
            answered = out
            sentAfter = plugin.model.replies[id]?.seq ?? 0
            ChatAnswers.shared.sent(choice.label, id, pane: pane)
            plugin.sendKeys(id, pane: pane, choice.keys)
        }, onError: { lockError = $0 })
    }
}

/// The answers that the chat sent to the agents, by computer and pane. An
/// answer shows on the card of the agent while the agent works on it, for
/// 10 minutes at most. The card of an agent changes when its status
/// changes, so the answers live here and not in the card.
@MainActor
@Observable
final class ChatAnswers {
    static let shared = ChatAnswers()

    private struct Entry {
        var text: String
        var lines: [TermLine] = []
        var working = false
        var at = Date()
    }

    private var entries: [String: Entry] = [:]

    /// Keeps the answer `text` to the agent in `pane`. `lines` are the lines
    /// of the question that a reply answered.
    func sent(_ text: String, _ deviceId: String, pane: String, lines: [TermLine] = []) {
        entries[deviceId + "|" + pane] = Entry(text: text, lines: lines)
    }

    /// The lines of the question that a reply of the chat answered, or nil.
    /// The choices of that question stay off until the agent shows another
    /// question, so that 1 tap does not answer it again.
    func told(_ deviceId: String, pane: String) -> [TermLine]? {
        guard let e = entries[deviceId + "|" + pane], !e.lines.isEmpty else { return nil }
        return e.lines
    }

    /// The answer to show for the agent in `pane`, or nil.
    func answer(_ deviceId: String, pane: String) -> String? {
        guard let e = entries[deviceId + "|" + pane], e.working, Date().timeIntervalSince(e.at) < 600 else { return nil }
        return e.text
    }

    /// The agent in `pane` has a new status. The answer shows while the
    /// agent works, and goes when the agent stops working.
    func status(_ status: AgentStatus, _ deviceId: String, pane: String) {
        let key = deviceId + "|" + pane
        guard let e = entries[key] else { return }
        if status == .working {
            if !e.working { entries[key]?.working = true }
        } else if e.working {
            entries[key] = nil
        }
    }
}

// MARK: Approval and pairing

/// The user and the terminal of a request, such as "user dev · pts/3".
private func approvalLine(_ r: ApproveRequest) -> String {
    ["user \(r.user)", r.tty].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " · ")
}

/// A sudo, polkit, or enrollment request, with Deny and Approve. Approve
/// opens the approval sheet, which asks for Face ID or Touch ID. It never
/// approves by itself.
struct ApprovalCard: View {
    let item: InboxItem
    let request: ApproveRequest
    let at: Date
    let width: CGFloat
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        // Deny and Approve share the width 1 to 1.6, as in the design.
        let inner = max(0, width - 24 - 8)
        ChatCard(state: item.stateWord, color: tn.red, source: request.service, time: at, title: item.title,
                 detail: approvalLine(request), ask: true, width: width) {
            PulseDot(color: tn.red, size: 8)
        } extra: {
            HStack(spacing: 8) {
                CardButton(label: "Deny", primary: false) {
                    if model.demo {
                        model.show(DemoMode.sendsNothing)
                    } else if let plugin = model.core.plugin(ApprovePlugin.self), plugin.model.current?.id == request.id {
                        // Deny acts on the open request, so it must be the request of this card.
                        plugin.deny()
                    }
                }
                .frame(width: inner / 2.6)
                .accessibilityHint("Denies the request")
                CardButton(label: request.kind == .approve ? "Approve" : "Enroll", icon: ApproveTexts.current.symbol, primary: true) {
                    if model.demo {
                        model.show(DemoMode.sendsNothing)
                    } else {
                        ApprovePresenter.shared.state.present()
                    }
                }
                .accessibilityHint("Opens the approval")
            }
            .padding(.top, 6)
        }
    }
}

/// A computer that asks to pair. Compare the key opens the pairing sheet
/// with the full key. It never pairs by itself.
struct PairCard: View {
    let item: InboxItem
    let deviceId: String
    let at: Date
    let width: CGFloat
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        ChatCard(state: item.stateWord, color: tn.red, source: "", time: at, title: item.title,
                 detail: "Compare the key on both screens.", ask: true, width: width) {
            PulseDot(color: tn.red, size: 8)
        } extra: {
            CardButton(label: "Compare the key", primary: true) { model.pairingSheet = deviceId }
                .padding(.top, 6)
        }
    }
}

/// The answer of this iPhone to a request: Approved or Denied.
struct AnswerCard: View {
    let record: ApproveRecord
    let width: CGFloat
    @Environment(\.tn) private var tn

    var body: some View {
        let ok = record.outcome == .approved || record.outcome == .enrolled
        let r = record.request
        let color = ok ? tn.green : tn.sub
        ChatCard(state: ok ? "Approved" : "Denied", color: color, source: r?.service ?? "", time: record.resolved ?? record.received,
                 title: title(ok: ok, r), detail: r.map(approvalLine) ?? "", width: width) {
            PulseDot(color: color, size: 8, pulse: false)
        }
    }

    private func title(ok: Bool, _ r: ApproveRequest?) -> String {
        guard let r else { return record.summary }
        if r.kind == .enroll {
            return ok ? "Enrolled \(FluxPlatform.current.deviceNoun) on \(r.host)" : "Denied the enrollment on \(r.host)"
        }
        return (ok ? "Approved " : "Denied ") + "\(r.service) for \(r.user)"
    }
}

// MARK: Files and clips of the computers

/// A file from a computer: its progress while it comes in, then Open, which
/// shows it with Quick Look.
struct ReceivedFileCard: View {
    let transfer: FileTransfer
    let width: CGFloat
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let t = transfer
        let name = model.device(t.deviceId)?.name ?? "the computer"
        switch t.state {
        case .running:
            ChatCard(state: "Receiving", color: tn.accent, source: name, time: t.started, title: t.name, mono: true,
                     detail: t.fraction.map { "\(Int($0 * 100))% of \(TransferRow.bytes(t.size))" } ?? "\(TransferRow.bytes(t.bytes)) so far",
                     progress: t.fraction, width: width) {
                RingSpinner(size: 11, color: tn.accent)
            }
        case .done:
            ChatCard(state: "Received", color: tn.green, source: name, time: t.started, title: t.name, mono: true, detail: "In Files",
                     action: t.file.map { file in ChatCardAction(label: "Open", run: { ShareFeature.shared.preview = file }) }, width: width) {
                PulseDot(color: tn.green, size: 8, pulse: false)
            }
        case .failed:
            ChatCard(state: "Not received", color: tn.red, source: name, time: t.started, title: t.name, mono: true,
                     detail: "Send it again from \(name)", width: width) {
                PulseDot(color: tn.red, size: 8, pulse: false)
            }
        }
    }
}

/// The last clip from a computer. It is on the clipboard of this iPhone
/// already, and the chat keeps only a short preview, so the card has no Copy.
struct ClipCard: View {
    let clip: ClipEvent
    let width: CGFloat
    @Environment(\.tn) private var tn

    var body: some View {
        let c = clip
        ChatCard(state: "Clipboard", color: tn.cyan, source: c.computer, time: c.at,
                 title: c.image ? "An image" : (c.secret ? ClipEvent.hiddenText : c.preview),
                 mono: !c.image && !c.secret, titleLines: 4, width: width) {
            PulseDot(color: tn.cyan, size: 8, pulse: false)
        }
    }
}

// MARK: What this iPhone sent

/// Text, a link, or a clip that went out: a bubble at the trailing side in
/// mono, at most 82% of `width`, with the meta line under it.
struct SentBubble: View {
    let text: String
    let meta: String
    let width: CGFloat
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous)
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(.footnote.monospaced())
                    .foregroundStyle(tn.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(shape.fill(tn.accentTile))
                    .overlay(shape.strokeBorder(tn.lineHi, lineWidth: 1))
                Text(meta)
                    .font(.caption2)
                    .foregroundStyle(tn.sub)
            }
            .frame(maxWidth: width * 0.82, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A file or an image clip that went out: a card of 236 pt at the trailing
/// side with its icon, its name, the meta line, and a bar while it runs.
struct SentFileCard: View {
    let icon: String
    let name: String
    let meta: String
    let state: FileTransfer.State
    let fraction: Double?
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14, style: .continuous)
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 19))
                        .foregroundStyle(tn.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.footnote.monospaced().weight(.medium))
                            .foregroundStyle(tn.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(meta)
                            .font(.caption)
                            .foregroundStyle(failed ? tn.red : tn.sub)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    mark
                }
                if state == .running {
                    ZStack(alignment: .leading) {
                        Capsule().fill(tn.line)
                        LineFill(fraction: fraction ?? 0, color: tn.accent).clipShape(Capsule())
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 236)
            .background(shape.fill(tn.accentTile))
            .overlay(shape.strokeBorder(tn.lineHi, lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch state {
        case .running: RingSpinner(size: 14, color: tn.accent)
        case .done: Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(tn.green)
        case .failed: Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(tn.red)
        }
    }

    private var failed: Bool {
        if case .failed = state { return true }
        return false
    }
}

/// The meta lines of what this iPhone sent. With `many` computers in scope,
/// the line names the computer. `name` gives the name of a computer.
@MainActor
enum SendMeta {
    static func sent(_ s: SentItem, many: Bool, name: (String) -> String) -> String {
        let time = ThreadTime.clock(s.at)
        switch s.kind {
        case .link: return many ? "Link · opened on \(name(s.deviceId)) · \(time)" : "Link · opened in the browser · \(time)"
        case .text: return many ? "Text · on the clipboard of \(name(s.deviceId)) · \(time)" : "Text · on the clipboard · \(time)"
        case .scan: return many ? "Scan · saved on \(name(s.deviceId)) · \(time)" : "Scan · saved as a text file · \(time)"
        case .clip, .clipImage: return many ? "Clipboard · to \(name(s.deviceId)) · \(time)" : "Clipboard · \(time)"
        }
    }

    static func file(_ t: FileTransfer, many: Bool, name: (String) -> String) -> String {
        let time = ThreadTime.clock(t.ended ?? t.started)
        let size = TransferRow.bytes(max(t.size, 0))
        let pct = t.fraction.map { "\(Int($0 * 100))% of \(size)" } ?? "\(TransferRow.bytes(t.bytes)) so far"
        switch t.state {
        case .running: return (many ? "Sending to \(name(t.deviceId))" : "Sending") + " · \(pct)"
        case .done: return (many ? "Sent to \(name(t.deviceId))" : "Sent") + " · \(time)"
        case .failed: return "Not sent · \(time)"
        }
    }

    /// The icon of a file: an image, or a document.
    static func fileIcon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "bmp"].contains(ext) ? "photo" : "doc.text"
    }
}
