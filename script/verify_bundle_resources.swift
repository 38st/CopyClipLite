import AppKit
import Foundation

enum VerificationFailure: Error, CustomStringConvertible {
    case usage
    case invalidBundle(String)
    case missingResource(String)
    case undecodableImage(String)
    case missingLocalization(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: verify_bundle_resources.swift <app-bundle> <source-resources>"
        case let .invalidBundle(path):
            return "Unable to load app bundle at \(path)"
        case let .missingResource(name):
            return "Bundle lookup failed for required resource \(name)"
        case let .undecodableImage(name):
            return "Required image resource is not decodable: \(name)"
        case let .missingLocalization(path):
            return "Packaged app is missing localization resource \(path)"
        }
    }
}

func verify() throws {
    guard CommandLine.arguments.count == 3 else {
        throw VerificationFailure.usage
    }

    let appPath = CommandLine.arguments[1]
    let sourceResources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    guard let bundle = Bundle(path: appPath),
          let packagedResources = bundle.resourceURL else {
        throw VerificationFailure.invalidBundle(appPath)
    }

    for fileName in ["CopyClipIcon.icns", "CopyClipLogo.png"] {
        let sourceURL = URL(fileURLWithPath: fileName)
        guard let resourceURL = bundle.url(
            forResource: sourceURL.deletingPathExtension().lastPathComponent,
            withExtension: sourceURL.pathExtension
        ) else {
            throw VerificationFailure.missingResource(fileName)
        }
        guard NSImage(contentsOf: resourceURL) != nil else {
            throw VerificationFailure.undecodableImage(fileName)
        }
    }

    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
        at: sourceResources,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw VerificationFailure.invalidBundle(sourceResources.path)
    }

    for case let sourceURL as URL in enumerator {
        let relativePath = String(
            sourceURL.path.dropFirst(sourceResources.path.count + 1)
        )
        guard relativePath.split(separator: "/").contains(where: {
            $0.hasSuffix(".lproj")
        }) else {
            continue
        }
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            continue
        }
        let packagedURL = packagedResources.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: packagedURL.path) else {
            throw VerificationFailure.missingLocalization(relativePath)
        }
    }
}

do {
    try verify()
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
