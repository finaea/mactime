import AppKit

/// JPEG encoding and the timeline thumbnail, in one place.
///
/// Two paths produce a thumbnail and they must produce the same one, or a
/// restored day scrubs differently from a recorded one: `ScreenshotService`
/// makes them from a live frame, and `ArchiveImport` makes them from a finished
/// JPEG, because the archive deliberately does not carry them — they are
/// derived, and shipping one per capture would double its entry count for bytes
/// the app can recompute.
///
/// Here rather than on `ScreenshotService` so import does not have to depend on
/// a tracker — which would drag ScreenCaptureKit into a path that only ever
/// handles bytes, and put both out of reach of the checks in Tests/.
enum Thumbnail {
    /// Points, not pixels. The timeline draws these at a fixed height and the
    /// hover preview scales from them, so the number lives with the code that
    /// makes them rather than in two call sites that could drift.
    static let height = 120
    static let quality = 0.7

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality as NSNumber])
    }

    static func scaled(_ image: CGImage, toHeight target: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard h > 0 else { return nil }
        let outH = target
        let outW = max(1, w * outH / h)
        guard let ctx = CGContext(data: nil, width: outW, height: outH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage()
    }

    /// From a live capture.
    static func of(_ image: CGImage) -> Data? {
        scaled(image, toHeight: height).flatMap { jpeg($0, quality: quality) }
    }

    /// From a capture that arrived as a finished JPEG — which is to say, one
    /// being restored from an archive.
    static func ofJPEG(_ data: Data) -> Data? {
        NSBitmapImageRep(data: data)?.cgImage.flatMap(of)
    }
}
