// swift-tools-version: 6.2
import PackageDescription

// The pure parts of the iPhone app (storage layout, transcript formatting, chunking, prompts, Markdown),
// kept free of UIKit so they can be tested with `swift test` on a Mac or `xcodebuild test` on a simulator.
let package = Package(
    name: "MeetingCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "MeetingCore", targets: ["MeetingCore"])],
    targets: [
        .target(name: "MeetingCore"),
        .testTarget(name: "MeetingCoreTests", dependencies: ["MeetingCore"]),
    ]
)
