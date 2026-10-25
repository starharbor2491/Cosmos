import Foundation
import CosmosCore
import CosmosImport

// cosmos-cli: import, inspect and export Cosmos data from the terminal.
// Output is counts and fixed messages only: never a tab title, URL or other browsing data.

let cliVersion = "0.1.0"

let helpText = """
cosmos-cli \(cliVersion)

Usage:
  cosmos-cli import-arc [--from DIR] [--to DATA_DIR] [--summary] [--force]
  cosmos-cli version
  cosmos-cli help

import-arc reads an Arc profile (read-only) and writes workspace.json, archive.json, boosts.json and
link-routing.json into the Cosmos data directory.

  --from DIR      Arc profile directory (default: ~/Library/Application Support/Arc)
  --to DATA_DIR   Cosmos data directory (default: $COSMOS_DATA_DIR, else ~/Library/Application Support/Cosmos)
  --summary       Print what would be imported (counts only) and write nothing
  --force         Replace an existing workspace.json (the old files are backed up first)
"""

struct UsageError: Error { var message: String }

struct ImportArcOptions {
    var from: String?
    var to: String?
    var summaryOnly = false
    var force = false
}

/// `--flag value` and `--flag=value`.
func parseImportArc(_ arguments: [String]) throws -> ImportArcOptions {
    var options = ImportArcOptions()
    var rest = arguments[...]
    func value(for flag: String, inline: String?) throws -> String {
        if let inline, !inline.isEmpty { return inline }
        guard let next = rest.first, !next.hasPrefix("--") else { throw UsageError(message: "\(flag) needs a value") }
        rest = rest.dropFirst()
        return next
    }
    while let argument = rest.first {
        rest = rest.dropFirst()
        let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let inline = parts.count == 2 ? parts[1] : nil
        switch parts[0] {
        case "--from": options.from = try value(for: "--from", inline: inline)
        case "--to": options.to = try value(for: "--to", inline: inline)
        case "--summary": options.summaryOnly = true
        case "--force": options.force = true
        default: throw UsageError(message: "unknown option \(argument)")
        }
    }
    return options
}

func directory(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
}

func display(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

func printError(_ message: String) {
    FileHandle.standardError.write(Data(("cosmos-cli: " + message + "\n").utf8))
}

func importArc(_ arguments: [String]) -> Int32 {
    let options: ImportArcOptions
    do { options = try parseImportArc(arguments) } catch let error as UsageError {
        printError(error.message + "\n\n" + helpText)
        return 2
    } catch { return 2 }

    let source = options.from.map(directory) ?? ArcImporter.defaultDirectory
    guard ArcImporter.hasProfile(at: source) else {
        printError("no Arc profile found in \(display(source)) (StorableSidebar.json is missing)")
        return 1
    }

    let target = options.to.map(directory) ?? CosmosPaths.dataDirectory
    if !options.summaryOnly, !options.force, FileManager.default.fileExists(atPath: target.appendingPathComponent("workspace.json").path) {
        printError("\(display(target))/workspace.json already exists; pass --force to replace it (the old file is backed up first)")
        return 1
    }

    let result: ArcImportResult
    do { result = try ArcImporter.importProfile(at: source) } catch {
        printError(error.localizedDescription)
        return 1
    }

    print("Arc profile: \(display(source))")
    print(result.report.summary)
    for warning in result.report.warnings { print("  warning: \(warning)") }

    if options.summaryOnly {
        print("Summary only: nothing was written.")
        return 0
    }
    do {
        let files = try result.write(to: target, force: options.force)
        print("Wrote \(files.joined(separator: ", ")) to \(display(target))")
        return 0
    } catch {
        printError(error.localizedDescription)
        return 1
    }
}

func run(_ arguments: [String]) -> Int32 {
    guard let command = arguments.first else {
        print(helpText)
        return 0
    }
    let rest = Array(arguments.dropFirst())
    switch command {
    case "import-arc": return importArc(rest)
    case "version", "--version", "-v":
        print("cosmos-cli \(cliVersion)")
        return 0
    case "help", "--help", "-h":
        print(helpText)
        return 0
    default:
        printError("unknown command \(command)\n\n" + helpText)
        return 2
    }
}

exit(run(Array(CommandLine.arguments.dropFirst())))
