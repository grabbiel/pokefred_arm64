// swift-tools-version: 5.9
import PackageDescription

// The map model is pure Swift so it can be tested off macOS.
// The AppKit + Metal executable is declared only when the package is
// evaluated on a Mac, which is also the only place it can compile.
var products: [Product] = [
    .library(name: "ShuverseMapModel", targets: ["ShuverseMapModel"]),
]

var targets: [Target] = [
    .target(name: "ShuverseMapModel"),
    .testTarget(
        name: "ShuverseMapModelTests",
        dependencies: ["ShuverseMapModel"]
    ),
]

#if os(macOS)
products.append(
    .executable(name: "ShuverseEditor", targets: ["ShuverseEditor"])
)
targets.append(
    .executableTarget(
        name: "ShuverseEditor",
        dependencies: ["ShuverseMapModel"],
        path: "App",
        resources: [
            .copy("Resources/PalletTown.json"),
        ]
    )
)
let supportedPlatforms: [SupportedPlatform]? = [.macOS(.v13)]
#else
let supportedPlatforms: [SupportedPlatform]? = nil
#endif

let package = Package(
    name: "ShuverseEditor",
    platforms: supportedPlatforms,
    products: products,
    targets: targets
)
