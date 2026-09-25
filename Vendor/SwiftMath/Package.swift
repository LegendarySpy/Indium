// swift-tools-version: 5.9
// Vendored from https://github.com/mgriebling/SwiftMath (MIT). Trimmed to the
// Latin Modern math font and given a small public typesetting entry point.
import PackageDescription

let package = Package(
    name: "SwiftMath",
    platforms: [.macOS(.v13)],
    products: [.library(name: "SwiftMath", targets: ["SwiftMath"])],
    targets: [
        .target(name: "SwiftMath", resources: [.copy("mathFonts.bundle")])
    ]
)
