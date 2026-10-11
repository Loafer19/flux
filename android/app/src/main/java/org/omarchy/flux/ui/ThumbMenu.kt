package org.omarchy.flux.ui

import androidx.activity.compose.BackHandler
import androidx.annotation.DrawableRes
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/*
 * The thumb menu of the chat: the + key at the left of the field opens it
 * above the key. A tap opens it, and a tap on an item runs the item. A hold
 * opens it at once: the thumb slides to an item, the item lights up, and
 * the release runs it. A release on no item keeps the menu open. The items
 * nearest the thumb lead to the other destinations, so the chat needs no
 * navigation bar.
 */

/** An item of the thumb menu. [description] is what TalkBack reads. */
class ThumbItem(
    @param:DrawableRes val icon: Int,
    val label: String,
    val description: String,
    val enabled: Boolean,
    val run: () -> Unit,
)

/** A group of items of the thumb menu with a [title]. [wide] items take a row of 2, with the icon before the label. */
class ThumbSection(val title: String, val items: List<ThumbItem>, val wide: Boolean = false)

/**
 * The state of the thumb menu. [held] is true while the finger that opened
 * the menu stays down, and [hover] is the item under it. The key and the
 * items keep their places on the screen, so the finger can find an item.
 */
class ThumbMenu {
    var open by mutableStateOf(false)
        private set
    var held by mutableStateOf(false)
        private set
    /** The label of the item under the finger, or null. */
    var hover by mutableStateOf<String?>(null)
        internal set

    /** The top left corner of the + key in the root. */
    internal var key = Offset.Zero

    /** The top of the + key in the root. The menu ends above it. */
    internal var keyTop by mutableStateOf(0f)

    /** The items by their labels, and their places in the root. */
    internal var items: Map<String, ThumbItem> = emptyMap()
    internal val places = mutableStateMapOf<String, Rect>()

    fun show(hold: Boolean) {
        open = true
        held = hold
        hover = null
    }

    fun close() {
        open = false
        held = false
        hover = null
    }

    /** The item at [p] in the root that the user can select, or null. */
    internal fun at(p: Offset): ThumbItem? =
        places.entries.firstOrNull { it.value.contains(p) }?.key?.let { items[it] }?.takeIf { it.enabled }

    /** Ends a hold: the item under the finger runs, or the menu stays open for a tap. */
    internal fun release() {
        val item = hover?.let { items[it] }?.takeIf { it.enabled }
        held = false
        hover = null
        if (item != null) {
            close()
            item.run()
        }
    }
}

@Composable
fun rememberThumbMenu(): ThumbMenu = remember { ThumbMenu() }

/**
 * The gesture of the + key: a tap opens [menu], and a hold opens it for
 * the thumb. While the finger stays down, the item under it lights up,
 * with a light tick of the phone at each new item.
 */
@Composable
internal fun Modifier.thumbMenuKey(menu: ThumbMenu, enabled: Boolean, label: String): Modifier {
    val haptic = LocalHapticFeedback.current
    return this
        .onGloballyPositioned {
            val p = it.positionInRoot()
            menu.key = p
            menu.keyTop = p.y
        }
        .semantics {
            role = Role.Button
            contentDescription = label
            if (enabled) onClick(label = "Open the menu") { menu.show(hold = false); true }
        }
        .pointerInput(enabled) {
            if (!enabled) return@pointerInput
            awaitEachGesture {
                val down = awaitFirstDown()
                val up = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) { waitForUpOrCancellation() }
                if (up != null) {
                    menu.show(hold = false)
                    return@awaitEachGesture
                }
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                menu.show(hold = true)
                while (true) {
                    val event = awaitPointerEvent()
                    val change = event.changes.firstOrNull { it.id == down.id } ?: break
                    val item = menu.at(menu.key + change.position)?.label
                    if (item != menu.hover) {
                        menu.hover = item
                        if (item != null) haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                    }
                    change.consume()
                    if (!change.pressed) break
                }
                menu.release()
            }
        }
}

/** The columns of the items of a section that is not wide. */
private const val THUMB_COLUMNS = 3

/** The scrim under the thumb menu. */
private val ThumbScrim = Color(0x99080808)

