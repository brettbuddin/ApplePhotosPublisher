import ArgumentParser
import Foundation

@main
struct LRPhotosImporter: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "lrphotosimporter",
        abstract: "Import photos into Apple Photos from Lightroom",
        discussion: """
            Photo importer designed to be called from a Lightroom Classic plugin.
            Supports single-photo and batch import modes.
            Outputs XML to stdout for easy parsing.
            """,
        subcommands: [ImportCommand.self, DeleteCommand.self, OpenCommand.self]
    )
}
