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

        // Some skins ship .wmz files with the local file header signature of
        // one entry overwritten (an anti-rip trick). WMP's own reader trusts
        // the central directory and opens them fine, but `/usr/bin/unzip`
        // refuses that entry. If we can repair the signature using the
        // central directory's bookkeeping, do so on a scratch copy.
        let repaired = repairedCopy(of: url, in: tempDir)
        let sourceURL = repaired ?? url

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", sourceURL.path, "-d", tempDir.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SkinLoaderError.extractionFailed(underlying: error)
        }

        if let repaired {
            try? FileManager.default.removeItem(at: repaired)
        }

        // Even unrepaired corruption shouldn't be fatal if `unzip` still
        // managed to extract most entries: only treat this as a hard
        // failure if nothing was extracted at all.
        if process.terminationStatus != 0 {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
            if entries.isEmpty {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errorData, encoding: .utf8) ?? "unzip exited \(process.terminationStatus)"
                throw SkinLoaderError.extractionFailed(underlying: NSError(
                    domain: "SkinLoader",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: message]
                ))
            }
        }

        return tempDir
    }

    private static let localFileHeaderSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    private static let centralDirectorySignature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
    private static let endOfCentralDirectorySignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]

    /// Walks the ZIP central directory and, for any entry whose local file
    /// header signature has been overwritten, patches it back to
    /// `PK\x03\x04` in a scratch copy written into `tempDir`. Returns `nil`
    /// if the archive is well-formed already, or if it can't be parsed
    /// (e.g. ZIP64) — callers should fall back to the original file.
    private static func repairedCopy(of url: URL, in tempDir: URL) -> URL? {
        guard var bytes = try? [UInt8](Data(contentsOf: url)) else { return nil }

        // The EOCD record is 22 bytes plus an optional comment of up to 65535 bytes.
        let searchStart = max(0, bytes.count - 22 - 65535)
        guard let eocd = lastRange(of: endOfCentralDirectorySignature, in: bytes, from: searchStart),
              eocd + 22 <= bytes.count else { return nil }

        let totalEntries = readUInt16LE(bytes, eocd + 10)
        let cdOffset = Int(readUInt32LE(bytes, eocd + 16))
        guard cdOffset != 0xFFFF_FFFF, totalEntries != 0xFFFF else { return nil } // ZIP64, not handled

        var pos = cdOffset
        var patchOffsets: [Int] = []
        for _ in 0..<totalEntries {
            guard pos + 46 <= bytes.count,
                  Array(bytes[pos..<(pos + 4)]) == centralDirectorySignature else { return nil }

            let fnLen = Int(readUInt16LE(bytes, pos + 28))
            let extraLen = Int(readUInt16LE(bytes, pos + 30))
            let commentLen = Int(readUInt16LE(bytes, pos + 32))
            let localHeaderOffset = Int(readUInt32LE(bytes, pos + 42))

            if localHeaderOffset + 4 <= bytes.count,
               Array(bytes[localHeaderOffset..<(localHeaderOffset + 4)]) != localFileHeaderSignature {
                patchOffsets.append(localHeaderOffset)
            }

            pos += 46 + fnLen + extraLen + commentLen
        }

        guard !patchOffsets.isEmpty else { return nil }

        for offset in patchOffsets {
            bytes.replaceSubrange(offset..<(offset + 4), with: localFileHeaderSignature)
        }

        let repairedURL = tempDir.appendingPathComponent("_repaired.wmz")
        guard (try? Data(bytes).write(to: repairedURL)) != nil else { return nil }
        return repairedURL
    }

    private static func readUInt16LE(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// Returns the start index of the last occurrence of `pattern` in
    /// `bytes` at or after `from`, searching backwards from the end.
    private static func lastRange(of pattern: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        var i = bytes.count - pattern.count
        while i >= from {
            if Array(bytes[i..<(i + pattern.count)]) == pattern { return i }
            i -= 1
        }
        return nil
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
