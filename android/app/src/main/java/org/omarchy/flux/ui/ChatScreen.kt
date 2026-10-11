package org.omarchy.flux.ui

import android.app.DownloadManager
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.util.Calendar
import kotlinx.coroutines.flow.drop
import org.omarchy.flux.BuildConfig
import org.omarchy.flux.R
import org.omarchy.flux.camera.CameraMode
import org.omarchy.flux.core.AgentChoice
import org.omarchy.flux.core.AgentItem
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.ApprovalItem
import org.omarchy.flux.core.Approvals
import org.omarchy.flux.core.ApproveRequest
import org.omarchy.flux.core.ChatEventItem
import org.omarchy.flux.core.ChatItem
import org.omarchy.flux.core.ChatLogItem
import org.omarchy.flux.core.DebugDemo
import org.omarchy.flux.core.DebugFirstRun
import org.omarchy.flux.core.DebugInbox
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.HerdrOutput
import org.omarchy.flux.core.HerdrSync
import org.omarchy.flux.core.InboxFeed
import org.omarchy.flux.core.InboxItem
import org.omarchy.flux.core.InboxKind
import org.omarchy.flux.core.PairItem
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.core.SEND_TEXT_MAX
import org.omarchy.flux.core.SeenClock
import org.omarchy.flux.core.SendEntry
import org.omarchy.flux.core.SendKind
import org.omarchy.flux.core.SendLog
import org.omarchy.flux.core.Share
import org.omarchy.flux.core.Target
import org.omarchy.flux.core.TermLine
import org.omarchy.flux.core.TransferState
import org.omarchy.flux.core.UiState
import org.omarchy.flux.core.agentAsk
import org.omarchy.flux.core.agentPrompt
import org.omarchy.flux.core.agentThread
import org.omarchy.flux.core.chatItems
import org.omarchy.flux.core.choicesOpen
import org.omarchy.flux.core.inScope
import org.omarchy.flux.core.inboxItems
import org.omarchy.flux.core.isTellChoice
import org.omarchy.flux.core.target

/**
 * The agents, the approval, and the pair requests of all computers. A
 * debug build with the demo adds the sample approval of [DebugInbox].
 */
@Composable
fun rememberChatEvents(state: UiState): List<InboxItem> {
    val approval by Approvals.current.collectAsStateWithLifecycle()
    // The first run and the pairing success state of a debug build show no samples.
    val demo = BuildConfig.DEBUG && DebugDemo.on && DebugFirstRun.mode == DebugFirstRun.Mode.Off
    return remember(state.devices, approval, demo) {
        inboxItems(state.devices, approval ?: if (demo) DebugInbox.approval() else null)
    }
}

/**
 * What the chat and its notices do: open screens, the approval screen,
 * and the pair sheet, pair a computer, show all computers, and ask for the
 * notifications. [pair] starts the pairing that this phone sends, as in
 * Computers.
 */
class ChatActions(
    val open: (Route) -> Unit,
    val approve: (ApproveRequest) -> Unit,
    val showPair: (String) -> Unit,
    val pair: (DeviceUi) -> Unit,
    val tools: SendTools,
    val showAll: () -> Unit,
    val allowNotifications: () -> Unit,
    val hideNotifications: () -> Unit,
)

/**
 * A reply that the dock writes to the agent in [pane] in the place of the
 * [choice] that rejects its action, such as "No, and tell Codex what to
 * do differently". [lines] are the output lines of the question that the
 * user read. The reply goes out only while the question is the same.
 */
private data class ChatReply(val deviceId: String, val pane: String, val agent: String, val project: String, val choice: AgentChoice, val lines: List<TermLine>)

/** The first time that the chat showed each item whose start is not known. It lives as long as the app process. */
private val seenClock = SeenClock()

/**
 * The answers that the chat sent to the agents, by computer and pane. An
 * answer shows on the card of the agent while the agent works on it. It
 * stays while the app runs, because the card of an agent changes when its
 * status changes.
 */
private val chatAnswers = mutableStateMapOf<String, SentAnswer>()

/**
 * The lines of the question that a reply of the chat answered, by computer
 * and pane. The choices of that question stay off until the agent shows
 * another question, so that 1 tap does not answer it again.
 */
private val toldLines = mutableStateMapOf<String, List<TermLine>>()

/**
 * The Chat destination: 1 thread of what happens between this phone and
 * the computers in scope, with the newest at the bottom. The computers
 * write on the left: agents, approvals, pair requests, received files, and
 * clips. What this phone sent shows on the right. An agent that waits
 * shows its choices, and an approval shows Approve and Deny, in the
 * thread. The dock under it shows the clipboard of this phone with Send,
 * the tools, and a field for text or a link. A choice that rejects the
 * action of an agent turns the field into a reply to that agent.
 *
 * [all] are the Inbox items of all computers. [active] is false while
 * the screen moves, so that it reads nothing new then. [notices] tell what
 * the thread cannot show.
 */
