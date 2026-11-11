# Investigation helpers

Small throwaway programs used to inspect macOS 27 touch internals. Build with
`clang -isysroot "$(xcrun --show-sdk-path)" -fobjc-arc X.m -framework Foundation -o X`.

- `objc_dump.m`: dlopens the BackBoard/UniversalHID frameworks, dumps classes (pass class names as args).
- `matching_dicts.m`: prints `+[BKHIDDirectTouchEventProcessor digitizerMatchingDictionaries]`.
- `feature_flag_check.c`: asks `_os_feature_enabled_impl` about the touch-related flags.
- `dis.py`: lldb driver that disassembles ObjC methods and names the selector call targets. Needs a
  program `./t` that dlopens the frameworks and hits `__builtin_debugtrap()`. Use Apple's lldb at
  `/Library/Developer/CommandLineTools/usr/bin/lldb`, not the Android NDK one.
- `hid_virtual_device_test.swift`: creates a 10-finger virtual touchscreen with CoreHID. Needs the
  `com.apple.developer.hid.virtual.device` entitlement or it returns nil / gets killed.
