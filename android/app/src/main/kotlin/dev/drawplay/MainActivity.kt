package dev.drawplay

import android.app.Activity
import android.content.Context
import android.content.pm.ActivityInfo
import android.net.wifi.WifiManager
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.view.Gravity
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.io.DataInputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Tablet -> Mac: an 8-byte hello ("DPLY" + PIN, little-endian), then 24-byte input packets
 * (see mac/Sources/DrawPlayCore/Packet.swift). Mac -> tablet: [u8 type][u32 len LE][payload]
 * with type 1 = SPS/PPS config, 2 = keyframe, 3 = delta frame (H.264 Annex-B).
 */
class Link(private val host: String, private val port: Int, private val pin: Int,
           private val greeting: () -> ByteArray?, private val onFrame: (Int, ByteArray) -> Unit) {
    private val q = LinkedBlockingQueue<ByteArray>(4096)
    @Volatile var connected = false
    @Volatile var gotFrame = false          // the Mac has sent at least one picture frame on this connection
    @Volatile var attempts = 0
    @Volatile private var stopped = false
    @Volatile private var sock: Socket? = null
    fun send(b: ByteArray) { if (!q.offer(b)) q.clear() }
    fun stop() { stopped = true; try { sock?.close() } catch (_: Exception) {} }

    private fun hello(): ByteArray =
        ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).put("DPLY".toByteArray()).putInt(pin).array()

    fun start() = thread(isDaemon = true) {
        while (!stopped) {
            attempts++
            try {
                Socket().use { s ->
                    sock = s
                    s.tcpNoDelay = true
                    s.receiveBufferSize = 2 shl 20              // room for big keyframes at high bitrates
                    s.connect(InetSocketAddress(host, port), 3000)
                    val out: OutputStream = s.getOutputStream()
                    out.write(hello())
                    greeting()?.let { out.write(it) }      // current screen orientation
                    out.flush()
                    connected = true; gotFrame = false
                    q.clear()
                    thread(isDaemon = true) {
                        try {
                            val inp = DataInputStream(s.getInputStream().buffered(2 shl 20))
                            val hdr = ByteArray(5)
                            while (!stopped) {
                                inp.readFully(hdr)
                                val len = ByteBuffer.wrap(hdr, 1, 4).order(ByteOrder.LITTLE_ENDIAN).int
                                if (len < 0 || len > 16_000_000) break
                                val buf = ByteArray(len); inp.readFully(buf)
                                if (hdr[0].toInt() < 4 && hdr[0].toInt() > 0) gotFrame = true      // a picture frame (not a control message)
                                onFrame(hdr[0].toInt(), buf)
                            }
                        } catch (_: Exception) {}
                        try { s.close() } catch (_: Exception) {}
                    }
                    while (!stopped && !s.isClosed) {
                        val b = q.poll(500, TimeUnit.MILLISECONDS)
                        if (b != null) { out.write(b); out.flush() }
                    }
                }
            } catch (_: Exception) {}
            connected = false; gotFrame = false
            if (!stopped) Thread.sleep(1000)
        }
    }
}

class Decoder(surface: Surface) {
    private val codec = MediaCodec.createDecoderByType("video/avc")
    private val info = MediaCodec.BufferInfo()
    private var released = false
    private var needKey = true   // discard deltas until a full keyframe arrives
    private var lastConfig: ByteArray? = null

    init {
        val f = MediaFormat.createVideoFormat("video/avc", 2560, 1600)
        f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 6 shl 20)        // a keyframe at maximum quality can be several MB
        f.setInteger(MediaFormat.KEY_MAX_WIDTH, 2560); f.setInteger(MediaFormat.KEY_MAX_HEIGHT, 2560)   // landscape or portrait
        codec.configure(f, surface, null, 0)
        codec.start()
    }

    @Synchronized fun feed(type: Int, data: ByteArray) {
        if (released) return
        try {
            if (type == 1) {                    // new SPS/PPS: the Mac changed size (screen turned), so start the decoder fresh
                if (lastConfig != null && !lastConfig!!.contentEquals(data)) { codec.flush(); needKey = true }
                lastConfig = data
            }
            if (type == 2) needKey = false
            if (type == 3 && needKey) return
            val flags = when (type) { 1 -> MediaCodec.BUFFER_FLAG_CODEC_CONFIG; 2 -> MediaCodec.BUFFER_FLAG_KEY_FRAME; else -> 0 }
            val i = codec.dequeueInputBuffer(100_000)
            if (i >= 0) {
                val buf = codec.getInputBuffer(i)!!
                buf.clear()
                if (data.size > buf.capacity()) {               // too big for this buffer: skip it and wait for a fresh keyframe
                    codec.queueInputBuffer(i, 0, 0, 0, 0); needKey = true; return
                }
                buf.put(data)
                codec.queueInputBuffer(i, 0, data.size, System.nanoTime() / 1000, flags)
            } else if (type != 1) needKey = true   // lost a frame: wait for the next keyframe (<= 2 s)
            while (true) {
                val o = codec.dequeueOutputBuffer(info, 0)
                if (o >= 0) codec.releaseOutputBuffer(o, true) else if (o != MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) break
            }
        } catch (_: Exception) {}
    }

    @Synchronized fun release() { released = true; try { codec.stop(); codec.release() } catch (_: Exception) {} }
}

