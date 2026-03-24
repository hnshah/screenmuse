import Foundation

/// Upload a recorded video to iCloud Drive.
///
/// Strategy: copy to ~/Library/Mobile Documents/com~apple~CloudDocs/ScreenMuse/
/// iCloud daemon (bird) picks up files written here and syncs them automatically.
/// No entitlements, no bundle ID, no NSUbiquityContainerIdentifier required.
///
/// This is the same mechanism used by iCloud Drive — the folder IS iCloud Drive.
/// Files appear in the user's iCloud Drive → ScreenMuse folder on all devices.
///
/// Limitations:
///   - iCloud must be configured on the Mac (iCloud Drive enabled)
///   - Sync is asynchronous — the file appears locally immediately but takes
///     time to upload (depends on file size + connection)
///   - No programmatic way to get a share link without CloudKit entitlements
///   - `NSFileManager.url(forUbiquityContainerIdentifier:)` requires entitlements —
///     we avoid this and use the physical path directly

public final class iCloudUploader {

    // MARK: - Types

    public struct UploadResult: Sendable {
        /// Full path to the file in iCloud Drive folder (already syncing)
        public let localPath: String
        /// Relative path within iCloud Drive (e.g. "ScreenMuse/recording.mp4")
        public let icloudRelativePath: String
        /// iCloud Drive is handling sync — true if the destination folder exists
        public let syncingToCloud: Bool
        /// File size in bytes
        public let fileSize: Int

        public var sizeMB: Double { Double(fileSize) / 1_048_576 }

        public func asDictionary() -> [String: Any] {
            [
                "local_path": localPath,
                "icloud_relative_path": icloudRelativePath,
                "syncing_to_cloud": syncingToCloud,
                "size": fileSize,
                "size_mb": (sizeMB * 100).rounded() / 100,
                "note": syncingToCloud
                    ? "File is in iCloud Drive and will sync to your other devices automatically."
                    : "iCloud Drive folder not found — check System Settings → Apple ID → iCloud → iCloud Drive.",
                "find_it": "Open Finder → iCloud Drive → ScreenMuse"
            ]
        }
    }

    public enum UploadError: Error, LocalizedError {
        case sourceNotFound(String)
        case iCloudDriveNotAvailable
        case copyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sourceNotFound(let path):
                return "Source file not found: \(path)"
            case .iCloudDriveNotAvailable:
                return "iCloud Drive not available. Enable it in System Settings → Apple ID → iCloud → iCloud Drive, then try again."
            case .copyFailed(let msg):
                return "Failed to copy file to iCloud Drive: \(msg)"
            }
        }
    }

    // MARK: - iCloud Drive Path

    /// The physical path to iCloud Drive on this Mac.
    /// This is ~/Library/Mobile Documents/com~apple~CloudDocs/
    public static var iCloudDriveURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidate = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Mobile Documents")
            .appendingPathComponent("com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// ScreenMuse subfolder inside iCloud Drive
    public static var screenMuseCloudFolder: URL? {
        guard let drive = iCloudDriveURL else { return nil }
        let folder = drive.appendingPathComponent("ScreenMuse", isDirectory: true)
        // Create the folder if it doesn't exist yet
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    // MARK: - Upload

    /// Copy a video to iCloud Drive → ScreenMuse folder.
    ///
    /// - Parameters:
    ///   - sourceURL: The local file to upload
    ///   - filename: Optional custom filename. Defaults to source filename.
    ///   - overwrite: If true, replace existing file with same name. Default false (auto-renames).
    public func upload(
        sourceURL: URL,
        filename: String? = nil,
        overwrite: Bool = false
    ) throws -> UploadResult {
        smLog.info("iCloudUploader: upload source=\(sourceURL.lastPathComponent)", category: .recording)

        // Verify source exists
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw UploadError.sourceNotFound(sourceURL.path)
        }

        // Resolve iCloud Drive folder
        guard let cloudFolder = Self.screenMuseCloudFolder else {
            smLog.error("iCloudUploader: iCloud Drive not found at ~/Library/Mobile Documents/com~apple~CloudDocs/", category: .recording)
            throw UploadError.iCloudDriveNotAvailable
        }

        // Resolve destination filename
        let destName: String
        if let custom = filename, !custom.isEmpty {
            destName = custom
        } else {
            destName = sourceURL.lastPathComponent
        }

        var destURL = cloudFolder.appendingPathComponent(destName)

        // Handle name collision
        if !overwrite && FileManager.default.fileExists(atPath: destURL.path) {
            let stem = destURL.deletingPathExtension().lastPathComponent
            let ext = destURL.pathExtension
            let ts = Int(Date().timeIntervalSince1970)
            destURL = cloudFolder.appendingPathComponent("\(stem)-\(ts).\(ext)")
            smLog.info("iCloudUploader: destination exists — renamed to \(destURL.lastPathComponent)", category: .recording)
        }

        // Copy (not move — keep original in Movies/ScreenMuse/)
        do {
            if overwrite && FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            smLog.error("iCloudUploader: copy failed — \(error.localizedDescription)", category: .recording)
            throw UploadError.copyFailed(error.localizedDescription)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0

        // Relative path within iCloud Drive (for display)
        let driveRoot = Self.iCloudDriveURL?.path ?? ""
        let relativePath = destURL.path.hasPrefix(driveRoot)
            ? String(destURL.path.dropFirst(driveRoot.count + 1))
            : destURL.lastPathComponent

        let result = UploadResult(
            localPath: destURL.path,
            icloudRelativePath: relativePath,
            syncingToCloud: true,
            fileSize: fileSize
        )

        smLog.info("iCloudUploader: ✅ uploaded to iCloud Drive — \(destURL.lastPathComponent) \(String(format:"%.2f",result.sizeMB))MB path=\(destURL.path)", category: .recording)
        smLog.usage("ICLOUD UPLOAD", details: [
            "file": destURL.lastPathComponent,
            "size": "\(String(format:"%.2f",result.sizeMB))MB",
            "icloud_path": relativePath
        ])

        return result
    }
}
