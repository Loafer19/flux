package org.omarchy.flux.core

/**
 * 1 entry of the chat: an entry of the chat log, or an Inbox item at the
 * time it got its state. [key] stays the same while the entry is the
 * same. [at] is the time in milliseconds since the epoch.
 */
sealed interface ChatItem {
    val key: String
    val at: Long
}

/** An entry of [SendLog]: a send, a received file or clip, or the answer to an approval. */
data class ChatLogItem(val entry: SendEntry) : ChatItem {
    override val key: String get() = "log|${entry.id}"
    override val at: Long get() = entry.at
}

/** An agent, an approval, or a pair request. An agent with a new status is a new entry at the end. */
data class ChatEventItem(val item: InboxItem, override val at: Long) : ChatItem {
    override val key: String get() = item.key
}

/**
 * Keeps the first time that the chat showed each Inbox item, for the
 * items whose start is not known: an approval, a pair request, and an
 * agent whose status started before this phone connected, see
 * [AgentClock]. It forgets the items that are gone.
 */
class SeenClock {
    private val seen = HashMap<String, Long>()

    /** Takes the keys of the items at the time [now] and returns the first time of each key. */
    fun update(keys: Collection<String>, now: Long): Map<String, Long> {
        seen.keys.retainAll(keys.toSet())
        for (k in keys) seen.getOrPut(k) { now }
        return HashMap(seen)
    }
}

/**
 * The entries of the chat, oldest first: the [log] and the Inbox [items].
 * An agent takes the start time of its status from [since], by computer
 * and pane. Any other item, and an agent with no start time, takes its
 * time from [seen], by key. Entries with the same time keep the order of
 * the log, then of the items.
 */
fun chatItems(
    log: List<SendEntry>,
    items: List<InboxItem>,
    since: (deviceId: String, pane: String) -> Long?,
    seen: Map<String, Long>,
): List<ChatItem> {
    val events = items.map { item ->
        val start = (item as? AgentItem)?.let { since(it.deviceId, it.agent.pane) }
        ChatEventItem(item, start ?: seen[item.key] ?: 0L)
    }
    return (log.map(::ChatLogItem) + events).sortedBy { it.at }
}

/** The text of a choice that rejects the action and lets the user tell the agent what to do, as Claude Code and Codex show it. */
private val tellChoice = Regex("""\btell\b.*\bdifferently\b""", RegexOption.IGNORE_CASE)

/** True when [c] lets the user write what the agent must do in its place, for example "No, and tell Codex what to do differently (esc)". */
fun isTellChoice(c: AgentChoice): Boolean = tellChoice.containsMatchIn(c.label)