/**
 * Captures pen and finger input. Pen samples keep the batched history Android collects between
 * events (smooth strokes). Fingers are ignored while the pen is near, and lifted if it arrives.
 */
class PadView(ctx: Context, var link: Link?) : View(ctx) {
    private val fingerPos = HashMap<Int, FloatArray>()      // active fingers: last x, y (pixels)
    private val rejected = HashSet<Int>()                    // fingers ignored as palms
    private var penNearUntil = 0L
    init { isFocusable = true; isFocusableInTouchMode = true }          // pointer capture needs a focused view

    // ---- game mouse lock: like Roblox on Android, hide the tablet's cursor and send raw movement instead
    private var macLocked = false
    /** The Mouse lock button: capture the trackpad even if the Mac does not report a hidden cursor. */
    var forcedLock = false
        set(v) { field = v; updateCapture() }
    private var capturing = false
    private var capButtons = 0
    private var padX = 0f
    private var padY = 0f

    fun setMacLock(on: Boolean) { macLocked = on; updateCapture() }
    fun reapplyCapture() { capturing = false; updateCapture() }

    private fun updateCapture() = post {
        val want = macLocked || forcedLock
        if (want && !capturing) { requestFocus(); requestPointerCapture(); capturing = true }
        else if (!want && capturing) { releasePointerCapture(); capturing = false; capButtons = 0 }
    }

    override fun onPointerCaptureChange(hasCapture: Boolean) {
        super.onPointerCaptureChange(hasCapture)
        capturing = hasCapture
        if (!hasCapture) capButtons = 0
    }