@Composable
fun ChatScreen(
    state: UiState,
    all: List<InboxItem>,
    active: Boolean,
    notices: InboxNotices,
    actions: ChatActions,
    scope: String?,
    onScope: (String?) -> Unit,
    picker: TargetPicker,
) {
    val devices = state.devices
    val context = LocalContext.current
    // The computers send their changes. A new visit asks again for the agents.
    LaunchedEffect(active) {
        if (!active) return@LaunchedEffect
        for (d in devices) {
            if (d.paired && d.online && !isDemo(d.id) && d.herdrSupported) HerdrSync.request(FluxCore, d.id)
        }
    }
    val paired = devices.any { it.paired }
    val events = remember(all, scope) { all.inScope(scope) }
    val needs = events.count { it.kind.needsYou }
    // The scope chip names the scope, so the line names only a single computer, as the design does.
    val header = listOfNotNull(devices.firstOrNull { it.paired && it.id == scope }?.name, if (needs > 0) "$needs need you" else "nothing needs you").joinToString(" · ")

    val logged by SendLog.entries.collectAsStateWithLifecycle()
    // The first run and the pairing success state of a debug build show no samples.
    val demo = BuildConfig.DEBUG && DebugDemo.on && DebugFirstRun.mode == DebugFirstRun.Mode.Off
    val entries = remember(logged, demo, scope) {
        (if (demo) DebugInbox.sends() + logged else logged).filter { scope == null || it.deviceId == scope }.sortedBy { it.at }
    }
    // All computers keep their times, so that a change of the scope does not move an item.
    val seen = remember(all) { seenClock.update(all.map { it.key }, System.currentTimeMillis()) }
    val chat = remember(entries, events, seen, devices) {
        chatItems(entries, events, { id, pane -> devices.firstOrNull { it.id == id }?.agentSince?.get(pane) }, seen)
    }
    val running = entries.filter { it.kind == SendKind.File && it.state == TransferState.Running }

    // The dock writes to 1 agent while a reply is open. The reply ends when the agent no longer waits, and Back ends it.
    var reply by remember { mutableStateOf<ChatReply?>(null) }
    BackHandler(enabled = reply != null) { reply = null }
    LaunchedEffect(reply, events) {
        val r = reply ?: return@LaunchedEffect
        val waits = events.any { it is AgentItem && it.deviceId == r.deviceId && it.agent.pane == r.pane && it.kind == InboxKind.AgentInput }
        if (!waits) reply = null
    }
    // A reply that fluxd refused shows as a message. The number is the last reply of the computer before it.
    var told by remember { mutableStateOf<Triple<String, String, Long>?>(null) }
    LaunchedEffect(told, devices) {
        val (id, pane, before) = told ?: return@LaunchedEffect
        val r = devices.firstOrNull { it.id == id }?.herdrReply ?: return@LaunchedEffect
        if (r.pane != pane || r.action != "prompt" || r.seq <= before || r.sending) return@LaunchedEffect
        r.error?.let { FluxCore.toast(it) }
        told = null
    }
    fun tell(r: ChatReply, text: String) {
        ReplyLock.run(context, {
            // The keys of the choice go out only while the agent shows the question that the user read.
            val now = devices.firstOrNull { it.id == r.deviceId }?.herdrOutput?.takeIf { it.pane == r.pane }?.lines
                ?: if (isDemo(r.deviceId)) r.lines else null
            if (reply != r || now != r.lines) {
                reply = null
                FluxCore.toast("The question changed. Read it, then answer again.")
                return@run
            }
            told = Triple(r.deviceId, r.pane, devices.firstOrNull { it.id == r.deviceId }?.herdrReply?.seq ?: 0L)
            chatAnswers["${r.deviceId}|${r.pane}"] = SentAnswer(text, "Reply", null)
            toldLines["${r.deviceId}|${r.pane}"] = r.lines
            HerdrSync.tell(FluxCore, r.deviceId, r.pane, r.choice.keys, text)
            reply = null
        }) { FluxCore.toast(it) }
    }

    Column(Modifier.fillMaxSize().imePadding()) {
        Box(Modifier.statusBarsPadding()) {
            ScreenHeader("Chat", if (paired) header else "") {
                if (paired) ScopeChip(devices, scope, onScope, Modifier.widthIn(max = 180.dp), compact = true)
            }
        }
        ProgressLine {
            if (running.isNotEmpty()) {
                val size = running.sumOf { it.size }
                LineFill(if (size > 0) running.sumOf { it.done }.toFloat() / size else 0f, Tn.blue)
            }
        }
        if (!paired) {
            Column(
                Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter).padding(top = 12.dp, bottom = 16.dp),
            ) { PairGuide(state, actions) }
            return@Column
        }
        val t = target(scope, devices)
        // Each computer reads the output of 1 agent at a time: the newest that waits, or else the newest that works.
        val focus = remember(chat) {
            chat.filterIsInstance<ChatEventItem>().map { it.item }.filterIsInstance<AgentItem>()
                .groupBy { it.deviceId }
                .mapNotNull { (_, agents) -> (agents.lastOrNull { it.kind == InboxKind.AgentInput } ?: agents.lastOrNull { it.kind == InboxKind.AgentWorking })?.key }
                .toSet()
        }
        DockLayout(
            Modifier.weight(1f).fillMaxWidth(),
            thread = { bottom ->
                ChatThread(
                    chat, bottom, devices, active, focus, many = scope == null && devices.count { it.paired } > 1,
                    reply = reply, notices = notices, actions = actions,
                    onReply = { reply = it },
                )
            },
            dock = { shape ->
                ChatDock(
                    shape, on = t !is Target.None, entries = entries, target = t, reply = reply,
                    tools = listOf(
                        DockTool(Ic.sendFiles, "Files", "Send files", actions.tools.sendFiles),
                        DockTool(Ic.folderOpen, "Get", "Get files from the computer") { picker.run(t, "Get files from") { actions.open(Route(it.id, "browse")) } },
                        DockTool(Ic.camera, "Photo", CameraMode.Photo.hint) { picker.run(t, "Send from the camera to") { actions.open(Route(it.id, "camera:photo")) } },
                        DockTool(Ic.document, "Scan", CameraMode.Document.hint) { picker.run(t, "Send from the camera to") { actions.open(Route(it.id, "camera:document")) } },
                        DockTool(Ic.text, "Text", CameraMode.Text.hint) { picker.run(t, "Send from the camera to") { actions.open(Route(it.id, "camera:text")) } },
                        DockTool(Ic.qr, "QR", CameraMode.Qr.hint) { picker.run(t, "Send from the camera to") { actions.open(Route(it.id, "camera:qr")) } },
                    ),
                    onClip = actions.tools.sendClipboard,
                    onText = { text -> picker.run(t, "Send to") { Share.sendText(FluxCore, it.id, text) } },
                    onReply = { text -> reply?.let { tell(it, text) } },
                    onCancel = { reply = null },
                )
            },
        )
    }
}

// ───────────────────────── Thread ─────────────────────────

