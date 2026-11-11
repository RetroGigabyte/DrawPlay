package dev.drawplay

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

fun Context.dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

object Colors {
    val bg = 0xFF0E1013.toInt()
    val card = 0xFF171A1F.toInt()
    val field = 0xFF1F2329.toInt()
    val pill = 0xFF2C2F36.toInt()
    val accent = 0xFF3A7BFF.toInt()
    val text = 0xFFF2F4F7.toInt()
    val muted = 0xFF98A2B3.toInt()
    val good = 0xFF3DD68C.toInt()
    val warn = 0xFFFFB02E.toInt()
    val bad = 0xFFFF5C5C.toInt()
}

fun roundedBg(ctx: Context, color: Int, radiusDp: Int) = GradientDrawable().apply {
    cornerRadius = ctx.dp(radiusDp).toFloat(); setColor(color)
}

/** A rounded button used in the toolbar. */
fun pill(ctx: Context, label: String, onClick: () -> Unit) = TextView(ctx).apply {
    text = label; setTextColor(Colors.text); textSize = 15f; gravity = Gravity.CENTER
    setPadding(ctx.dp(16), ctx.dp(10), ctx.dp(16), ctx.dp(10))
    background = roundedBg(ctx, Colors.pill, 20)
    setOnClickListener { onClick() }
}

fun TextView.setActive(active: Boolean) { background = roundedBg(context, if (active) Colors.accent else Colors.pill, 20) }

/**
 * Full-screen screen shown while there is no picture yet: pick USB or Wi-Fi, enter address and PIN, connect.
 * Hides itself once the Mac is streaming. Opened again from the toolbar's Settings button.
 */