    /** Relative mouse packet (kind 5, byte 2 = 1): x, y are movement as a fraction of the screen. */
    private fun sendRelative(action: Int, buttons: Int, dx: Float, dy: Float) {
        if (width == 0 || height == 0) return
        val b = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN)
        b.put(5).put(action.toByte()).put(1).put(buttons.toByte()).putFloat(dx / width).putFloat(dy / height)
        link?.send(b.array())
    }

    override fun onCapturedPointerEvent(e: MotionEvent): Boolean {
        val a = e.actionMasked
        var dx = 0f; var dy = 0f
        if (a == MotionEvent.ACTION_MOVE || a == MotionEvent.ACTION_HOVER_MOVE) {
            if (e.isFromSource(InputDevice.SOURCE_MOUSE_RELATIVE)) {          // a mouse: x, y already are the movement
                for (h in 0 until e.historySize) { dx += e.getHistoricalX(h); dy += e.getHistoricalY(h) }
                dx += e.x; dy += e.y
            } else if (e.isFromSource(InputDevice.SOURCE_TOUCHPAD) && a == MotionEvent.ACTION_MOVE) {   // a touchpad: absolute, so take the difference
                val range = e.device?.getMotionRange(MotionEvent.AXIS_X, e.source)
                val k = if (range != null && range.range > 0) width * 0.7f / range.range else 1f
                dx = (e.x - padX) * k; dy = (e.y - padY) * k
            }
        }
        if (e.isFromSource(InputDevice.SOURCE_TOUCHPAD)) { padX = e.x; padY = e.y }
        if (a == MotionEvent.ACTION_SCROLL) sendWheel(e.getAxisValue(MotionEvent.AXIS_HSCROLL), e.getAxisValue(MotionEvent.AXIS_VSCROLL))
        if (dx != 0f || dy != 0f) sendRelative(if (capButtons != 0) 3 else 2, capButtons, dx, dy)
        val mask = buttonMask(e.buttonState)
        if (mask != capButtons) {
            for (bit in intArrayOf(1, 2, 4)) {
                val was = capButtons and bit != 0; val now = mask and bit != 0
                if (now && !was) sendRelative(0, bit, 0f, 0f) else if (!now && was) sendRelative(1, bit, 0f, 0f)
            }
            capButtons = mask
        }
        return true
    }

    /** Pen only: fingers are ignored completely (rest your hand on the screen while drawing). */
    var penOnly = false

    /** Kind 4: screen orientation, action 0 landscape / 1 portrait. */
    fun orientationPacket(): ByteArray? {
        if (width == 0 || height == 0) return null
        return ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN).put(4).put(if (height > width) 1 else 0).array()
    }

    override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
        super.onSizeChanged(w, h, ow, oh)
        orientationPacket()?.let { link?.send(it) }          // the tablet was turned
    }

    private fun penNear() = SystemClock.uptimeMillis() < penNearUntil

    private fun markPen() {
        if (!penNear()) cancelFingers()
        penNearUntil = SystemClock.uptimeMillis() + 500
    }

    private fun cancelFingers() {
        for ((id, p) in fingerPos) send(2, 2, id, 0, p[0], p[1], 0f, 0f, 0f)
        fingerPos.clear()
    }

    private fun send(kind: Int, action: Int, id: Int, buttons: Int, x: Float, y: Float, pressure: Float, tilt: Float, ori: Float) {
        if (width == 0 || height == 0) return
        val b = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN)
        b.put(kind.toByte()).put(action.toByte()).put(id.toByte()).put(buttons.toByte())
        b.putFloat((x / width).coerceIn(0f, 1f))
        b.putFloat((y / height).coerceIn(0f, 1f))
        b.putFloat(pressure.coerceIn(0f, 1f))
        // tilt: 0..pi/2 away from vertical, ori: direction of the lean
        b.putFloat((Math.sin(ori.toDouble()) * tilt / (Math.PI / 2)).toFloat())
        b.putFloat((-Math.cos(ori.toDouble()) * tilt / (Math.PI / 2)).toFloat())
        link?.send(b.array())
    }

    private fun isPen(e: MotionEvent, i: Int) =
        e.getToolType(i) == MotionEvent.TOOL_TYPE_STYLUS || e.getToolType(i) == MotionEvent.TOOL_TYPE_ERASER

    private fun penKind(e: MotionEvent, i: Int) = if (e.getToolType(i) == MotionEvent.TOOL_TYPE_ERASER) 1 else 0

    private fun penButtons(e: MotionEvent) =
        (if (e.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY != 0) 1 else 0) or
        (if (e.buttonState and MotionEvent.BUTTON_STYLUS_SECONDARY != 0) 2 else 0)

    private fun sendPen(e: MotionEvent, i: Int, action: Int) {
        val id = e.getPointerId(i)
        val pressure = if (action == 2 || action == 3 || action == 4) 0f else e.getPressure(i)
        send(penKind(e, i), action, id, penButtons(e), e.getX(i), e.getY(i), pressure,
             e.getAxisValue(MotionEvent.AXIS_TILT, i), e.getOrientation(i))
    }

    private fun down(e: MotionEvent, i: Int) {
        val id = e.getPointerId(i)
        if (isPen(e, i)) { markPen(); sendPen(e, i, 0); return }
        if (penOnly) { rejected.add(id); return }
        if (penNear()) { rejected.add(id); return }           // palm resting while writing
        fingerPos[id] = floatArrayOf(e.getX(i), e.getY(i))
        send(2, 0, id, 0, e.getX(i), e.getY(i), e.getPressure(i), 0f, 0f)
    }

    private fun move(e: MotionEvent, i: Int) {
        val id = e.getPointerId(i)
        if (isPen(e, i)) {
            markPen()
            for (h in 0 until e.historySize) {                  // batched samples between frames
                send(penKind(e, i), 1, id, penButtons(e), e.getHistoricalX(i, h), e.getHistoricalY(i, h),
                     e.getHistoricalPressure(i, h), e.getHistoricalAxisValue(MotionEvent.AXIS_TILT, i, h),
                     e.getHistoricalOrientation(i, h))
            }
            sendPen(e, i, 1)
            return
        }
        if (id in rejected) return
        if (penOnly) { rejected.add(id); return }
        if (penNear()) {                                        // pen arrived while this finger was down
            fingerPos[id]?.let { send(2, 2, id, 0, it[0], it[1], 0f, 0f, 0f) }
            fingerPos.remove(id); rejected.add(id); return
        }
        fingerPos[id] = floatArrayOf(e.getX(i), e.getY(i))
        send(2, 1, id, 0, e.getX(i), e.getY(i), e.getPressure(i), 0f, 0f)
    }

    private fun up(e: MotionEvent, i: Int) {
        val id = e.getPointerId(i)
        if (isPen(e, i)) { markPen(); sendPen(e, i, 2); return }
        if (rejected.remove(id)) return
        fingerPos.remove(id)
        send(2, 2, id, 0, e.getX(i), e.getY(i), 0f, 0f, 0f)
    }

    // ---- mouse / trackpad (e.g. the keyboard cover): absolute position on the screen, like the touch screen
    private var mouseButtons = 0

    private fun isMouse(e: MotionEvent) =
        e.getToolType(0) == MotionEvent.TOOL_TYPE_MOUSE || e.isFromSource(InputDevice.SOURCE_MOUSE)

    private fun buttonMask(state: Int) =
        (if (state and MotionEvent.BUTTON_PRIMARY != 0) 1 else 0) or
        (if (state and MotionEvent.BUTTON_SECONDARY != 0) 2 else 0) or
        (if (state and MotionEvent.BUTTON_TERTIARY != 0) 4 else 0)

    /** Kind 5: action 0 down, 1 up, 2 move, 3 drag; buttons 1 left, 2 right, 4 middle. */
    private fun sendMouse(action: Int, buttons: Int, x: Float, y: Float) {
        if (width == 0 || height == 0) return
        val b = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN)
        b.put(5).put(action.toByte()).put(0).put(buttons.toByte())
        b.putFloat((x / width).coerceIn(0f, 1f)).putFloat((y / height).coerceIn(0f, 1f))
        link?.send(b.array())
    }

    /** Kind 6: wheel amounts (Android axis values: positive = up / right). */
    private fun sendWheel(h: Float, v: Float) {
        val b = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN)
        b.put(6).put(0).put(0).put(0).putFloat(h).putFloat(v)
        link?.send(b.array())
    }

    private fun mouseTouch(e: MotionEvent): Boolean {
        val m = buttonMask(e.buttonState)
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { mouseButtons = if (m != 0) m else 1; sendMouse(0, mouseButtons, e.x, e.y) }
            MotionEvent.ACTION_MOVE -> sendMouse(3, mouseButtons, e.x, e.y)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { sendMouse(1, mouseButtons, e.x, e.y); mouseButtons = 0 }
        }
        return true
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (isMouse(e)) return mouseTouch(e)
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> down(e, e.actionIndex)
            MotionEvent.ACTION_MOVE -> for (i in 0 until e.pointerCount) move(e, i)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> up(e, e.actionIndex)
            MotionEvent.ACTION_CANCEL -> { for (i in 0 until e.pointerCount) up(e, i); cancelFingers(); rejected.clear() }
        }
        return true
    }

    override fun onGenericMotionEvent(e: MotionEvent): Boolean {
        val a = e.actionMasked
        if (isMouse(e)) {
            when (a) {
                MotionEvent.ACTION_HOVER_MOVE, MotionEvent.ACTION_HOVER_ENTER -> sendMouse(2, 0, e.x, e.y)
                MotionEvent.ACTION_SCROLL -> sendWheel(e.getAxisValue(MotionEvent.AXIS_HSCROLL), e.getAxisValue(MotionEvent.AXIS_VSCROLL))
            }
            return true
        }
        if (a == MotionEvent.ACTION_HOVER_MOVE || a == MotionEvent.ACTION_HOVER_ENTER || a == MotionEvent.ACTION_HOVER_EXIT) {
            if (!isPen(e, 0)) return super.onGenericMotionEvent(e)
            markPen()
            sendPen(e, 0, if (a == MotionEvent.ACTION_HOVER_EXIT) 4 else 3)
            return true
        }
        return super.onGenericMotionEvent(e)
    }
}

