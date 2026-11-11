# macOS 27 native touch: findings log

Goal: make macOS treat the Tab S8 as a real direct-touch screen (not just mouse events).
Everything here was read from the macOS 27.0 SDK, the dyld shared cache and disassembly on a
MacBook Air (Apple Silicon, macOS 27.2, build 26B123). Nothing here has been seen working.

## Verified facts (read from the system)

| Fact | How it was found |
|---|---|
| The touch code runs **inside WindowServer**. There is no separate `backboardd` process on macOS. | `com.apple.WindowServer.plist` has `_Conclave = com.apple.backboardd.conclave`; `com.apple.backboard.hid-services.xpc` is registered. |
| Touch classes exist and load: `BKHIDDirectTouchEventProcessor`, `BKDirectTouchState`, `BKTouchPadManager`, `BKTouchEventServer`, `UniversalHIDKit.DirectTouchEventTranslator`. | `dlopen` + ObjC runtime dump (see `docs/tools/`). |
| Devices are matched by HID usage: **page 13 (Digitizer)** with usage **4 (Touch Screen)**, **1 (Digitizer)** or **32 (Stylus)**. | Called `+[BKHIDDirectTouchEventProcessor digitizerMatchingDictionaries]`. |
| An **external touchscreen** is only accepted if feature flag `os_feature_enabled("backboardd","SupportExternalTouchscreen")` is on, the device has **no display assigned**, is **not built in**, has **`eventSource == 2`**, and is usage page 13 / usage 4. It is then assigned to **`_chamoisDisplayUUID`**. | Disassembly of `-[BKHIDDirectTouchEventProcessor _queue_displayUUIDForDigitizerService:]` and `_isPossibleChamoisTouchscreen:`. |
| "Chamois" is Apple's internal name for touch-capable Mac hardware (also `ChamoisSWKeyboard` in UIKit flags). | Flag names. Inference, not documented. |
| `DirectTouchEventType`, `SystemGestures`, `ModernSidecarProcessor` are already **FeatureComplete** in the WindowServer flag domain. | `/System/Library/FeatureFlags/Domain/WindowServer.plist`. |
| `SupportExternalTouchscreen` is **not declared** in any system flag file. No `backboardd` domain exists. | grep over `/System/Library/FeatureFlags`. |
| SkyLight has `SetSidecarTouchEnabled`, `kSLSHIDEventTypeDirectTouch`, per-window direct-touch event shapes. AppKit has `NSEventTypeDirectTouch`, `NSTouchTypeDirect`, `NSTouchDevice` add/remove notifications. | `.tbd` symbol lists, `NSEvent.h`, `NSTouch.h`. |
| Creating a virtual HID device (`HIDVirtualDevice`, CoreHID) fails without entitlement `com.apple.developer.hid.virtual.device`. Signing locally with it gets the process **SIGKILLed (exit 137)**. | Test program (`docs/tools/hid_virtual_device_test.swift`). |
| The feature flag table is **built once at boot** by `/usr/libexec/init_featureflags` into shared memory `com.apple.featureflags.shm`, from `/System/Library/FeatureFlags`, `.../Unified` and `/Library/Preferences/FeatureFlags`. It logs "Generating hash table with N enabled features of M known". The library also references `CSR_ALLOW_APPLE_INTERNAL`. | `strings` on `init_featureflags` and the shared cache. |

## Experiment log

1. Wrote `/Library/Preferences/FeatureFlags/Domain/backboardd.plist` with `SupportExternalTouchscreen = {Enabled: true}` (SIP on, no reboot).
   Result: `_os_feature_enabled_impl("backboardd","SupportExternalTouchscreen")` still returns **0**.
   Not conclusive: the table is only rebuilt at boot.
2. **Next: reboot, then re-run** `docs/tools/feature_flag_check.c` (queries four flags). If still 0, run a control test with an already-declared, currently-off flag to see whether `/Library` overrides are honored with SIP on at all.

## Open questions

- Does `init_featureflags` ignore the override because the feature is unknown, or because SIP is on (`CSR_ALLOW_APPLE_INTERNAL`)?
- What calls `-[BKHIDDirectTouchEventProcessor setChamoisDisplayUUID:]`? Not in any framework loaded so far. If nothing sets it on non-touch Macs, an accepted touchscreen gets no display.
- What does `eventSource == 2` mean, and would a virtual HID device report it?
- Which display would it map to? Could a virtual display (`CGVirtualDisplay` with spoofed IDs) be chosen?

## Routes to a native-touch device

| Route | Needs | Status |
|---|---|---|
| `HIDVirtualDevice` / `IOHIDUserDevice` virtual digitizer | Apple entitlement, or SIP + AMFI off (`amfi_get_out_of_my_way=0x1`, works on 27.3 beta per MacIsland) | Entitlement-less attempt killed |
| Real USB HID touchscreen from a microcontroller (RP2040/ESP32-S3) fed by the Mac daemon over serial | A $5 board; the feature flag still needs to be on | Not tried |
| Keep CGEvent mouse/scroll and add synthesized gestures | Nothing | Planned fallback |

## Reference