class ConnectScreen(
    ctx: Context,
    private val onConnect: (usb: Boolean, host: String, pin: String) -> Unit,
    private val onClose: () -> Unit,
    private val onCtrlAsCmd: (Boolean) -> Unit,
) : FrameLayout(ctx) {
    private var usb = true
    private val status = TextView(ctx)
    private val usbTab = TextView(ctx)
    private val wifiTab = TextView(ctx)
    private val usbHelp = TextView(ctx)
    private val wifiBox = LinearLayout(ctx)
    private val address = EditText(ctx)
    private val pin = EditText(ctx)
    private val close = TextView(ctx)
    private val ctrlRow = TextView(ctx)
    private var ctrlAsCmd = true

    private fun field(e: EditText, hint: String, type: Int) = e.apply {
        this.hint = hint; inputType = type; setSingleLine()
        setTextColor(Colors.text); setHintTextColor(Colors.muted); textSize = 17f
        setPadding(context.dp(16), context.dp(14), context.dp(16), context.dp(14))
        background = roundedBg(context, Colors.field, 12)
    }

    private fun tab(t: TextView, label: String, onTap: () -> Unit) = t.apply {
        text = label; gravity = Gravity.CENTER; textSize = 16f; typeface = Typeface.DEFAULT_BOLD
        setPadding(context.dp(8), context.dp(12), context.dp(8), context.dp(12))
        setOnClickListener { onTap() }
    }

    init {
        setBackgroundColor(Colors.bg)
        isClickable = true                               // swallow touches so the picture underneath is not controlled
        val card = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL
            setPadding(ctx.dp(28), ctx.dp(28), ctx.dp(28), ctx.dp(24))
            background = roundedBg(ctx, Colors.card, 24)
        }
        card.addView(ImageView(ctx).apply { setImageResource(R.mipmap.ic_launcher) }, LinearLayout.LayoutParams(ctx.dp(84), ctx.dp(84)))
        card.addView(TextView(ctx).apply {
            text = "DrawPlay"; setTextColor(Colors.text); textSize = 28f; typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER
            setPadding(0, ctx.dp(12), 0, ctx.dp(2))
        })
        status.apply { setTextColor(Colors.muted); textSize = 15f; gravity = Gravity.CENTER; setPadding(0, 0, 0, ctx.dp(18)) }
        card.addView(status)

        val tabs = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL; background = roundedBg(ctx, Colors.field, 14); setPadding(ctx.dp(4), ctx.dp(4), ctx.dp(4), ctx.dp(4)) }
        tabs.addView(tab(usbTab, "USB cable") { setMode(true) }, LinearLayout.LayoutParams(0, -2, 1f))
        tabs.addView(tab(wifiTab, "Wi-Fi") { setMode(false) }, LinearLayout.LayoutParams(0, -2, 1f))
        card.addView(tabs, LinearLayout.LayoutParams(-1, -2))

        usbHelp.apply {
            text = "Plug the tablet into the Mac with USB debugging on, then press Start USB in the DrawPlay Mac app. Nothing to type here."
            setTextColor(Colors.muted); textSize = 15f; setPadding(0, ctx.dp(16), 0, ctx.dp(4))
        }
        card.addView(usbHelp)

        wifiBox.orientation = LinearLayout.VERTICAL
        wifiBox.addView(field(address, "Mac address, for example 192.168.1.20", InputType.TYPE_CLASS_PHONE), LinearLayout.LayoutParams(-1, -2).apply { topMargin = ctx.dp(16) })
        wifiBox.addView(field(pin, "PIN shown in the Mac app", InputType.TYPE_CLASS_NUMBER), LinearLayout.LayoutParams(-1, -2).apply { topMargin = ctx.dp(10) })
        wifiBox.addView(TextView(ctx).apply {
            text = "Both are shown in the DrawPlay Mac app when Wi-Fi is selected."
            setTextColor(Colors.muted); textSize = 13f; setPadding(0, ctx.dp(8), 0, 0)
        })
        card.addView(wifiBox, LinearLayout.LayoutParams(-1, -2))

        val connect = TextView(ctx).apply {
            text = "Connect"; setTextColor(Color.WHITE); textSize = 17f; typeface = Typeface.DEFAULT_BOLD; gravity = Gravity.CENTER
            setPadding(0, ctx.dp(14), 0, ctx.dp(14)); background = roundedBg(ctx, Colors.accent, 14)
            setOnClickListener { onConnect(usb, address.text.toString().trim(), pin.text.toString().trim()) }
        }
        card.addView(connect, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ctx.dp(20) })

        ctrlRow.apply {
            textSize = 15f; setTextColor(Colors.text); gravity = Gravity.CENTER
            setPadding(ctx.dp(12), ctx.dp(12), ctx.dp(12), ctx.dp(12))
            setOnClickListener { setCtrlAsCmd(!ctrlAsCmd); onCtrlAsCmd(ctrlAsCmd) }
        }
        card.addView(ctrlRow, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ctx.dp(14) })

        close.apply {
            text = "Close"; setTextColor(Colors.muted); textSize = 15f; gravity = Gravity.CENTER
            setPadding(0, ctx.dp(14), 0, 0); visibility = View.GONE
            setOnClickListener { onClose() }
        }
        card.addView(close)

        val width = minOf(ctx.dp(520), ctx.resources.displayMetrics.widthPixels - ctx.dp(32))
        val scroll = ScrollView(ctx).apply { isFillViewport = true }
        val holder = FrameLayout(ctx)
        holder.addView(card, FrameLayout.LayoutParams(width, -2, Gravity.CENTER))
        scroll.addView(holder, FrameLayout.LayoutParams(-1, -2))
        addView(scroll, LayoutParams(-1, -1))
        setMode(true)
    }

    private fun setMode(isUsb: Boolean) {
        usb = isUsb
        usbTab.background = roundedBg(context, if (isUsb) Colors.accent else Color.TRANSPARENT, 11)
        wifiTab.background = roundedBg(context, if (!isUsb) Colors.accent else Color.TRANSPARENT, 11)
        usbTab.setTextColor(if (isUsb) Color.WHITE else Colors.muted)
        wifiTab.setTextColor(if (!isUsb) Color.WHITE else Colors.muted)
        usbHelp.visibility = if (isUsb) View.VISIBLE else View.GONE
        wifiBox.visibility = if (isUsb) View.GONE else View.VISIBLE
    }

    /** Keyboard cover: make Ctrl act as Command, so Ctrl+C copies on the Mac. */
    fun setCtrlAsCmd(on: Boolean) {
        ctrlAsCmd = on
        ctrlRow.text = if (on) "Keyboard: Ctrl works as Command (Ctrl+C copies)" else "Keyboard: Ctrl is Control (Cmd = Windows key)"
        ctrlRow.background = roundedBg(context, if (on) 0xFF24324F.toInt() else Colors.field, 12)
    }

    fun load(usbMode: Boolean, host: String, savedPin: String) { setMode(usbMode); address.setText(host); pin.setText(savedPin) }
    fun setStatus(text: String, color: Int = Colors.muted) { status.text = text; status.setTextColor(color) }
    fun showClose(show: Boolean) { close.visibility = if (show) View.VISIBLE else View.GONE }
}
