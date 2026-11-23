// HAo Studio 2.0 — wallpaper store (S5, leg A).
//
// User-imported wallpapers: image files under
// `Documents/wallpapers/<uuid>.jpg`, indexed by the
// `hao_wallpaper_paths` collection (a JSON array of relative
// names — the same collection file LocalStore reads; the list is
// read/written here with an injectable documents directory so
// tests never touch the real container, because LocalStore itself
// has no directory injection).
//
// Stored references are RELATIVE names only (`wallpapers/<file>`)
// — the container UUID changes on every reinstall (see
// LocalStore). An old absolute entry is repaired to its relative
// form on load (LocalFileIndex.loadRepaired rules).

import Foundation
import UIKit

enum WallpaperStore {
    static let wallpaperSubdir = "wallpapers"
    static let pathsCollection = "hao_wallpaper_paths"

    // MARK: - List

    /// The stored wallpaper names, repaired to relative form
    /// (absolute entries re-resolved, missing files pruned).
    /// `documentsURL` is the test seam (nil = the real container).
    static func list(documentsURL: URL? = nil) -> [String] {
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        let stored = readPaths(documentsURL: docs)
        let repaired = LocalFileIndex.loadRepaired(stored, subdir: wallpaperSubdir)
        if repaired != stored {
            writePaths(repaired, documentsURL: docs)
        }
        return repaired
    }

    /// Persist the wallpaper name list (used by SettingsStore's
    /// `wallpaperPaths` didSet). Writes the JSON array atomically.
    static func saveList(_ names: [String], documentsURL: URL? = nil) {
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        writePaths(names, documentsURL: docs)
    }

    // MARK: - Import / delete / resolve

    /// Import image data as a wallpaper. The data is stored as-is
    /// under a fresh UUID name (no re-encode: a PNG stays a PNG
    /// even though the name ends in .jpg — UIImage decodes by
    /// content, and re-encoding would lose quality). Returns the
    /// relative name (`wallpapers/<uuid>.jpg`), or nil when the
    /// data is not an image or the write fails.
    @discardableResult
    static func importImage(data: Data, documentsURL: URL? = nil) -> String? {
        guard UIImage(data: data) != nil else { return nil }
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        let dir = docs.appendingPathComponent(wallpaperSubdir)
        let fileName = "\(UUID().uuidString).jpg"
        let url = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            return nil
        }
        let relative = "\(wallpaperSubdir)/\(fileName)"
        var names = readPaths(documentsURL: docs)
        if !names.contains(relative) {
            names.append(relative)
            writePaths(names, documentsURL: docs)
        }
        return relative
    }

    /// Delete a wallpaper: the file and its list entry. Matches by
    /// relative name or by bare file name. No-op when absent.
    static func delete(_ name: String, documentsURL: URL? = nil) {
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        let base = URL(fileURLWithPath: name).lastPathComponent
        if let url = LocalFileIndex.resolve(name, subdir: wallpaperSubdir) {
            try? FileManager.default.removeItem(at: url)
        } else {
            // The index was stale but the file may still be there
            // under its basename.
            let candidate = docs.appendingPathComponent(wallpaperSubdir).appendingPathComponent(base)
            try? FileManager.default.removeItem(at: candidate)
        }
        let names = readPaths(documentsURL: docs).filter {
            $0 != name && URL(fileURLWithPath: $0).lastPathComponent != base
        }
        writePaths(names, documentsURL: docs)
    }

    /// The file URL for a wallpaper name, or nil when the file is
    /// gone. Accepts a relative name or a bare file name.
    static func fileURL(for name: String, documentsURL: URL? = nil) -> URL? {
        if let docs = documentsURL {
            let base = URL(fileURLWithPath: name).lastPathComponent
            guard !base.isEmpty else { return nil }
            let url = docs.appendingPathComponent(wallpaperSubdir).appendingPathComponent(base)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return LocalFileIndex.resolve(name, subdir: wallpaperSubdir)
    }

    // MARK: - Collection file (mirrors LocalStore's format)

    private static func collectionURL(documentsURL: URL) -> URL {
        documentsURL.appendingPathComponent("\(pathsCollection).json")
    }

    private static func readPaths(documentsURL: URL) -> [String] {
        guard let data = try? Data(contentsOf: collectionURL(documentsURL: documentsURL)),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = parsed as? [String]
        else { return [] }
        return array
    }

    private static func writePaths(_ names: [String], documentsURL: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: names, options: []) else { return }
        try? data.write(to: collectionURL(documentsURL: documentsURL), options: [.atomic])
    }
}
