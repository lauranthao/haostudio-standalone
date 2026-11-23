// HAo Studio 2.0 — profile store (S5, leg A).
//
// The "我的" profile: a display nickname (a plain UserDefaults
// string, key `hao_profile_nickname` — read/written through
// SettingsStore in the app) and an avatar image.
//
// The avatar lives at `Documents/profile/avatar.jpg` as a RELATIVE
// reference (never an absolute path — the container UUID changes
// on every reinstall; see LocalStore). It is downsampled to at
// most 512 px on the long edge and stored as JPEG 0.85 on save,
// so a 12 MP camera photo never becomes a multi-megabyte avatar.

import Foundation
import UIKit

enum ProfileStore {
    static let avatarSubdir = "profile"
    static let avatarFileName = "avatar.jpg"
    /// Relative reference, the form indexes store.
    static let avatarRelativePath = "profile/avatar.jpg"
    /// Long-edge cap in pixels.
    static let avatarMaxDimension: CGFloat = 512

    // MARK: - Nickname

    static func loadNickname(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: SettingsStore.nicknameKey) ?? ""
    }

    static func saveNickname(_ nickname: String, defaults: UserDefaults = .standard) {
        defaults.set(nickname, forKey: SettingsStore.nicknameKey)
    }

    // MARK: - Avatar

    /// The avatar file URL when one exists, else nil.
    /// `documentsURL` is the test seam (nil = the real container).
    static func avatarURL(documentsURL: URL? = nil) -> URL? {
        if let docs = documentsURL {
            let url = docs.appendingPathComponent(avatarSubdir).appendingPathComponent(avatarFileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return LocalFileIndex.resolve(avatarRelativePath, subdir: avatarSubdir)
    }

    /// Save avatar image data. Downsamples to at most 512 px on
    /// the long edge (aspect kept, never upscaled) and stores
    /// JPEG 0.85. Returns false when the data is not an image, the
    /// downsample / encode fails, or the write fails.
    @discardableResult
    static func saveAvatar(data: Data, documentsURL: URL? = nil) -> Bool {
        guard let image = UIImage(data: data) else { return false }
        guard let downsampled = downsampledImage(image, maxDimension: avatarMaxDimension) else { return false }
        guard let jpeg = downsampled.jpegData(compressionQuality: 0.85) else { return false }
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        let dir = docs.appendingPathComponent(avatarSubdir)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try jpeg.write(to: dir.appendingPathComponent(avatarFileName), options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// Delete the avatar file. No-op when there is none.
    static func deleteAvatar(documentsURL: URL? = nil) {
        let docs = documentsURL ?? LocalStore.documentsDirectory()
        let url = docs.appendingPathComponent(avatarSubdir).appendingPathComponent(avatarFileName)
        try? FileManager.default.removeItem(at: url)
    }

    /// Downsample to at most `maxDimension` on the long edge.
    /// Smaller images pass through untouched (never upscaled).
    static func downsampledImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
