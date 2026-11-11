# DrawPlay: Sidecar-style second screen for an Android tablet (Galaxy Tab S8)

The Mac makes a virtual monitor, streams it to the tablet, and the tablet sends pen and touch back.

## Mac app

```
cd mac && ./scripts/make-app.sh      # builds mac/build/DrawPlay.app (bundles ../DrawPlay.apk)
open build/DrawPlay.app
```

1. Allow **Screen Recording** and **Accessibility** for DrawPlay (System Settings > Privacy & Security), then quit and reopen it.
2. Pick **USB cable** or **Wi-Fi**, choose a resolution, press Start.
   - USB: plug the tablet in with USB debugging on. The app sets up `adb reverse` and can install/open the tablet app.
   - Wi-Fi: in the tablet app tap the gear, enter the Mac's address and the PIN shown in the Mac app, tap Connect.

Rebuilding changes the app's signature, so macOS may ask for the permissions again.

## Command line (same engine)

```
cd mac && swift run drawplayd usb                       # then: adb reverse tcp:7878 tcp:7878
swift run drawplayd wifi --size 2560x1600 --hidpi       # prints a PIN for the tablet
swift run drawplayd --probe --size 2560x1600 --hidpi    # test the virtual display only, no permissions needed
```

## Tablet app

`cd android && gradle :app:assembleDebug`, then `app/build/outputs/apk/debug/app-debug.apk` (copy: `DrawPlay.apk`).

## Keyboard cover and trackpad

A physical keyboard on the tablet (for example the Galaxy Tab S8 Book Cover Keyboard) types on the Mac, including shortcuts and
key repeat. Its trackpad moves the pointer, clicks, right-clicks, drags and scrolls. In the tablet's Settings, "Ctrl works as Command"
(on by default) makes Ctrl+C / Ctrl+V copy and paste; turn it off to keep Ctrl as Control. Keys are sent by position (US layout),
so the Mac's own input source decides the characters. Check the Mac side with `swift run drawplayd --selftest-input`.

## Video quality

Standard, High (default) and Maximum use about 15, 30 and 60 Mbit/s at 2560 x 1600 and 60 fps (less at lower resolutions).
USB handles any of them; on Wi-Fi DrawPlay lowers the bitrate by itself if frames start dropping, and raises it again when the
network recovers. The bitrate is a ceiling: still screens use very little, and fast video or window motion uses more.
Check what your Mac's encoder can sustain with `swift run drawplayd --probe-encode --video --quality maximum`.

## Games that hide the mouse (Roblox, shooters)

Games hide the cursor and read raw mouse movement for camera look. DrawPlay watches for that on the Mac: when an app hides the
cursor, the tablet captures its trackpad (the tablet cursor disappears) and sends raw movement, which the Mac delivers as relative
mouse movement. It switches back when the game shows the cursor again. The toolbar's **Mouse lock** button forces it on for games
the automatic detection misses. Every mouse event now also carries its movement, so games that read it work in normal mode too.

## Focus mode

In the Mac app (or the menu bar, "Focus on app"), pick a running app while streaming: DrawPlay moves that app's window onto the
tablet's display and makes it full screen there, so the tablet shows only that app. Stopping puts the window back where it was.
It uses the Accessibility permission. Test it without a tablet: `swift run drawplayd --probe-focus "<app name>"`.

## Staying awake

While streaming, the Mac is kept awake (option in the Screen section, on by default) and the tablet keeps its screen on and Wi-Fi in low-latency mode.

## Tablet screen

A connect screen (USB or Wi-Fi) shows until the Mac is streaming. Afterwards a small status dot at the top right opens a toolbar:
Keyboard, Pen only (ignore fingers while drawing), Settings.

## Touch gestures

| Fingers | Gesture | Result on the Mac |
|---|---|---|
| 1 | tap / drag | click / drag (double-tap double-clicks) |
| 2 | slide | scroll, with momentum after a flick |
| 2 | pinch | zoom (works in Preview, Safari, Photos, Maps, Photoshop...) |
| 2 | twist | rotate |
| 2 | quick tap | right click |
| 3 | swipe left / right | next / previous Space (Control + arrow) |
| 3 | swipe up / down | Mission Control / App Exposé (Control + arrow) |

The three-finger swipes use the Mission Control keyboard shortcuts, so they need those enabled in System Settings > Keyboard > Keyboard Shortcuts.
Check the logic any time with `swift run drawplayd --selftest-touch` (no permissions needed).

## Security

Wi-Fi mode needs the PIN (5 wrong tries lock it for 30 s). USB mode accepts only connections from the Mac itself.
The connection is not encrypted, so use Wi-Fi mode on networks you trust.

## More

`docs/TOUCH_FINDINGS.md`: research on macOS 27 native touch. Architecture map: `DrawPlay Architecture Map.pdf`.