/**
 * The entries of the chat with the day over each new day, the newest at
 * the bottom, and the notices under them. The view follows the end. When
 * the user scrolls up, the view stays there, unless this phone sent the
 * new entry.
 * [bottom] is the space under the last entry. [focus] holds the keys of
 * the agents whose output this screen reads.
 */
@Composable
private fun ChatThread(
    chat: List<ChatItem>,
    bottom: Dp,
    devices: List<DeviceUi>,
    active: Boolean,
    focus: Set<String>,
    many: Boolean,
    reply: ChatReply?,
    notices: InboxNotices,
    actions: ChatActions,
    onReply: (ChatReply) -> Unit,
) {
    val scroll = rememberScrollState()
    var follow by remember { mutableStateOf(true) }
    // Only the end of a scroll changes follow. A scroll by the user to the end follows again.
    LaunchedEffect(scroll) {
        snapshotFlow { scroll.isScrollInProgress }.drop(1).collect { moving ->
            if (!moving) follow = scroll.value >= scroll.maxValue - FOLLOW_SLACK_PX
        }
    }
    // While the view follows, it stays at the end when an entry or the view changes its height.
    LaunchedEffect(scroll) {
        snapshotFlow { scroll.maxValue }.collect { end ->
            if (follow && !scroll.isScrollInProgress && end in 1 until Int.MAX_VALUE) scroll.scrollTo(end)
        }
    }
    // While the view follows, it shows a new entry at the end. What this phone sent shows also after the user scrolled up.
    val last = chat.lastOrNull()
    LaunchedEffect(last?.key) {
        val mine = (last as? ChatLogItem)?.entry?.let { !it.incoming } == true
        if (follow || mine) {
            follow = true
            scroll.scrollTo(scroll.maxValue)
        }
    }
    val context = LocalContext.current
    BoxWithConstraints(Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxSize().verticalScroll(scroll).heightIn(min = maxHeight)
                .padding(start = 12.dp, end = 12.dp, top = 14.dp, bottom = bottom),
            verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.Bottom),
        ) {
            if (chat.isEmpty()) {
                T(
                    "Agents that need you, approvals, and files from your computers show here. So do the links, text, and files that you send.",
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp), size = 13, color = Tn.sub, align = TextAlign.Center, lineHeight = 1.4f,
                )
            }
            var day = -1L
            for (c in chat) {
                val d = dayOf(c.at)
                if (c.at > 0 && d != day) {
                    day = d
                    T(dayText(c.at), Modifier.fillMaxWidth().padding(vertical = 2.dp), size = 12, color = Tn.sub, align = TextAlign.Center)
                }
                key(c.key) {
                    when (c) {
                        is ChatLogItem -> LogEntry(c.entry, context, many)
                        is ChatEventItem -> when (val item = c.item) {
                            is AgentItem -> AgentCard(
                                item, devices.firstOrNull { it.id == item.deviceId }, c.at, active, item.key in focus, many,
                                replying = reply?.let { it.deviceId == item.deviceId && it.pane == item.agent.pane } == true,
                                actions = actions, onReply = onReply,
                            )
                            is ApprovalItem -> ApprovalCard(item.request, c.at, actions)
                            is PairItem -> PairCard(item, c.at, actions)
                        }
                    }
                }
            }
            ChatNotices(notices, actions)
        }
    }
}

/** The state of the links under the entries: that Flux connects, and the notices with their next steps. */
@Composable
private fun ChatNotices(notices: InboxNotices, actions: ChatActions) {
    if (notices.connecting && notices.reach.noneOnline) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Spinner(Modifier.size(16.dp), color = Tn.blue)
            T(connectingTitle(notices.reach), size = 13, color = Tn.sub)
        }
    }
    InboxNoticeList(notices, actions)
}

// ───────────────────────── Cards of the computers ─────────────────────────

/** The shape of a card from a computer: round, with a small corner at the bottom left. */
private val InShape = RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp, bottomEnd = 14.dp, bottomStart = 4.dp)

/** The part of the width that a card from a computer takes. A card that needs the user takes the full width. */
private const val IN_WIDTH = 0.88f

/**
 * A card from a computer, on the left: the [mark] and the [state] in
 * [color], the [source] in mono, and the [time] at the end. The [title]
 * and the [body] follow, then [content]. A card that needs the user
 * ([ask]) takes the full width and has a red border of 2 dp. [mono] sets
 * the title in mono, for a file name or a command. [action] is a text
 * action at the bottom. TalkBack reads the top row as 1 line.
 */
@Composable
private fun InCard(
    mark: @Composable () -> Unit,
    state: String,
    color: Color,
    source: String,
    time: String,
    title: String,
    body: String = "",
    mono: Boolean = false,
    ask: Boolean = false,
    progress: Float? = null,
    action: Pair<String, (() -> Unit)?>? = null,
    titleLines: Int = Int.MAX_VALUE,
    content: @Composable ColumnScope.() -> Unit = {},
) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        Column(
            Modifier.width(if (ask) maxWidth else maxWidth * IN_WIDTH).clip(InShape).background(Tn.tile)
                .border(if (ask) 2.dp else 1.dp, if (ask) Tn.red else Tn.line, InShape)
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Row(
                Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = listOf(state, source, time).filter { it.isNotEmpty() }.joinToString(", ") },
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                mark()
                T(state, size = 12, color = color, weight = FontWeight.Medium, maxLines = 1)
                if (source.isNotEmpty()) T("· $source", Modifier.weight(1f), size = 12, color = Tn.sub, family = Mono, maxLines = 1) else Spacer(Modifier.weight(1f))
                T(time, size = 11, color = Tn.sub, family = Mono, maxLines = 1)
            }
            LineText(
                if (mono) breakAll(title) else title, size = 14f, lineHeight = 1.3f, weight = FontWeight.SemiBold,
                family = if (mono) Mono else androidx.compose.ui.text.font.FontFamily.Default, maxLines = titleLines,
            )
            if (body.isNotEmpty()) LineText(body, size = 12f, lineHeight = 1.4f, color = Tn.sub, family = Mono)
            if (progress != null) {
                Box(Modifier.padding(top = 2.dp).fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(Tn.line)) { LineFill(progress, Tn.blue) }
            }
            content()
            if (action != null) {
                val (label, onClick) = action
                // The action reaches 6 dp into the padding of the card, as in the design.
                if (onClick != null) {
                    TextAction(label, onClick, Modifier.overhangBottom(6.dp), size = 13, height = 32.dp, pad = 0.dp)
                } else {
                    Box(Modifier.overhangBottom(6.dp).heightIn(min = 32.dp), contentAlignment = Alignment.CenterStart) {
                        T(label, size = 13, color = Tn.blue, weight = FontWeight.SemiBold, maxLines = 1)
                    }
                }
            }
        }
    }
}

