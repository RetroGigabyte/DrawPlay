import Foundation

/// Tells whether an app (a game, usually) has hidden the cursor to read raw mouse movement.
/// The function exists in CoreGraphics but its header marks it unavailable, so it is looked up by name.
enum CursorWatch {
    private typealias VisibleFn = @convention(c) () -> UInt32
    private static let fn: VisibleFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(s, to: VisibleFn.self)
    }()

    static func isHidden() -> Bool { fn.map { $0() == 0 } ?? false }
}
