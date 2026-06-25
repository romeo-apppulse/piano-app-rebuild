// swift-tools-version: 5.9
//
//  PianoCore — the UI-free domain + calculation layer for the PianoAppv2 rebuild.
//
//  Pure Foundation only (no SwiftUI/UIKit) so the combat-log model, the HP/average
//  engine, the leaderboards, and undo can be unit-tested in isolation via `swift test`
//  on any platform with a Swift toolchain — no iOS simulator required.
//
//  The iOS app target depends on this package; views/persistence live in the app.
//
import PackageDescription

let package = Package(
    name: "PianoCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "PianoCore", targets: ["PianoCore"]),
    ],
    targets: [
        .target(name: "PianoCore"),
        .testTarget(name: "PianoCoreTests", dependencies: ["PianoCore"]),
    ]
)