/** Lays out the element [by] shorter at the bottom, so that it reaches into the space under it. */
private fun Modifier.overhangBottom(by: Dp): Modifier = layout { m, c ->
    val p = m.measure(c)
    layout(p.width, (p.height - by.roundToPx()).coerceAtLeast(0)) { p.place(0, 0) }
}

/** A button of a card: [primary] has the accent fill, the other the tonal fill. It is 48 dp high. */
@Composable
private fun CardButton(label: String, modifier: Modifier, primary: Boolean, @DrawableRes icon: Int? = null, onClick: () -> Unit) {
    val ink = if (primary) Tn.onAccent else Tn.text
    Row(
        modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(12.dp)).background(if (primary) Tn.blue else Tn.line)
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) Sym(icon, tint = ink, size = 19.dp)
        T(label, size = 14, color = ink, weight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** The time of a chat entry, such as 14:05, in the format of the phone. */
private fun timeText(context: Context, at: Long): String =
    if (at <= 0) "" else android.text.format.DateFormat.getTimeFormat(context).format(java.util.Date(at))

/** "2:14" for [ms] milliseconds, or "1:02:14" from 1 hour. */
private fun clockText(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

/** The source of an agent: the agent and its project, and the computer when [many] computers are in scope. */
private fun agentSource(item: AgentItem, many: Boolean): String =
    listOf(item.agent.agent, item.agent.project.ifEmpty { item.agent.workspace }, if (many) item.computer else "").filter { it.isNotBlank() }.joinToString(" · ")

/**
 * An agent: what it waits for, what it works on, or that it is done.
 * Only the agent in [focus] reads its output, because the computer sends
 * the output of 1 pane at a time. An agent that waits shows its question
 * and its choices. A choice that rejects the action opens a reply in the
 * dock, and the card says so while [replying]. [at] is the start of the
 * status.
 */
@Composable
private fun AgentCard(
    item: AgentItem,
    d: DeviceUi?,
    at: Long,
    active: Boolean,
    focus: Boolean,
    many: Boolean,
    replying: Boolean,
    actions: ChatActions,
    onReply: (ChatReply) -> Unit,
) {
    val a = item.agent
    val pane = a.pane
    val blocked = item.kind == InboxKind.AgentInput
    val working = item.kind == InboxKind.AgentWorking
    val demo = isDemo(item.deviceId)
    val out = d?.herdrOutput?.takeIf { it.pane == pane } ?: if (demo) DebugDemo.output(pane) else null
    // The card reads the output again when it shows, because an output from before can hold an older question.
    // The agent screen forgets the output when it closes, so the card reads it again then too.
    val missing = out == null
    var stale by remember { mutableStateOf<HerdrOutput?>(null) }
    var asked by remember { mutableStateOf(false) }
    LaunchedEffect(active, focus, item.deviceId, pane, missing) {
        if (!active || !focus || !(blocked || working) || demo || d?.online != true || (asked && !missing)) return@LaunchedEffect
        stale = out
        asked = true
        HerdrSync.read(FluxCore, item.deviceId, pane)
    }
    // Only an output that came after the read of this card shows its choices. It is a new object.
    val fresh = out != null && !out.loading && out.error == null && (demo || (asked && out !== stale))
    // After an answer, the choices wait for the next output, so that a second tap does not answer the next question.
    var answered by remember { mutableStateOf<HerdrOutput?>(null) }
    val choices = if (blocked && fresh && !replying) out.choices else emptyList()
    val texts = remember(out?.lines) { out?.lines?.map { it.text } }
    val ask = remember(texts) { texts?.let { agentAsk(it, 4) } }
    val thread = remember(texts, blocked) { if (!blocked) texts?.let(::agentThread) else null }
    val answerKey = "${item.deviceId}|$pane"
    val sent = chatAnswers[answerKey]?.takeIf { SystemClock.elapsedRealtime() - it.at < SENT_ANSWER_MS }
    LaunchedEffect(item.kind) {
        val s = chatAnswers[answerKey] ?: return@LaunchedEffect
        if (working) chatAnswers[answerKey] = s.copy(working = true) else if (s.working) chatAnswers.remove(answerKey)
    }
    LaunchedEffect(item.kind) { if (!blocked) toldLines.remove(answerKey) }
    val context = LocalContext.current
    var lockError by remember { mutableStateOf<String?>(null) }
    // The number of the last reply before this card answered. The card shows only the replies that it sent.
    var sentAfter by remember { mutableStateOf<Long?>(null) }
    val herdrReply = d?.herdrReply?.takeIf { r -> r.pane == pane && sentAfter.let { it != null && r.seq > it } }
    val sending = herdrReply?.sending == true
    fun answer(c: AgentChoice) {
        if (isTellChoice(c)) {
            onReply(ChatReply(item.deviceId, pane, a.agent, a.project.ifEmpty { a.workspace }, c, out?.lines.orEmpty()))
            return
        }
        lockError = null
        ReplyLock.run(context, {
            answered = out
            sentAfter = d?.herdrReply?.seq ?: 0L
            chatAnswers[answerKey] = SentAnswer(c.label, sentMeta(c), null)
            HerdrSync.sendKeys(FluxCore, item.deviceId, pane, c.keys)
        }) { lockError = it }
    }

    val elapsed = if (working) {
        val since = d?.agentSince?.get(pane)
        if (since != null) {
            val now by rememberTicker(1_000L)
            clockText(now - since)
        } else {
            thread?.elapsed.orEmpty()
        }
    } else {
        ""
    }
    val body = when {
        blocked -> ""
        working -> listOf(sent?.takeIf { it.working }?.let { "You answered: ${it.text}" }.orEmpty(), thread?.step.orEmpty(), elapsed)
            .filter { it.isNotEmpty() }.joinToString(" · ").ifEmpty { "Working" }
        else -> doneText(thread?.worked.orEmpty()).let { if (it == "Done") "Waits for the next prompt" else it }
    }
    val open = { actions.open(Route(item.deviceId, "$AGENT_PAGE$pane")) }
    InCard(
        mark = {
            when {
                blocked -> PulseDot(Tn.red, 8.dp)
                working -> RingSpinner(11.dp, color = Tn.blue)
                else -> Dot(Tn.green, 8.dp)
            }
        },
        state = when {
            blocked -> "Needs input"
            working -> "Working"
            else -> "Done"
        },
        color = when {
            blocked -> Tn.red
            working -> Tn.blue
            else -> Tn.green
        },
        source = agentSource(item, many),
        time = timeText(context, at),
        title = a.title.ifEmpty { a.project.ifEmpty { pane } },
        body = body,
        ask = blocked,
        action = when {
            replying -> "Writing a reply below" to null
            choices.isNotEmpty() -> null
            else -> "Open thread" to open
        },
    ) {
        if (!blocked) return@InCard
        when {
            out?.error != null && !out.loading -> T(out.error, size = 12, color = Tn.red, lineHeight = 1.35f)
            !fresh -> LineSkeleton("Reading the question", Modifier.padding(vertical = 3.dp), lines = listOf(0.8f, 0.55f))
            ask != null -> {
                // The question never gets cut, so that the command that a choice approves shows in full.
                if (!ask.command && ask.question.isNotEmpty()) LineText(ask.question, size = 13f, lineHeight = 1.35f)
                if (ask.lines.isNotEmpty()) LineText(breakAll(ask.lines.joinToString("\n")), size = 12f, lineHeight = 1.4f, color = Tn.sub, family = Mono)
            }
            else -> texts?.let { agentPrompt(it, 4) }?.takeIf { it.isNotEmpty() }?.let { LineText(breakAll(it), size = 12f, lineHeight = 1.4f, color = Tn.sub, family = Mono) }
        }
        if (choices.isNotEmpty()) {
            val enabled = item.control && choicesOpen(out, answered, sending) && toldLines[answerKey] != out?.lines
            Column(Modifier.padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                choices.forEachIndexed { i, c -> AskChoice(c, primary = i == 0, enabled = enabled, height = 44.dp, size = 13.5f) { answer(c) } }
            }
        }
        val problem = lockError ?: herdrReply?.error
        if (problem != null) T(problem, size = 12, color = Tn.red, lineHeight = 1.35f)
        if (!item.control) T("To answer from this phone, set herdr_control = true on ${item.computer}.", size = 12, color = Tn.sub, lineHeight = 1.35f)
        if (sending) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                RingSpinner(14.dp, color = Tn.blue)
                T("Sending", size = 12, color = Tn.sub)
            }
        }
    }
}

