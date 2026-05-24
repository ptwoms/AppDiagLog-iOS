// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AppDiagLog",
    platforms: [ .iOS(.v15), .macOS(.v12) ],
    products: [
        .library(name: "AppDiagLog", targets: ["AppDiagLog"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AppDiagLog",
            path: "Sources/AppDiagLog"
        ),
        .testTarget(
            name: "AppDiagLogTests",
            dependencies: ["AppDiagLog"],
            path: "Tests/AppDiagLogTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
