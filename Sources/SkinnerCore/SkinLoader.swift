import Foundation

/// A resolved skin bundle: a directory on disk plus the located .wms file.
public struct SkinBundle: Sendable {
    public let directory: URL
    public let wmsFile: URL

    /// Resolves an asset filename (e.g. "background.png") to a full URL within the bundle.
    public func assetURL(named name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}

public enum SkinLoaderError: Error, CustomStringConvertible, LocalizedError {
    case notAFileOrDirectory(URL)
    case noWMSFile(URL)
    case extractionFailed(underlying: Error)

    public var description: String {
        switch self {
        case .notAFileOrDirectory(let url):
            return "Path is not a readable file or directory: \(url.path)"
        case .noWMSFile(let url):
            return "No .wms file found in: \(url.path)"
        case .extractionFailed(let err):
            return "ZIP extraction failed: \(err.localizedDescription)"
        }
    }

    public var errorDescription: String? { description }
}

public enum SkinLoader {
    /// Load a skin from a `.wmz` archive or a pre-extracted directory.
    ///
    /// - `.wmz` file: extracted to a temporary directory that the caller owns;
    ///   delete `SkinBundle.directory` when done.
    /// - Directory: returned as-is; the caller must not delete it.
    public static func load(from url: URL) throws -> SkinBundle {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw SkinLoaderError.notAFileOrDirectory(url)
        }

        let skinDir: URL
        if isDir.boolValue {
            skinDir = url
        } else {
            skinDir = try extractWMZ(at: url)
        }

        guard let wmsFile = findWMS(in: skinDir) else {
            throw SkinLoaderError.noWMSFile(skinDir)
        }

        return SkinBundle(directory: skinDir, wmsFile: wmsFile)
    }

    // MARK: - Private

    /// Extracts a .wmz (ZIP) to a new temp directory and returns that directory's URL.
    private static func extractWMZ(at url: URL) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skinner-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            throw SkinLoaderError.extractionFailed(underlying: error)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", url.path, "-d", tempDir.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SkinLoaderError.extractionFailed(underlying: error)
        }

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? "unzip exited \(process.terminationStatus)"
            throw SkinLoaderError.extractionFailed(underlying: NSError(
                domain: "SkinLoader",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }

        return tempDir
    }

    /// Returns the first `.wms` file found (non-recursively) in `directory`.
    private static func findWMS(in directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return nil }

        return contents.first { $0.pathExtension.lowercased() == "wms" }
    }
}