/** A request that waits for the fingerprint, with Deny and Approve. Approve opens the approval screen, which asks for the fingerprint. */
@Composable
private fun ApprovalCard(r: ApproveRequest, at: Long, actions: ChatActions) {
    val context = LocalContext.current
    InCard(
        mark = { PulseDot(Tn.red, 8.dp) },
        state = "Needs approval",
        color = Tn.red,
        source = r.service,
        time = timeText(context, at),
        title = if (r.kind == ApproveRequest.Kind.Approve) "Approve ${r.service} on ${r.host}?" else "Enroll this phone on ${r.host}?",
        body = approvalLine(r),
        ask = true,
    ) {
        Row(Modifier.fillMaxWidth().padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CardButton("Deny", Modifier.weight(1f), primary = false) {
                if (isDemo(r.computerId)) FluxCore.toast("This is a sample request") else Approvals.deny(FluxCore, r)
            }
            CardButton("Approve", Modifier.weight(1.6f), primary = true, icon = R.drawable.ic_fingerprint) { actions.approve(r) }
        }
    }
}

/** The user and the terminal of a request, such as "user dev · pts/3". */
private fun approvalLine(r: ApproveRequest): String = listOf("user ${r.user}", r.tty).filter { it.isNotBlank() }.joinToString(" · ")

/** A computer that asks to pair, with the key to compare. */
@Composable
private fun PairCard(item: PairItem, at: Long, actions: ChatActions) {
    InCard(
        mark = { PulseDot(Tn.red, 8.dp) },
        state = "Pair request",
        color = Tn.red,
        source = "",
        time = timeText(LocalContext.current, at),
        title = "${item.computer} asks to pair",
        body = "Compare the key on both screens.",
        ask = true,
    ) {
        CardButton("Compare the key", Modifier.fillMaxWidth().padding(top = 6.dp), primary = true) { actions.showPair(item.deviceId) }
    }
}

// ───────────────────────── Log entries ─────────────────────────

/** An entry of the chat log: a card from the computer, or a bubble or a file card of this phone. With [many] computers in scope, the line under a send names the computer. */
@Composable
private fun LogEntry(e: SendEntry, context: Context, many: Boolean) {
    when {
        e.kind == SendKind.Approved || e.kind == SendKind.Denied -> ApprovalResult(e, context)
        e.incoming && e.kind == SendKind.File -> ReceivedFile(e, context)
        e.incoming -> ReceivedClip(e, context)
        e.kind == SendKind.File || e.kind == SendKind.ClipImage -> SentFile(e, sendMeta(context, e, many))
        else -> SentBubble(e.text, sendMeta(context, e, many))
    }
}

