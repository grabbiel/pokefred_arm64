import Foundation

enum MapFileLocator {
    /// Command-line path wins. Otherwise search upward for the sample, then the bundled copy.
    static func initialMapURL() -> URL? {
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let argument = arguments.first {
            return URL(fileURLWithPath: argument).standardizedFileURL
        }
        return palletTownURL()
    }

    static func palletTownURL() -> URL? {
        if let found = findSample() {
            return found
        }
        if let url = Bundle.module.url(forResource: "PalletTown", withExtension: "json", subdirectory: "Resources") {
            return url
        }
        return Bundle.module.url(forResource: "PalletTown", withExtension: "json")
    }

    private static let relativePaths = [
        "Samples/PalletTown.json",
        "ShuverseEditor/Samples/PalletTown.json",
    ]

    private static func findSample() -> URL? {
        var roots = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
        ]
        if let resources = Bundle.main.resourceURL {
            roots.append(resources)
        }
        for root in roots {
            var directory = root.standardizedFileURL
            for _ in 0..<10 {
                for relative in relativePaths {
                    let candidate = directory.appendingPathComponent(relative)
                    if FileManager.default.isReadableFile(atPath: candidate.path) {
                        return candidate
                    }
                }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path {
                    break
                }
                directory = parent
            }
        }
        return nil
    }
}
