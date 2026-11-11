package dev.drawplay

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.MotionEvent
import android.widget.LinearLayout
import android.widget.TextView

/**
 * On-screen keyboard that sends real key presses to the Mac (macOS virtual key codes + modifier bits).
 * Shift, Ctrl, Option and Command latch for the next key (tap again to cancel); Caps stays on until tapped.
 * Delete and the arrow keys repeat while held.
 */
@SuppressLint("ClickableViewAccessibility")
class Osk(ctx: Context, private val sendKey: (code: Int, down: Boolean, mods: Int) -> Unit) : LinearLayout(ctx) {
    private class Key(val label: String, val code: Int = -1, val shifted: String? = null,
                      val weight: Float = 1f, val mod: Char = ' ', val letter: Boolean = false, val repeat: Boolean = false)

    private fun k(c: Char, code: Int, shifted: String? = null) =
        Key(c.toString(), code, shifted, letter = c.isLetter())

    private val rows: List<List<Key>> = listOf(
        listOf(Key("esc", 53), k('`', 50, "~"), k('1', 18, "!"), k('2', 19, "@"), k('3', 20, "#"), k('4', 21, "$"), k('5', 23, "%"),
            k('6', 22, "^"), k('7', 26, "&"), k('8', 28, "*"), k('9', 25, "("), k('0', 29, ")"), k('-', 27, "_"), k('=', 24, "+"),
            Key("⌫", 51, weight = 1.6f, repeat = true)),
        listOf(Key("tab", 48, weight = 1.5f), k('q', 12), k('w', 13), k('e', 14), k('r', 15), k('t', 17), k('y', 16), k('u', 32),
            k('i', 34), k('o', 31), k('p', 35), k('[', 33, "{"), k(']', 30, "}"), Key("\\", 42, "|", weight = 1.1f)),
        listOf(Key("caps", mod = 'c', weight = 1.8f), k('a', 0), k('s', 1), k('d', 2), k('f', 3), k('g', 5), k('h', 4), k('j', 38),
            k('k', 40), k('l', 37), k(';', 41, ":"), k('\'', 39, "\""), Key("return", 36, weight = 2f)),
        listOf(Key("shift", mod = 's', weight = 2.3f), k('z', 6), k('x', 7), k('c', 8), k('v', 9), k('b', 11), k('n', 45), k('m', 46),
            k(',', 43, "<"), k('.', 47, ">"), k('/', 44, "?"), Key("shift", mod = 's', weight = 2.3f)),
        listOf(Key("ctrl", mod = 'k', weight = 1.3f), Key("opt", mod = 'o', weight = 1.3f), Key("cmd", mod = 'm', weight = 1.5f),
            Key("space", 49, weight = 6f), Key("cmd", mod = 'm', weight = 1.5f), Key("opt", mod = 'o', weight = 1.3f),
            Key("←", 123, repeat = true), Key("↓", 125, repeat = true), Key("↑", 126, repeat = true), Key("→", 124, repeat = true))
    )

    private val views = ArrayList<Pair<Key, TextView>>()
    private var shift = false; private var ctrl = false; private var opt = false; private var cmd = false; private var caps = false
    private val handler = Handler(Looper.getMainLooper())
    private val dp = ctx.resources.displayMetrics.density

    init {
        orientation = VERTICAL
        setPadding((10 * dp).toInt(), (10 * dp).toInt(), (10 * dp).toInt(), (14 * dp).toInt())
        setBackgroundColor(0xF0181818.toInt())
        for (row in rows) {
            val r = LinearLayout(ctx).apply { orientation = HORIZONTAL }
            for (key in row) {
                val tv = TextView(ctx).apply {
                    gravity = Gravity.CENTER
                    setTextColor(Color.WHITE)
                    textSize = 16f
                    isAllCaps = false
                    setOnTouchListener { _, e -> onKey(key, this, e) }
                }
                r.addView(tv, LayoutParams(0, (50 * dp).toInt(), key.weight).apply { setMargins(3, 3, 3, 3) })
                views.add(key to tv)
            }
            addView(r, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        }
        refresh()
    }

    private fun mods(isLetter: Boolean): Int {
        val s = shift || (caps && isLetter)
        return (if (s) 1 else 0) or (if (ctrl) 2 else 0) or (if (opt) 4 else 0) or (if (cmd) 8 else 0)
    }

    private fun refresh() {
        val upper = shift || caps
        for ((key, tv) in views) {
            val on = when (key.mod) { 's' -> shift; 'k' -> ctrl; 'o' -> opt; 'm' -> cmd; 'c' -> caps; else -> false }
            tv.text = when {
                key.mod != ' ' -> key.label
                key.letter && upper -> key.label.uppercase()
                !key.letter && shift && key.shifted != null -> key.shifted
                else -> key.label
            }
            tv.background = GradientDrawable().apply {
                cornerRadius = 10 * dp
                setColor(if (on) 0xFF3A7BFF.toInt() else if (key.mod != ' ' || key.code in listOf(53, 48, 51, 36)) 0xFF3B3B3F.toInt() else 0xFF55555A.toInt())
            }
        }
    }

    private val heldMods = HashMap<Int, Int>()      // key code -> modifier bits used at press time

    private fun onKey(key: Key, v: TextView, e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                if (key.mod != ' ') {                    // modifiers latch for the next key
                    when (key.mod) { 's' -> shift = !shift; 'k' -> ctrl = !ctrl; 'o' -> opt = !opt; 'm' -> cmd = !cmd; 'c' -> caps = !caps }
                    refresh(); return true
                }
                val m = mods(key.letter)
                heldMods[key.code] = m
                v.alpha = 0.6f
                sendKey(key.code, true, m)
                shift = false; ctrl = false; opt = false; cmd = false      // one-shot modifiers are used up
                refresh()
                if (key.repeat) startRepeat(key.code, m)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (key.mod != ' ') return true
                v.alpha = 1f
                stopRepeat()
                sendKey(key.code, false, heldMods.remove(key.code) ?: 0)
            }
        }
        return true
    }

    private var repeater: Runnable? = null

    private fun startRepeat(code: Int, m: Int) {
        stopRepeat()
        val r = object : Runnable {
            override fun run() { sendKey(code, false, m); sendKey(code, true, m); handler.postDelayed(this, 45) }
        }
        repeater = r
        handler.postDelayed(r, 400)
    }

    private fun stopRepeat() { repeater?.let { handler.removeCallbacks(it) }; repeater = null }
}