/** A file from a computer: its progress while it comes in, then Open. */
@Composable
private fun ReceivedFile(e: SendEntry, context: Context) {
    val pct = "${(e.progress * 100).toInt()}% of ${bytes(e.size)}"
    InCard(
        mark = {
            when (e.state) {
                TransferState.Running -> RingSpinner(11.dp, color = Tn.blue)
                TransferState.Done -> Dot(Tn.green, 8.dp)
                TransferState.Failed -> Dot(Tn.red, 8.dp)
            }
        },
        state = when (e.state) {
            TransferState.Running -> "Receiving"
            TransferState.Done -> "Received"
            TransferState.Failed -> "Not received"
        },
        color = when (e.state) {
            TransferState.Running -> Tn.blue
            TransferState.Done -> Tn.green
            TransferState.Failed -> Tn.red
        },
        source = e.computer,
        time = timeText(context, e.at),
        title = e.text,
        mono = true,
        body = when (e.state) {
            TransferState.Running -> pct
            TransferState.Done -> "In Downloads"
            TransferState.Failed -> "Send it again from ${e.computer}"
        },
        progress = if (e.state == TransferState.Running) e.progress else null,
        action = if (e.state == TransferState.Done) "Open" to { openReceived(context, e) } else null,
    )
}

/** Opens a received file, or Downloads when the chat does not know the file or no app opens it. */
private fun openReceived(context: Context, e: SendEntry) {
    val downloads = Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    val view = e.uri.takeIf { it.isNotEmpty() }?.let {
        Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse(it), Android.mimeType(e.text) ?: "*/*")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    if (view != null && runCatching { context.startActivity(view) }.isSuccess) return
    runCatching { context.startActivity(downloads) }
}

/** The clip that a computer sent. It is on the clipboard of this phone already, so Copy puts it back after another copy. */
@Composable
private fun ReceivedClip(e: SendEntry, context: Context) {
    var copied by remember { mutableStateOf(false) }
    val image = e.kind == SendKind.ClipImage
    // A text that the log cut is not the whole clip, so it cannot go back on the clipboard.
    val whole = !image && e.text.length < SEND_TEXT_MAX
    InCard(
        mark = { Dot(Tn.cyan, 8.dp) },
        state = "Clipboard",
        color = Tn.cyan,
        source = e.computer,
        time = timeText(context, e.at),
        title = if (image) "An image" else e.text,
        mono = !image,
        titleLines = 4,
        action = if (!whole) {
            null
        } else if (copied) {
            "Copied" to null
        } else {
            "Copy" to {
                if (Plugins.putRemoteText(FluxCore, e.computer, e.text)) {
                    copied = true
                    FluxCore.toast("Copied to this phone")
                }
            }
        },
    )
}

/** The answer of this phone to a request. */
@Composable
private fun ApprovalResult(e: SendEntry, context: Context) {
    val r = e.approval
    val ok = e.kind == SendKind.Approved
    val enroll = r?.kind == ApproveRequest.Kind.Enroll
    val host = r?.host.orEmpty()
    InCard(
        mark = { Dot(if (ok) Tn.green else Tn.sub, 8.dp) },
        state = if (enroll && ok) "Enrolled" else if (ok) "Approved" else "Denied",
        color = if (ok) Tn.green else Tn.sub,
        source = e.text,
        time = timeText(context, e.at),
        title = when {
            enroll && ok -> "Enrolled this phone on $host"
            enroll -> "Denied the enrollment on $host"
            else -> (if (ok) "Approved " else "Denied ") + e.text + (r?.user?.let { " for $it" } ?: "")
        },
        body = r?.let(::approvalLine).orEmpty(),
    )
}

/** The shape of text that this phone sent: round, with a small corner at the bottom right. */
private val OutShape = RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp, bottomEnd = 4.dp, bottomStart = 16.dp)

/** Text, a link, or a clip that went out: a bubble at the right in mono, with [meta] under it. */
@Composable
private fun SentBubble(text: String, meta: String) {
    BoxWithConstraints(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
        Column(Modifier.widthIn(max = maxWidth * 0.82f), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            SelectionContainer {
                LineText(
                    breakAll(text), Modifier.clip(OutShape).background(Tn.accentTile).border(1.dp, Tn.lineHi, OutShape).padding(horizontal = 14.dp, vertical = 8.dp),
                    size = 12.5f, lineHeight = 1.45f, family = Mono,
                )
            }
            T(meta, size = 11, color = Tn.sub)
        }
    }
}

/** The shape of a file that this phone sent. */
private val OutFileShape = RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp, bottomEnd = 4.dp, bottomStart = 14.dp)

/** A file or an image clip that went out: a card of 236 dp at the right with its icon, its name, and [meta], and a bar while it runs. */
@Composable
private fun SentFile(e: SendEntry, meta: String) {
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
        Column(
            Modifier.width(236.dp).clip(OutFileShape).background(Tn.accentTile).border(1.dp, Tn.lineHi, OutFileShape).padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Sym(if (e.kind == SendKind.ClipImage) Ic.image else sendFileIcon(e.text), tint = Tn.blue, size = 22.dp)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    T(if (e.kind == SendKind.ClipImage) "Image" else e.text, size = 13, weight = FontWeight.Medium, family = Mono, maxLines = 1)
                    T(meta, size = 12, color = if (e.state == TransferState.Failed) Tn.red else Tn.sub)
                }
                when (e.state) {
                    TransferState.Running -> RingSpinner(14.dp, color = Tn.blue)
                    TransferState.Done -> Sym(Ic.check, "Done", tint = Tn.green, size = 18.dp)
                    TransferState.Failed -> Sym(Ic.close, "Failed", tint = Tn.red, size = 18.dp)
                }
            }
            if (e.state == TransferState.Running) {
                Box(Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(Tn.line)) { LineFill(e.progress, Tn.blue) }
            }
        }
    }
}

/** The icon of a file that went out: an image, or a document. */
@DrawableRes
private fun sendFileIcon(name: String): Int = if (fileIcon(name, false) == Ic.image) Ic.image else Ic.textFile

