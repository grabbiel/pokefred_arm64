// swift-tools-version: 5.9
import PackageDescription

// The map model is pure Swift so it can be tested off macOS.
// The AppKit + Metal executable, including the Dear ImGui dock host, is
// declared only when the package is evaluated on a Mac.
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
targets.append(contentsOf: [
    .target(
        name: "CImGuiHost",
        path: "ImGuiHost",
        exclude: [
            "imgui/LICENSE.txt",
            "imgui/VENDORED.txt",
        ],
        publicHeadersPath: "include",
        cxxSettings: [
            .headerSearchPath("include"),
            .headerSearchPath("imgui"),
        ]
    ),
    .executableTarget(
        name: "ShuverseEditor",
        dependencies: ["ShuverseMapModel", "CImGuiHost"],
        path: "App",
        resources: [
            .copy("Resources/PalletTown.json"),
            .copy("Resources/tilesets"),
        ]
    ),
])
let supportedPlatforms: [SupportedPlatform]? = [.macOS(.v13)]
#else
let supportedPlatforms: [SupportedPlatform]? = nil
#endif

let package = Package(
    name: "ShuverseEditor",
    platforms: supportedPlatforms,
    products: products,
    targets: targets,
    cxxLanguageStandard: .cxx17
)
