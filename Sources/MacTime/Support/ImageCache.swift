import AppKit

/// Small shared cache so the thumbnail strip and the hover preview don't hit
/// disk on every appearance.
enum ImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()

    /// Synchronous peek. Views read this inside `body` so a warm thumbnail draws
    /// in the same pass — `image(path:)` can only deliver one frame later, which
    /// on the hover preview means a visible placeholder flash.
    static func cached(path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    static func image(path: String) async -> NSImage? {
        if let hit = cached(path: path) { return hit }
        let loaded = await Task.detached(priority: .utility) { NSImage(contentsOfFile: path) }.value
        if let loaded { cache.setObject(loaded, forKey: path as NSString) }
        return loaded
    }
}
