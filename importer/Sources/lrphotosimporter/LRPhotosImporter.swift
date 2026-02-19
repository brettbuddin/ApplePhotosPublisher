import ArgumentParser
import Foundation

/// Main entry point for the LRPhotosImporter command-line tool.
///
/// This tool is designed to be invoked by a Lightroom Classic publish service plugin
/// to import, delete, and open photos in the Apple Photos library. It exposes three
/// subcommands: `import`, `delete`, and `open`.
@main
struct LRPhotosImporter: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        var config = CommandConfiguration(
            commandName: "lrphotosimporter",
            abstract: "Import photos into Apple Photos from Lightroom",
            discussion: """
                Photo importer designed to be called from a Lightroom Classic plugin.
                Supports single-photo and batch import modes.
                Outputs XML to stdout for easy parsing.
                """,
            subcommands: [ImportCommand.self, DeleteCommand.self, OpenCommand.self]
        )
        #if RELEASE_BUILD
        config.version = BuildInfo.version
        #endif
        return config
    }
}
