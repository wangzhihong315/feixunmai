package com.vibepad.trackpad

import androidx.compose.ui.geometry.Offset
import kotlin.math.abs
import kotlin.math.max

/**
 * Clean-room trackpad gesture state machine.
 *
 * Trackpad semantics, not mouse semantics:
 *  - one-finger move is pointer movement only, never a button press
 *  - one-finger tap is a left click
 *  - two-finger tap is a right click; two-finger move scrolls
 *  - hold still for [holdToDragMs] then move holds the left button
 *    (the phone's stand-in for pressing a physical trackpad down)
 *
 * Three-finger shortcuts were removed: MIUI claims three-finger gestures for
 * its own screenshot action, so they never reached the app reliably.
 *
 * Double-tap-then-drag was removed: on macOS the first two clicks land on a
 * window's title bar and zoom it, so the drag never reaches the content.
 * Long-press-and-move is also deliberately not a drag — a slow slide must stay
 * pointer movement — so the button only goes down when the finger has been
 * still inside the touch slop for [holdToDragMs] and then starts moving.
 */
class GestureEngine(
    private val callbacks: Callbacks,
    private val slopPx: Float,
    private val scrollStepPx: Float,
    private val edgeZonePx: Float,
    private val tapMaxMs: Long = 300L,
    private val holdToDragMs: Long = 350L,
) {
    interface Callbacks {
        fun move(dx: Float, dy: Float)
        fun scroll(pan: Int, wheel: Int)
        fun click(button: Int)
        fun button(button: Int, down: Boolean)
        fun haptic()
    }

    companion object {
        const val BUTTON_LEFT = 0x01
        const val BUTTON_RIGHT = 0x02
        const val BUTTON_MIDDLE = 0x04

    }

    var sensitivity: Float = 1.4f
    var naturalScroll: Boolean = true
    var edgeScrollEnabled: Boolean = true
    /// true: edge scrolling on the left edge (left-handed layout).
    var edgeScrollLeft: Boolean = false

    private var downTime = 0L
    private var pointerCount = 0
    private var maxPointers = 0
    private var maxDisplacement = 0f
    private var lastCentroid = Offset.Zero
    private var startCentroid = Offset.Zero
    private var edgeScroll = false
    private var edgeFeedbackSent = false
    private var dragStarted = false
    private var scrollAccumX = 0f
    private var scrollAccumY = 0f

    /// 诊断用：这次手势是否被判为边缘滚动。
    val isEdgeScrolling: Boolean get() = edgeScroll

    fun onDown(points: List<Offset>, time: Long, viewWidth: Float) {
        if (points.isEmpty()) return
        downTime = time
        pointerCount = points.size
        maxPointers = points.size
        maxDisplacement = 0f
        startCentroid = centroid(points)
        lastCentroid = startCentroid
        edgeScroll = edgeScrollEnabled && points.size == 1 && (
            if (edgeScrollLeft) startCentroid.x < edgeZonePx
            else startCentroid.x > viewWidth - edgeZonePx
        )
        dragStarted = false
        edgeFeedbackSent = false
        scrollAccumX = 0f
        scrollAccumY = 0f
    }

    fun onMove(points: List<Offset>, time: Long) {
        if (points.isEmpty()) return
        val count = points.size
        val c = centroid(points)
        if (count != pointerCount) {
            // A finger landed or lifted: the centroid jumps without the user
            // moving. Rebase so neither a scroll step nor the tap detector
            // sees that jump (it used to reject every two-finger tap).
            pointerCount = count
            maxPointers = max(maxPointers, count)
            lastCentroid = c
            startCentroid = c
            maxDisplacement = 0f
            return
        }
        maxPointers = max(maxPointers, count)
        val delta = c - lastCentroid
        lastCentroid = c
        maxDisplacement = max(maxDisplacement, (c - startCentroid).getDistance())

        when {
            count >= 3 -> Unit

            count == 2 -> {
                scrollAccumY += delta.y
                scrollAccumX += delta.x
                val wheel = notches(scrollAccumY)
                scrollAccumY -= wheel * scrollStepPx
                val pan = notches(scrollAccumX)
                scrollAccumX -= pan * scrollStepPx
                if (wheel != 0 || pan != 0) {
                    // macOS HID wheel is positive = scroll up; fingers moving
                    // down must scroll the content down, which is the negative
                    // direction. Two-finger scrolling was reported as inverted.
                    val sign = if (naturalScroll) -1 else 1
                    callbacks.scroll(pan * sign, wheel * sign)
                }
            }

            else -> {
                if (edgeScroll) {
                    scrollAccumY += delta.y
                    val wheel = notches(scrollAccumY)
                    scrollAccumY -= wheel * scrollStepPx
                    if (wheel != 0) {
                        if (!edgeFeedbackSent) {
                            edgeFeedbackSent = true
                            callbacks.haptic()
                        }
                        val sign = if (naturalScroll) -1 else 1
                        callbacks.scroll(0, wheel * sign)
                    }
                    return
                }

                // Hold still, then move = press the trackpad and drag. The
                // button only goes down if the finger never left the slop
                // circle while it was held, so a slow slide stays a slide.
                if (!dragStarted &&
                    time - downTime >= holdToDragMs &&
                    maxDisplacement <= slopPx
                ) {
                    dragStarted = true
                    callbacks.button(BUTTON_LEFT, true)
                    callbacks.haptic()
                }

                callbacks.move(delta.x * sensitivity, delta.y * sensitivity)
            }
        }
    }

    fun onUp(time: Long) {
        val duration = time - downTime

        if (dragStarted) {
            callbacks.button(BUTTON_LEFT, false)
            dragStarted = false
        } else if (maxPointers == 1 &&
            maxDisplacement <= slopPx &&
            duration <= tapMaxMs
        ) {
            callbacks.click(BUTTON_LEFT)
            callbacks.haptic()
        } else if (maxPointers == 2 &&
            maxDisplacement <= slopPx * 2 &&
            duration <= tapMaxMs + 100
        ) {
            callbacks.click(BUTTON_RIGHT)
            callbacks.haptic()
        }

        pointerCount = 0
        maxPointers = 0
        maxDisplacement = 0f
        edgeScroll = false
        scrollAccumX = 0f
        scrollAccumY = 0f
    }

    private fun centroid(points: List<Offset>): Offset {
        var x = 0f
        var y = 0f
        for (p in points) {
            x += p.x
            y += p.y
        }
        val n = points.size.toFloat()
        return Offset(x / n, y / n)
    }

    private fun notches(accum: Float): Int {
        if (scrollStepPx <= 0f) return 0
        return (accum / scrollStepPx).toInt()
    }
}
