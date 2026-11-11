package dev.drawplay

import android.view.KeyEvent

/** Android key codes -> macOS virtual key codes (US layout positions), for a physical keyboard on the tablet. */
object KeyMap {
    private val keys = HashMap<Int, Int>().apply {
        val letters = intArrayOf(0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6)   // A..Z
        for (i in letters.indices) put(KeyEvent.KEYCODE_A + i, letters[i])
        val digits = intArrayOf(29, 18, 19, 20, 21, 23, 22, 26, 28, 25)                                                       // 0..9
        for (i in digits.indices) put(KeyEvent.KEYCODE_0 + i, digits[i])
        val fkeys = intArrayOf(122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111)                                       // F1..F12
        for (i in fkeys.indices) put(KeyEvent.KEYCODE_F1 + i, fkeys[i])
        val pad = intArrayOf(82, 83, 84, 85, 86, 87, 88, 89, 91, 92)                                                          // numpad 0..9
        for (i in pad.indices) put(KeyEvent.KEYCODE_NUMPAD_0 + i, pad[i])
        put(KeyEvent.KEYCODE_ENTER, 36); put(KeyEvent.KEYCODE_NUMPAD_ENTER, 76); put(KeyEvent.KEYCODE_TAB, 48)
        put(KeyEvent.KEYCODE_SPACE, 49); put(KeyEvent.KEYCODE_DEL, 51); put(KeyEvent.KEYCODE_FORWARD_DEL, 117)
        put(KeyEvent.KEYCODE_ESCAPE, 53)
        put(KeyEvent.KEYCODE_DPAD_LEFT, 123); put(KeyEvent.KEYCODE_DPAD_RIGHT, 124)
        put(KeyEvent.KEYCODE_DPAD_DOWN, 125); put(KeyEvent.KEYCODE_DPAD_UP, 126)
        put(KeyEvent.KEYCODE_MOVE_HOME, 115); put(KeyEvent.KEYCODE_MOVE_END, 119)
        put(KeyEvent.KEYCODE_PAGE_UP, 116); put(KeyEvent.KEYCODE_PAGE_DOWN, 121)
        put(KeyEvent.KEYCODE_MINUS, 27); put(KeyEvent.KEYCODE_EQUALS, 24)
        put(KeyEvent.KEYCODE_LEFT_BRACKET, 33); put(KeyEvent.KEYCODE_RIGHT_BRACKET, 30); put(KeyEvent.KEYCODE_BACKSLASH, 42)
        put(KeyEvent.KEYCODE_SEMICOLON, 41); put(KeyEvent.KEYCODE_APOSTROPHE, 39)
        put(KeyEvent.KEYCODE_COMMA, 43); put(KeyEvent.KEYCODE_PERIOD, 47); put(KeyEvent.KEYCODE_SLASH, 44); put(KeyEvent.KEYCODE_GRAVE, 50)
        put(KeyEvent.KEYCODE_NUMPAD_ADD, 69); put(KeyEvent.KEYCODE_NUMPAD_SUBTRACT, 78); put(KeyEvent.KEYCODE_NUMPAD_MULTIPLY, 67)
        put(KeyEvent.KEYCODE_NUMPAD_DIVIDE, 75); put(KeyEvent.KEYCODE_NUMPAD_DOT, 65)
    }

    /** The Mac key for an Android key, or null if the key should not be forwarded (Back, volume, brightness...). */
    fun toMac(code: Int, ctrlAsCmd: Boolean): Int? = when (code) {
        KeyEvent.KEYCODE_SHIFT_LEFT -> 56; KeyEvent.KEYCODE_SHIFT_RIGHT -> 60
        KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_CTRL_RIGHT -> if (ctrlAsCmd) 55 else 59
        KeyEvent.KEYCODE_ALT_LEFT -> 58; KeyEvent.KEYCODE_ALT_RIGHT -> 61
        KeyEvent.KEYCODE_META_LEFT -> 55; KeyEvent.KEYCODE_META_RIGHT -> 54
        else -> keys[code]
    }

    /** Modifier bit sent to the Mac: 1 shift, 2 control, 4 option, 8 command (0 if the key is not a modifier). */
    fun modifierBit(code: Int, ctrlAsCmd: Boolean): Int = when (code) {
        KeyEvent.KEYCODE_SHIFT_LEFT, KeyEvent.KEYCODE_SHIFT_RIGHT -> 1
        KeyEvent.KEYCODE_CTRL_LEFT, KeyEvent.KEYCODE_CTRL_RIGHT -> if (ctrlAsCmd) 8 else 2
        KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_ALT_RIGHT -> 4
        KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_META_RIGHT -> 8
        else -> 0
    }

    /** The Mac modifier keys, used to release everything if the app loses focus. */
    val allModifierKeys = intArrayOf(54, 55, 56, 58, 59, 60, 61, 62)
}