/** The line under a send, such as "Link · opened in the browser · 13:20". [showComputer] adds the computer. */
private fun sendMeta(context: Context, e: SendEntry, showComputer: Boolean): String {
    val time = timeText(context, e.at)
    val pct = "${(e.progress * 100).toInt()}% of ${bytes(e.size)}"
    return when (e.kind) {
        SendKind.Link -> if (showComputer) "Link · opened on ${e.computer} · $time" else "Link · opened in the browser · $time"
        SendKind.Text -> if (showComputer) "Text · on the clipboard of ${e.computer} · $time" else "Text · on the clipboard · $time"
        SendKind.Scan -> if (showComputer) "Scan · saved on ${e.computer} · $time" else "Scan · saved as a text file · $time"
        SendKind.Clip, SendKind.ClipImage -> if (showComputer) "Clipboard · to ${e.computer} · $time" else "Clipboard · $time"
        SendKind.File -> when (e.state) {
            TransferState.Running -> (if (showComputer) "Sending to ${e.computer}" else "Sending") + " · $pct"
            TransferState.Done -> (if (showComputer) "Sent to ${e.computer}" else "Sent") + " · $time"
            TransferState.Failed -> "Not sent · $time"
        }
        SendKind.Approved, SendKind.Denied -> time
    }
}

/** The day of [at] as a number, to find the first entry of each day. */
private fun dayOf(at: Long): Long {
    val c = Calendar.getInstance().apply { timeInMillis = at }
    return c.get(Calendar.YEAR) * 1000L + c.get(Calendar.DAY_OF_YEAR)
}

/** "Today", "Yesterday", or the date of [at]. */
private fun dayText(at: Long): String {
    val now = System.currentTimeMillis()
    return when (dayOf(at)) {
        dayOf(now) -> "Today"
        dayOf(now - 24 * 60 * 60_000L) -> "Yesterday"
        else -> java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(java.util.Date(at))
    }
}

/**
 * Text that breaks at any character, as a link or a command in mono does in
 * the design. A zero-width space goes between 2 characters that are not
 * white space.
 */
internal fun breakAll(text: String): String {
    val b = StringBuilder(text.length * 2)
    var i = 0
    while (i < text.length) {
        val n = Character.charCount(text.codePointAt(i))
        if (i > 0 && !text[i].isWhitespace() && !text[i - 1].isWhitespace()) b.append('​')
        b.append(text, i, i + n)
        i += n
    }
    return b.toString()
}

// ───────────────────────── Dock ─────────────────────────

/** A tool of the dock. [description] is the label for TalkBack. */
private class DockTool(@param:DrawableRes val icon: Int, val label: String, val description: String, val onClick: () -> Unit)

/**
 * The dock of the chat: the clipboard of this phone with Send, the 6
 * tools, and the field for text or a link. While a [reply] is open, a row
 * with Cancel takes the place of the clipboard and the tools, and the field
 * writes to the agent. [entries] tell whether the clip went out already.
 */
@Composable
private fun ChatDock(
    shape: DockShape,
    on: Boolean,
    entries: List<SendEntry>,
    target: Target,
    reply: ChatReply?,
    tools: List<DockTool>,
    onClip: () -> Unit,
    onText: (String) -> Unit,
    onReply: (String) -> Unit,
    onCancel: () -> Unit,
) {
    val clip = rememberPhoneClip()
    Column(
        Modifier.fillMaxWidth().dockFrame(shape).padding(start = 12.dp, end = 12.dp, top = 12.dp, bottom = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (reply != null) {
            Row(Modifier.fillMaxWidth().heightIn(min = 32.dp).padding(start = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Sym(R.drawable.ic_reply, tint = Tn.blue, size = 18.dp)
                T("Reply to ${reply.agent}", size = 13, weight = FontWeight.Medium, maxLines = 1)
                if (reply.project.isNotEmpty()) T("· ${reply.project}", Modifier.weight(1f, fill = false), size = 11, color = Tn.sub, family = Mono, maxLines = 1)
                Spacer(Modifier.weight(1f))
                TextAction("Cancel", onCancel, size = 13, height = 32.dp, pad = 4.dp)
            }
        } else {
            ClipRow(clip, entries, enabled = on, onClip = onClip)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (k in tools) {
                    DockKey(k.description, Modifier.weight(1f).height(56.dp), enabled = on, onClick = k.onClick) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Sym(k.icon, tint = Tn.blue, size = 21.dp)
                            T(k.label, size = 11, weight = FontWeight.Medium, maxLines = 1, fit = true)
                        }
                    }
                }
            }
        }
        ChatComposer(
            enabled = on || reply != null,
            reply = reply,
            placeholder = when {
                reply != null -> "Tell ${reply.agent} what to do differently"
                target is Target.One -> "Type text or a link for ${target.device.name}"
                else -> "Type text or a link"
            },
            onSend = { text -> if (reply != null) onReply(text) else onText(text) },
        )
    }
}

/**
 * The clipboard of this phone and its Send key, 56 dp high. The box shows
 * where the clip came from and its text on 1 line. After a send, the key
 * shows Sent.
 */