/**
 * The thumb menu over the chat, when it is open. A card above the + key
 * holds the [sections], with the last section nearest the thumb. A tap on
 * the scrim or Back closes it.
 */
@Composable
fun ThumbMenuOverlay(menu: ThumbMenu, sections: List<ThumbSection>) {
    BackHandler(enabled = menu.open) { menu.close() }
    SideEffect { menu.items = sections.flatMap { it.items }.associateBy { it.label } }
    val shown = remember { MutableTransitionState(false) }
    shown.targetState = menu.open
    if (!shown.currentState && !shown.targetState) return
    val density = LocalDensity.current
    var top by remember { mutableStateOf(0f) }
    var height by remember { mutableStateOf(0) }
    Box(Modifier.fillMaxSize().onGloballyPositioned { top = it.positionInRoot().y; height = it.size.height }) {
        AnimatedVisibility(shown, enter = fadeIn(tween(120)), exit = fadeOut(tween(120))) {
            Box(
                Modifier.fillMaxSize().background(ThumbScrim)
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClickLabel = "Close the menu") { menu.close() },
            )
        }
        // The card ends 10 dp above the + key, at the left edge of the dock.
        val bottom = with(density) { (top + height - menu.keyTop).coerceAtLeast(0f).toDp() } + 10.dp
        AnimatedVisibility(
            shown,
            Modifier.align(Alignment.BottomStart).padding(start = TiledGutter, end = TiledGutter, bottom = bottom),
            // A slide moves the layout, so the places of the items follow it. A scale would leave them old.
            enter = fadeIn(tween(140)) + slideInVertically(spring(dampingRatio = 0.8f, stiffness = 600f)) { it / 6 },
            exit = fadeOut(tween(100)) + slideOutVertically(tween(100)) { it / 10 },
        ) {
            val shape = RoundedCornerShape(20.dp)
            Column(
                Modifier.fillMaxWidth().clip(shape).background(Tn.bg).border(1.dp, Tn.lineHi, shape).padding(10.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                for (s in sections) {
                    T(s.title, Modifier.padding(start = 6.dp, top = 2.dp).semantics { heading() }, size = 12, color = Tn.sub, weight = FontWeight.Medium)
                    val columns = if (s.wide) 2 else THUMB_COLUMNS
                    for (row in s.items.chunked(columns)) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            for (item in row) ThumbCell(menu, item, s.wide, Modifier.weight(1f))
                            // A short last row keeps the width of the columns.
                            repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
            }
        }
    }
}

/** An item of the thumb menu. It lights up while the thumb is on it. */
@Composable
private fun ThumbCell(menu: ThumbMenu, item: ThumbItem, wide: Boolean, modifier: Modifier) {
    val lit = menu.hover == item.label
    val grow by animateFloatAsState(if (lit) 1.05f else 1f, spring(dampingRatio = 0.6f), label = "thumbCell")
    val shape = RoundedCornerShape(14.dp)
    val m = modifier.height(if (wide) 56.dp else 72.dp)
        .onGloballyPositioned { menu.places[item.label] = it.boundsInRoot() }
        .scale(grow)
        .alpha(if (item.enabled) 1f else DimAlpha)
        .clip(shape)
        .background(if (lit) Tn.accentTile else Tn.tile)
        .border(1.dp, if (lit) Tn.blue else Tn.line, shape)
        .clickable(enabled = item.enabled && !menu.held, onClickLabel = item.description, role = Role.Button) {
            menu.close()
            item.run()
        }
        .clearAndSetSemantics {
            contentDescription = item.description
            role = Role.Button
            if (item.enabled) onClick { menu.close(); item.run(); true }
        }
    val tint = if (lit) Tn.blue else Tn.text
    if (wide) {
        Row(m.padding(horizontal = 14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
            Sym(item.icon, tint = Tn.blue, size = 22.dp)
            T(item.label, size = 14, color = tint, weight = FontWeight.SemiBold, maxLines = 1)
        }
    } else {
        Column(m, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterVertically)) {
            Sym(item.icon, tint = Tn.blue, size = 24.dp)
            T(item.label, size = 12, color = tint, weight = FontWeight.Medium, maxLines = 1, fit = true)
        }
    }
}
