import ArgumentParser
import Foundation
import LaunchSupport

/// Main entry point for the LRPhotosImporter command-line tool.
///
/// This tool is designed to be invoked by a Lightroom Classic publish service plugin
/// to import, delete, and open photos in the Apple Photos library. The `authorize`
/// subcommand diagnoses Photos permission and service access without changing photos.
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
            subcommands: [ImportCommand.self, DeleteCommand.self, OpenCommand.self, AuthorizeCommand.self]
        )
        #if RELEASE_BUILD
        config.version = BuildInfo.version
        #endif
        return config
    }
}

@main
enum ImporterMain {
    static func main() async {
        do {
            let arguments = try StartupHandshake.complete(arguments: Array(CommandLine.arguments.dropFirst()))
            await LRPhotosImporter.main(arguments)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            Foundation.exit(78)
        }
    }
}
