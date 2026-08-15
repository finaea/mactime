import AppKit

/// Small shared cache so the thumbnail strip and the hover preview don't hit
/// disk on every appearance.
enum ImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()

    static func image(path: String) async -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let loaded = await Task.detached(priority: .utility) { NSImage(contentsOfFile: path) }.value
        if let loaded { cache.setObject(loaded, forKey: path as NSString) }
        return loaded
    }
}