/** Key packet: kind 3, action 0 down / 1 up, byte 2 = 1 for a repeat, key code in bytes 4-5, modifier bits in byte 3
 *  (1 shift, 2 control, 4 option, 8 command, 16 caps lock). */
fun keyPacket(code: Int, down: Boolean, mods: Int, repeat: Boolean = false): ByteArray {
    val b = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN)
    b.put(3).put(if (down) 0 else 1).put(if (repeat) 1 else 0).put(mods.toByte()).putShort(code.toShort())
    return b.array()
}

class MainActivity : Activity() {
    private var link: Link? = null
    private var decoder: Decoder? = null
    private lateinit var pad: PadView
    private lateinit var connectScreen: ConnectScreen
    private var settingsOpen = false
    private var usbMode = true
    private var ctrlAsCmd = true
    private var heldMods = 0
    private var wifiLock: WifiManager.WifiLock? = null
    private val ui = Handler(Looper.getMainLooper())

    private fun connect(host: String, pin: String) {
        link?.stop()
        val p = pin.trim().toLongOrNull()?.toInt() ?: 0
        link = Link(host.trim().ifEmpty { "127.0.0.1" }, 7878, p, { pad.orientationPacket() }) { t, d ->
            when (t) {
                4 -> applyOrientation(d.firstOrNull()?.toInt() ?: 0)
                6 -> pad.setMacLock(d.firstOrNull()?.toInt() == 1)      // a Mac game hid its cursor: capture the trackpad too
                5 -> {                                          // ping from the Mac: send the same 8 bytes straight back
                    val b = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN).put(7).put(0).put(0).put(0)
                    b.put(d, 0, minOf(8, d.size)); link?.send(b.array())
                }
                else -> decoder?.feed(t, d)
            }
        }.also { it.start() }
        pad.link = link
    }

    /** From the Mac: 0 = Auto (follow the tablet's rotation), 1 = keep landscape, 2 = keep portrait. */
    private fun applyOrientation(mode: Int) {
        val want = when (mode) {
            1 -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            2 -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
            else -> ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
        }
        runOnUiThread { if (requestedOrientation != want) requestedOrientation = want }
    }

    override fun onCreate(s: Bundle?) {
        super.onCreate(s)
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR     // follow the tablet until the Mac says otherwise
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)         // the tablet never sleeps while DrawPlay is open
        window.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Colors.bg))
        try {                                                                   // keep Wi-Fi in its fastest mode too
            val wm = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "drawplay").apply { setReferenceCounted(false); acquire() }
        } catch (_: Exception) {}

        val prefs = getSharedPreferences("drawplay", MODE_PRIVATE)
        // USB: host 127.0.0.1 (the Mac app runs `adb reverse`). Wi-Fi: the Mac's IP and the PIN shown in the Mac app.
        val extraHost = intent.getStringExtra("host")
        val savedHost = prefs.getString("host", "") ?: ""
        val savedPin = intent.getStringExtra("pin") ?: prefs.getString("pin", "") ?: ""
        ctrlAsCmd = prefs.getBoolean("ctrlAsCmd", true)
        usbMode = if (extraHost != null) (extraHost == "127.0.0.1" || extraHost == "localhost") else prefs.getBoolean("usb", true)
        val startHost = extraHost ?: if (usbMode) "127.0.0.1" else savedHost

        val root = FrameLayout(this)
        val video = SurfaceView(this)
        video.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(h: SurfaceHolder) { decoder = Decoder(h.surface) }
            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, hh: Int) {}
            override fun surfaceDestroyed(h: SurfaceHolder) { decoder?.release(); decoder = null }
        })
        root.addView(video)
        pad = PadView(this, null)          // transparent: sits on top of the video, captures pen + touch
        pad.penOnly = prefs.getBoolean("penOnly", false)
        root.addView(pad)

        val osk = Osk(this) { code, down, mods -> link?.send(keyPacket(code, down, mods)) }.apply { visibility = View.GONE }
        root.addView(osk, FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM))

        // ---- toolbar: a small status dot that opens a row of buttons, which tucks itself away again
        val handle = TextView(this).apply {
            text = "●"; textSize = 22f; gravity = Gravity.CENTER; setTextColor(Colors.bad)
            background = roundedBg(this@MainActivity, 0xAA101216.toInt(), 22)
            setPadding(dp(14), dp(8), dp(14), dp(8))
        }
        val bar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; visibility = View.GONE }
        val collapse = Runnable { bar.visibility = View.GONE }
        fun keepOpen() { ui.removeCallbacks(collapse); ui.postDelayed(collapse, 5000) }
        val kbPill = pill(this, "Keyboard") { osk.visibility = if (osk.visibility == View.VISIBLE) View.GONE else View.VISIBLE; keepOpen() }
        val penPill = pill(this, "Pen only") {}.also { p ->
            p.setActive(pad.penOnly)
            p.setOnClickListener {
                pad.penOnly = !pad.penOnly; p.setActive(pad.penOnly)
                prefs.edit().putBoolean("penOnly", pad.penOnly).apply(); keepOpen()
            }
        }
        val lockPill = pill(this, "Mouse lock") {}.also { p ->
            p.setOnClickListener { pad.forcedLock = !pad.forcedLock; p.setActive(pad.forcedLock); keepOpen() }
        }
        val settingsPill = pill(this, "Settings") {
            settingsOpen = true; connectScreen.showClose(true); connectScreen.visibility = View.VISIBLE; bar.visibility = View.GONE
        }
        for (v in listOf(kbPill, penPill, lockPill, settingsPill)) bar.addView(v, LinearLayout.LayoutParams(-2, -2).apply { rightMargin = dp(8) })
        handle.setOnClickListener {
            if (bar.visibility == View.VISIBLE) { bar.visibility = View.GONE; ui.removeCallbacks(collapse) } else { bar.visibility = View.VISIBLE; keepOpen() }
        }
        root.addView(LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; addView(bar); addView(handle) },
            FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.END).apply { topMargin = dp(10); rightMargin = dp(12) })

        // ---- connect screen on top of everything
        connectScreen = ConnectScreen(this,
            onConnect = { usb, host, pin ->
                usbMode = usb
                prefs.edit().putBoolean("usb", usb).putString("host", host).putString("pin", pin).apply()
                settingsOpen = false
                connect(if (usb) "127.0.0.1" else host, if (usb) "" else pin)
                (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(root.windowToken, 0)
            },
            onClose = { settingsOpen = false },
            onCtrlAsCmd = { v -> ctrlAsCmd = v; prefs.edit().putBoolean("ctrlAsCmd", v).apply() })
        connectScreen.load(usbMode, savedHost, savedPin)
        connectScreen.setCtrlAsCmd(ctrlAsCmd)
        root.addView(connectScreen, FrameLayout.LayoutParams(-1, -1))

        // ---- keep the screen and the status dot in step with the connection
        ui.post(object : Runnable { override fun run() {
            val l = link
            val live = l?.connected == true && l.gotFrame
            if (l?.connected != true) pad.setMacLock(false)
            handle.setTextColor(if (live) Colors.good else if (l?.connected == true) Colors.warn else Colors.bad)
            if (live && !settingsOpen) connectScreen.visibility = View.GONE
            else if (!live) { connectScreen.visibility = View.VISIBLE; connectScreen.showClose(false) }
            connectScreen.setStatus(when {
                live -> "Connected"
                l?.connected == true -> "Connected, waiting for the picture…"
                (l?.attempts ?: 0) <= 1 -> "Looking for your Mac…"
                usbMode -> "Can't reach the Mac. Plug in the cable and press Start USB in the Mac app."
                else -> "Can't reach the Mac. Check the address and PIN, and that DrawPlay is running on the Mac."
            }, if (live) Colors.good else Colors.muted)
            ui.postDelayed(this, 400)
        } })

        setContentView(root)
        connect(startHost, savedPin)
    }

    /** A physical keyboard (for example the keyboard cover) types on the Mac. */
    override fun dispatchKeyEvent(e: KeyEvent): Boolean {
        if (connectScreen.visibility == View.VISIBLE) return super.dispatchKeyEvent(e)     // typing the address / PIN
        val mac = KeyMap.toMac(e.keyCode, ctrlAsCmd) ?: return super.dispatchKeyEvent(e)   // Back, volume... stay with Android
        val down = e.action == KeyEvent.ACTION_DOWN
        val bit = KeyMap.modifierBit(e.keyCode, ctrlAsCmd)
        if (bit != 0) heldMods = if (down) heldMods or bit else heldMods and bit.inv()
        val mods = heldMods or (if (e.isCapsLockOn) 16 else 0)
        link?.send(keyPacket(mac, down, mods, down && e.repeatCount > 0))
        return true
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) pad.reapplyCapture()                  // Android releases pointer capture when the window loses focus
        if (!hasFocus) {                                    // never leave Shift / Command held down on the Mac
            heldMods = 0
            for (k in KeyMap.allModifierKeys) link?.send(keyPacket(k, false, 0))
        }
        if (hasFocus) window.insetsController?.apply {
            hide(WindowInsets.Type.systemBars())
            systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    override fun onDestroy() {
        link?.stop()
        try { wifiLock?.release() } catch (_: Exception) {}
        super.onDestroy()
    }
}
