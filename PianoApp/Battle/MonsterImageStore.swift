//
//  MonsterImageStore.swift
//  PianoApp
//
//  The byte-handling core of the monster-art picker: land a picked image into our own
//  directory under a name we control, and read it back with a bounded (memory-flat) decode.
//  UI-free and directory-agnostic so it is unit-testable without a picker or the real
//  Documents sandbox (see MonsterImageStoreTests).
//
//  Invariants this type upholds:
//    • Every write mints a FRESH <uuid> filename — never an overwrite-in-place. Callers rely
//      on this: it keeps "replace art" atomic (no OS-cached stale image) and, because a given
//      filename's bytes are therefore immutable for life, makes the thumbnail cache below
//      invalidation-free. Do NOT "optimize" this into reusing/overwriting a filename.
//    • The previous file is intentionally left on disk by callers on replace (the rolling
//      appState.json .bak backups may still reference it) — orphan cleanup is separate,
//      deferred work and is NOT this type's job.
//

import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

enum MonsterImageStore {
    enum StoreError: Error, Equatable { case notAnImage, writeFailed }

    /// Copy a picked image into `directory` under a fresh `<uuid>.<ext>`.
    ///
    /// - Validates the source decodes as an image (via ImageIO) → else `.notAnImage`,
    ///   writing nothing.
    /// - `count <= maxBytes`: copy the bytes **as-is** (zero re-encode → no quality loss on
    ///   hand-drawn art), preserving a sanitized lowercase extension.
    /// - `count > maxBytes`: downscale (longest edge ≤ `maxPixel`) and re-encode, so a stray
    ///   full-res scan can't bloat the sandbox. Re-encodes as **PNG when the source has an
    ///   alpha channel** (JPEG would composite transparency onto black), otherwise JPEG.
    ///
    /// `maxPixel` defaults to 1600: the battle view renders art at ~360 pt (~720 px @2×), so
    /// 1600 px on the longest edge is already >2× display needs — deliberately not larger.
    ///
    /// - Returns: the generated filename (never a path).
    static func store(pickedFileAt sourceURL: URL,
                      into directory: URL,
                      maxBytes: Int = 15_000_000,
                      maxPixel: CGFloat = 1600) throws -> String {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let uti = CGImageSourceGetType(source),
              CGImageSourceGetCount(source) > 0 else {
            throw StoreError.notAnImage
        }

        // Unknown size → treat as oversized (re-encode is the safe default over copying an
        // unbounded file we couldn't measure).
        let byteCount = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max

        if byteCount <= maxBytes {
            let ext = sanitizedExtension(from: sourceURL, sourceType: uti)
            let name = "\(UUID().uuidString).\(ext)"
            do {
                try FileManager.default.copyItem(at: sourceURL, to: directory.appendingPathComponent(name))
            } catch {
                throw StoreError.writeFailed
            }
            return name
        }

        return try downscaleAndReencode(source: source, into: directory, maxPixel: maxPixel)
    }

    /// Bounded thumbnail decode: ImageIO scales down *while decoding*, so peak memory tracks
    /// `maxPixel`, not the source resolution. Cached by filename+size; the cache never needs
    /// invalidating because filenames are immutable-for-life (see the type's header).
    static func thumbnail(filename: String, in directory: URL, maxPixel: CGFloat) -> UIImage? {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let key = "\(filename)@\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = downscaledImage(from: source, maxPixel: maxPixel) else { return nil }

        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Private

    private static let cache = NSCache<NSString, UIImage>()

    private static func downscaleAndReencode(source: CGImageSource,
                                             into directory: URL,
                                             maxPixel: CGFloat) throws -> String {
        guard let cg = downscaledImage(from: source, maxPixel: maxPixel) else {
            throw StoreError.writeFailed
        }

        // PNG when the source carries transparency, else JPEG — see doc comment.
        var hasAlpha = false
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let flag = props[kCGImagePropertyHasAlpha] as? Bool {
            hasAlpha = flag
        }

        // Fixed, conventional extensions (UTType.jpeg prefers "jpeg"; we standardize on "jpg").
        let type: UTType = hasAlpha ? .png : .jpeg
        let ext = hasAlpha ? "png" : "jpg"
        let name = "\(UUID().uuidString).\(ext)"
        let dest = directory.appendingPathComponent(name)

        guard let destination = CGImageDestinationCreateWithURL(dest as CFURL,
                                                                type.identifier as CFString, 1, nil) else {
            throw StoreError.writeFailed
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw StoreError.writeFailed }
        return name
    }

    private static func downscaledImage(from source: CGImageSource, maxPixel: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Lowercase, allow only a short alphanumeric run; fall back to the extension implied by
    /// the source's UTI (or "img") when the picked file's extension is missing or odd.
    private static func sanitizedExtension(from url: URL, sourceType uti: CFString) -> String {
        let ext = url.pathExtension.lowercased()
        if (1...5).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return ext
        }
        return UTType(uti as String)?.preferredFilenameExtension ?? "img"
    }
}