@Composable
private fun ClipRow(clip: PhoneClip, entries: List<SendEntry>, enabled: Boolean, onClip: () -> Unit) {
    val now by rememberTicker(30_000L)
    val sent = clip.stamp.takeIf { it != 0L }?.let { s -> entries.lastOrNull { it.clipStamp == s } }
    val context = LocalContext.current
    Row(Modifier.fillMaxWidth().height(56.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(
            Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(10.dp)).background(Tn.bg).padding(horizontal = 11.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
        ) {
            val meta = when {
                sent != null -> "Clipboard · sent at ${timeText(context, sent.at)}"
                clip.empty -> "Clipboard on this phone · empty"
                clip.from != null -> "Clipboard from ${clip.from}" + (if (clip.stamp > 0) " · ${agoText(clip.stamp, now)}" else "")
                clip.stamp > 0 -> "Clipboard on this phone · ${agoText(clip.stamp, now)}"
                else -> "Clipboard on this phone"
            }
            T(meta, size = 11, color = Tn.cyan, weight = FontWeight.Medium, maxLines = 1)
            val text = clip.text
            if (text != null) {
                T(text.replace('\n', ' '), Modifier.clearAndSetSemantics { contentDescription = text }, size = 12, family = Mono, maxLines = 1)
            } else {
                T(
                    when {
                        clip.image -> "An image"
                        clip.hidden -> "Hidden, because its app marks it as private"
                        else -> "Copy text or an image on this phone"
                    },
                    size = 12, color = Tn.sub, maxLines = 1,
                )
            }
        }
        val can = enabled && !clip.empty
        val ink = if (sent != null) Tn.text else Tn.onAccent
        Column(
            Modifier.width(88.dp).fillMaxHeight().alpha(if (can) 1f else DimAlpha).clip(RoundedCornerShape(12.dp))
                .background(if (sent != null) Tn.line else Tn.blue)
                .clickable(enabled = can, onClickLabel = "Send the clipboard", role = Role.Button) {
                    if (sent != null) FluxCore.toast("The clip is on ${sent.computer} already") else onClip()
                },
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
        ) {
            Sym(if (sent != null) Ic.check else Ic.pasteGo, tint = ink, size = 20.dp)
            T(if (sent != null) "Sent" else "Send", size = 14, color = ink, weight = FontWeight.SemiBold)
        }
    }
}

/**
 * The field and its send key. A web link opens in the browser of the
 * computer, and other text goes to its clipboard. While a [reply] is open,
 * the field has the accent border, takes the focus, and writes to the
 * agent.
 */
@Composable
private fun ChatComposer(enabled: Boolean, reply: ChatReply?, placeholder: String, onSend: (String) -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    LaunchedEffect(reply) {
        text = ""
        if (reply != null) runCatching { focus.requestFocus() }
    }
    val can = enabled && text.isNotBlank()
    val send = {
        if (can) {
            onSend(text.trim())
            text = ""
        }
    }
    val shape = RoundedCornerShape(24.dp)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Bottom) {
        BasicTextField(
            value = text,
            onValueChange = { text = it },
            modifier = Modifier.weight(1f).focusRequester(focus).semantics { contentDescription = placeholder },
            enabled = enabled,
            textStyle = TextStyle(color = Tn.text, fontSize = 14.sp, lineHeight = 20.sp),
            cursorBrush = SolidColor(Tn.blue),
            maxLines = 4,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { send() }),
            decorationBox = { inner ->
                Box(
                    Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(shape).background(Tn.bg).border(1.dp, if (reply != null) Tn.blue else Tn.lineHi, shape)
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    if (text.isEmpty()) T(placeholder, Modifier.clearAndSetSemantics {}, size = 14, color = Tn.sub, maxLines = 1)
                    inner()
                }
            },
        )
        Box(
            Modifier.size(48.dp).clip(CircleShape).background(if (can) Tn.blue else Tn.line)
                .clickable(enabled = can, onClickLabel = "Send", role = Role.Button, onClick = send)
                .semantics { contentDescription = "Send" },
            contentAlignment = Alignment.Center,
        ) { Sym(Ic.up, tint = if (can) Tn.onAccent else Tn.sub, size = 22.dp) }
    }
}

// ───────────────────────── Clipboard ─────────────────────────

/**
 * The clipboard of this phone for the dock. [text] is null for an image, a
 * clip that its app marks as private ([hidden]), or an empty clipboard.
 * [from] names the computer when the clip came from Flux. [stamp] is the
 * time that Android set on the clip.
 */
internal data class PhoneClip(
    val text: String? = null,
    val image: Boolean = false,
    val hidden: Boolean = false,
    val stamp: Long = 0,
    val from: String? = null,
) {
    val empty: Boolean get() = text == null && !image && !hidden
}

/** The last clip that the dock read. A clip with the same time comes from here, so that Android shows its paste notice once for each clip. */
private var lastClip: PhoneClip? = null

/**
 * Reads the clipboard of this phone. Android lets the app read it only
 * while the window has focus, so the dock reads it again when the window
 * gets the focus, when the app comes back, and when the clip changes.
 */
@Composable
private fun rememberPhoneClip(): PhoneClip {
    val context = LocalContext.current
    val focused = LocalWindowInfo.current.isWindowFocused
    var clip by remember { mutableStateOf(lastClip ?: PhoneClip()) }
    LaunchedEffect(focused) { if (focused) clip = readClip(context) }
    LifecycleResumeEffect(context) {
        clip = readClip(context)
        onPauseOrDispose { }
    }
    DisposableEffect(context) {
        val cm = context.getSystemService(ClipboardManager::class.java)
        val listener = ClipboardManager.OnPrimaryClipChangedListener { clip = readClip(context) }
        cm?.addPrimaryClipChangedListener(listener)
        onDispose { cm?.removePrimaryClipChangedListener(listener) }
    }
    return clip
}

private fun readClip(context: Context): PhoneClip {
    val cm = context.getSystemService(ClipboardManager::class.java) ?: return PhoneClip()
    val desc = runCatching { cm.primaryClipDescription }.getOrNull() ?: return PhoneClip().also { lastClip = it }
    val stamp = Android.clipTimestamp(context)
    lastClip?.let { if (stamp != 0L && it.stamp == stamp) return it }
    // Flux puts the clip of a computer on the clipboard with its own label.
    val from = InboxFeed.clip.value?.takeIf { !it.sent && desc.label?.toString() == "Flux" }?.computer
    val read = when {
        desc.hasMimeType("image/*") -> PhoneClip(image = true, stamp = stamp, from = from)
        Android.clipboardSensitive(context) -> PhoneClip(hidden = true, stamp = stamp)
        else -> {
            // Without the focus, Android gives no text. The next read gets it.
            val text = Android.clipboardText(context, automatic = true)?.takeIf { it.isNotBlank() } ?: return PhoneClip(stamp = stamp)
            PhoneClip(text = text.trim().take(400), stamp = stamp, from = from)
        }
    }
    lastClip = read
    return read
}
