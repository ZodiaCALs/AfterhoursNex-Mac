// swift-tools-version: 6.2
// AfterhoursNex for Mac: a native SwiftUI app in Liquid Glass. Build the app with Scripts/build-app.sh, or open this folder in Xcode.
import PackageDescription

let package = Package(
    name: "AfterhoursNex",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "AfterhoursNex", path: "Sources/AfterhoursNex",
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("MediaPlayer"), .linkedFramework("Speech"), .linkedFramework("Network")])
    ],
    swiftLanguageModes: [.v5]
)
