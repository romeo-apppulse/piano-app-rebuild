//
//  MonsterImageStoreTests.swift
//  PianoAppTests
//
//  Unit coverage for MonsterImageStore — the byte-handling core of the monster-art
//  picker. This is exactly the "silent regression" surface: a broken re-encode path
//  just eats art with no crash. Fixtures are drawn in-code (no binary assets) so the
//  test target stays a pure synchronized group.
//

import XCTest
import UIKit
@testable import PianoApp

final class MonsterImageStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MISTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    /// A solid square image. `opaque == false` leaves a transparent region so the
    /// encoded PNG carries a real alpha channel.
    private func makeImage(pixels: Int, opaque: Bool) -> UIImage {
        let size = CGSize(width: pixels, height: pixels)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            if opaque {
                UIColor.systemBlue.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            } else {
                UIColor.systemRed.setFill()               // only half filled → rest is transparent
                ctx.fill(CGRect(x: 0, y: 0, width: pixels / 2, height: pixels / 2))
            }
        }
    }

    private func writeSource(_ data: Data, ext: String) throws -> URL {
        let url = dir.appendingPathComponent("src-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    private func maxDimension(ofFileAt url: URL) throws -> Int {
        let cg = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        return max(cg.width, cg.height)
    }

    // MARK: - Copy-as-is (under the size threshold)

    func testStoresSmallImageAsIsPreservingLowercasedExtension() throws {
        let data = try XCTUnwrap(makeImage(pixels: 32, opaque: true).pngData())
        let src = try writeSource(data, ext: "PNG")            // uppercase → must be sanitized to lowercase

        let name = try MonsterImageStore.store(pickedFileAt: src, into: dir)

        XCTAssertTrue(name.hasSuffix(".png"), "extension preserved & lowercased, got \(name)")
        let stored = dir.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertEqual(try Data(contentsOf: stored), data, "copy-as-is must not re-encode the bytes")
        XCTAssertNotNil(UIImage(contentsOfFile: stored.path))
    }

    // MARK: - Rejection

    func testRejectsNonImageBytesAndWritesNothing() throws {
        let src = try writeSource(Data("definitely not an image".utf8), ext: "png")

        XCTAssertThrowsError(try MonsterImageStore.store(pickedFileAt: src, into: dir)) { error in
            XCTAssertEqual(error as? MonsterImageStore.StoreError, .notAnImage)
        }
        // A rejected pick must not leave a stored <uuid> file behind.
        let stored = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { !$0.hasPrefix("src-") }
        XCTAssertTrue(stored.isEmpty, "rejected image must not write bytes, found \(stored)")
    }

    // MARK: - Over-threshold re-encode

    func testOversizedOpaqueImageDownscalesAndReencodesAsJPEG() throws {
        let data = try XCTUnwrap(makeImage(pixels: 400, opaque: true).pngData())
        let src = try writeSource(data, ext: "png")

        // Tiny maxBytes forces the re-encode branch; small maxPixel forces a downscale.
        let name = try MonsterImageStore.store(pickedFileAt: src, into: dir, maxBytes: 500, maxPixel: 64)

        XCTAssertTrue(name.hasSuffix(".jpg"), "opaque re-encode → jpg, got \(name)")
        XCTAssertLessThanOrEqual(try maxDimension(ofFileAt: dir.appendingPathComponent(name)), 64)
    }

    func testOversizedAlphaImageReencodesAsPNGPreservingAlpha() throws {
        let data = try XCTUnwrap(makeImage(pixels: 400, opaque: false).pngData())
        let src = try writeSource(data, ext: "png")

        let name = try MonsterImageStore.store(pickedFileAt: src, into: dir, maxBytes: 500, maxPixel: 64)

        XCTAssertTrue(name.hasSuffix(".png"), "alpha re-encode → png (JPEG would composite onto black), got \(name)")
        let stored = dir.appendingPathComponent(name)
        XCTAssertLessThanOrEqual(try maxDimension(ofFileAt: stored), 64)
        let alpha = try XCTUnwrap(UIImage(contentsOfFile: stored.path)?.cgImage).alphaInfo
        let hasAlpha = alpha != .none && alpha != .noneSkipFirst && alpha != .noneSkipLast
        XCTAssertTrue(hasAlpha, "transparency must survive the re-encode, got alphaInfo \(alpha.rawValue)")
    }

    // MARK: - Bounded thumbnail

    func testThumbnailIsBoundedAndNilForMissingFile() throws {
        XCTAssertNil(MonsterImageStore.thumbnail(filename: "nope.png", in: dir, maxPixel: 64))

        let data = try XCTUnwrap(makeImage(pixels: 300, opaque: true).pngData())
        let src = try writeSource(data, ext: "png")
        let name = try MonsterImageStore.store(pickedFileAt: src, into: dir)   // stored full-size (300px)

        let thumb = try XCTUnwrap(MonsterImageStore.thumbnail(filename: name, in: dir, maxPixel: 64))
        let cg = try XCTUnwrap(thumb.cgImage)
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), 64, "thumbnail decode must be bounded")
    }
}