- MacIsland (https://github.com/MakrSas/MacIsland): enables hidden Dynamic Island on 27.3 beta by injecting a dylib that makes `IsAppleInternalBuild()` return true inside one process. Same style of unlock could be tried for the touch gate. Not reviewed or run.
- Touch Up (https://hci.rwth-aachen.de/touchup): user-space driver for USB touchscreens on macOS.

## The touch event chain (read from disassembly, macOS 27.2)

Read with `docs/tools/dis2.py` (lldb on a small program that dlopens the BackBoard frameworks; call targets are resolved to names). All of it runs inside WindowServer. Nothing here was observed with a live touch device.

1. **HID report becomes a digitizer IOHIDEvent.** A collection event with one "path" sub-event per finger (path index, normalized X/Y, touch flags, update masks). Standard HID touchscreen descriptors produce this.
2. **`-[BKHIDDirectTouchEventProcessor processEvent:sender:dispatcher:]`** picks the service, checks `primaryUsagePage`/`primaryUsage`, and calls `_handleDirectTouchEvent:service:`. Events from non-digitizer senders are logged and dropped ("ignoring digitizer event from non-digitizer sender").
3. **Per-event block** (`_handleDirectTouchEvent:service:_block_invoke`):
   - `_queue_displayUUIDForDigitizerService:` (the gate in the section above). No display means the event is dropped with "ignoring digitizer event for display … from unsupported service".
   - `_queue_digitizerStateForService:`. First event from a device logs "*** unknown digitizer … initializing now" and calls `_queue_addDigitizerStateForService:`.
   - `-[BKDirectTouchState handlePathCollectionEvent:]`.
4. **`BKDirectTouchState`** tracks update generations and per-path masks, builds `BKTouchContact` objects (`_contactsFromPathCollection:previousContacts:`), handles HID cancels ("cancel received from HID"), and calls `_stopTrackingNonTouchingPaths`.
5. **Hit testing:** `BKDirectTouchStateHitTester determineHitTestDestinationsForPathCollection:contacts:hitTestRegions:…` chooses the destination (window/context) per contact. The regions come from WindowServer (`setHitTestRegions:forDisplay:`, the per-window direct-touch shapes in SkyLight).
6. **Coordinates:** `_denormalizedLocationForNormalPoint:offset:` turns the digitizer's 0..1 point into display pixels, then `_contextLocationFromDenormalizedLocation:targetID:display:` converts to the window's space. So the display assignment in step 3 decides where a touch lands.
7. **Gestures:** `handleProcessGestures:touches:senderInfo:` feeds the system gesture recognizer (`gestureProcessorWrapper`); `sendSystemGestureDidCancelTouches:` cancels app touches when a system gesture wins.
8. **Delivery:** `_appendSubsetOfHIDCollection:forDestination:toEventPoster:…` and `_postCollectedUpdatedEvents:` hand events to `BKHIDEventCollector addEvent:attributes:forContext:`, which delivers to the target app. AppKit exposes them as `NSEventTypeDirectTouch` (`__NSSendDirectTouchesEvent`). `_BKHIDNoteUserEventOccurredOnDisplay` counts it as user activity.

### Log strings worth watching (not yet observed live)

`ignoring digitizer event for display %@ from unsupported service`, `*** unknown digitizer %@ -- initializing now`, `touchstreams: start sending isFirstDown:… lifted:…`, `cancel received from HID`, `old chamois display:%@ new chamois display:%@`.

## Prior research found online (2026-11-09)

- **glasses666/macos27-external-touch** (https://github.com/glasses666/macos27-external-touch): with the `backboardd` flag `SupportExternalTouchscreen` on (private FeatureFlags plist + reboot), a generic USB HID digitizer (page 0x0D, usage 0x04) is recognized and `NSScreen.touchCapabilities` flips from 0 to `MultiTouch`. But WindowServer logs `handle_digitizer_added: digitizer service has no usable displayUUID property; treating as no digitizer added`. `displayUUID` must be supplied by the HID service provider (driver) when the service is created. `IOHIDDeviceSetProperty` / `IOHIDServiceClientSetProperty` from user space, even from inside WindowServer, do not persist. Apple's own `HSTouchHIDService.plugin` supplies it for built-in multitouch.
- **efekurucay/anydisplay issue #1** (https://github.com/efekurucay/anydisplay/issues/1): AnyDisplay (Android tablet as Mac second screen, MIT) injects CGEvents like DrawPlay does. Untested lead: `HIDVirtualDevice.Properties(extraProperties:)` sets properties at creation, so a `displayUUID` passed there might reach the event service. Also: pressure from a generic HID digitizer is lost in SkyLight's HID-to-NX translation (arrives as 0, Apple forums thread 845787), so direct tablet CGEvents remain better for the pen.
- **Consequence for the Bluetooth-HID-from-Android idea:** a Bluetooth HID device is created by Apple's Bluetooth HID driver, so we cannot give it a `displayUUID`. It would hit the same wall. Only a device whose creator controls properties (HIDVirtualDevice with extraProperties, or a DriverKit HID service) can pass it.
- Related projects: AnyDisplay, SideScreen (Android second screen), MacTouch (USB touchscreen + CGEvent gestures), Topti (virtual stylus via CoreHID, entitlement pending), HIDTouch (documents the virtual-digitizer entitlement block).
- AppleInsider reports macOS 27 touch features also work with external displays and Sidecar: https://appleinsider.com/articles/26/11/04/macos-golden-gate-touch-features-work-with-external-displays-sidecar
