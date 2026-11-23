// LXScriptFileStore.swift
// Script files on disk: `Documents/lx_scripts/<id>.js`.
//
// Mirrors the Flutter layout exactly: bundled scripts are seeded
// from the app bundle the first time (seed-if-missing, never
// overwriting a user edit), user scripts live in the same directory,
// and a bundled id the user deleted is never re-seeded. File names
// are relative names only — never absolute paths (iOS changes the
// container UUID on reinstall; see `LocalStore`).

import Foundation
import CryptoKit

final class LXScriptFileStore {
    /// Directory name under Documents (contract, same as Flutter).
    static let directoryName = "lx_scripts"

    private let documentsDirectory: URL
    private let fileManager: FileManager

    init(documentsDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.documentsDirectory = documentsDirectory ?? LocalStore.documentsDirectory()
        self.fileManager = fileManager
    }

    var directory: URL {
        documentsDirectory.appendingPathComponent(Self.directoryName)
    }

    func fileURL(forFileName fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    func fileURL(forScriptID id: String) -> URL {
        fileURL(forFileName: "\(id).js")
    }

    // MARK: - Seed / read / write / delete

    /// Copies the bundled script into Documents when no user file
    /// exists yet. Never overwrites. Returns the file URL when the
    /// file exists afterwards, nil when there is no bundled code to
    /// seed from and no file yet.
    @discardableResult
    func seedIfMissing(id: String, bundleCode: String?) -> URL? {
        let url = fileURL(forScriptID: id)
        if fileManager.fileExists(atPath: url.path) { return url }
        guard let code = bundleCode else { return nil }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try code.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    func read(id: String) -> String? {
        try? String(contentsOf: fileURL(forScriptID: id), encoding: .utf8)
    }

    func readFile(named fileName: String) -> String? {
        try? String(contentsOf: fileURL(forFileName: fileName), encoding: .utf8)
    }

    @discardableResult
    func write(code: String, fileName: String) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try code.write(to: fileURL(forFileName: fileName), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func delete(id: String) -> Bool {
        let url = fileURL(forScriptID: id)
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func deleteFile(named fileName: String) -> Bool {
        let url = fileURL(forFileName: fileName)
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Custom-script identity

    /// Stable id for a user-imported script, derived from its content
    /// (SHA-1, first 12 hex chars — identity only, never a secret).
    /// Re-importing the same content yields the same id, so the old
    /// record is replaced, never duplicated (Flutter parity).
    static func customScriptID(for code: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(code.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "custom:file:\(hex.prefix(12))"
    }

    /// File name for a custom script: `custom-file-<digest>.js`.
    /// The `custom-` prefix guarantees it can never collide with a
    /// bundled `<id>.js` file.
    static func customFileName(for code: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(code.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "custom-file-\(hex.prefix(12)).js"
    }

    /// Best-effort name for a user script from its header
    /// (`@name` tag) or its file name.
    static func displayName(for code: String, fileName: String) -> String {
        if let name = LXScriptHeader.parseName(from: code) { return name }
        return URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }
}

/// Minimal reader for a script's leading comment header. The engine
/// reads `@`-tags from the FIRST comment block only (scripts' own
/// `parseHeader` does the same), so the de-key comment we insert
/// AFTER that block is never mistaken for metadata.
enum LXScriptHeader {
    /// Returns the `@name` tag value from the leading comment block.
    static func parseName(from code: String) -> String? {
        guard let header = leadingCommentBlock(in: code) else { return nil }
        return tagValue("name", in: header)
    }

    /// Returns the `@version` tag value from the leading comment block.
    static func parseVersion(from code: String) -> String? {
        guard let header = leadingCommentBlock(in: code) else { return nil }
        return tagValue("version", in: header)
    }

    /// The first `/* … */` block at the start of the file (allowing
    /// leading whitespace). Nil when the file starts with code.
    static func leadingCommentBlock(in code: String) -> String? {
        let trimmed = code.drop(while: { $0.isWhitespace })
        guard trimmed.hasPrefix("/*") else { return nil }
        guard let end = trimmed.range(of: "*/") else { return nil }
        return String(trimmed[trimmed.startIndex..<end.upperBound])
    }

    private static func tagValue(_ tag: String, in header: String) -> String? {
        // Lines look like ` * @name suyin` or `@name suyin`.
        let pattern = "@\(tag)\\s+([^\\r\\n*]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: header,
                range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header)
        else { return nil }
        let value = header[range].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
