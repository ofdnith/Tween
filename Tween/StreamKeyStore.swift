import Foundation

/// Stream keys as files only this user can read, one per site, in the app's own folder.
/// They were in the login keychain at first; an ad hoc signed build is a new app to the keychain
/// after every rebuild, so macOS asked for the login password each time.
enum StreamKeyStore {
    /// Outside the app (the checks) a folder of the run's own, so the real keys are never touched.
    static let folder: URL = {
        guard let bundle = Bundle.main.bundleIdentifier else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("tween-stream-keys.checks.\(getpid())")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(bundle).appendingPathComponent("stream-keys")
    }()

    static func key(for site: StreamSite) -> String? {
        read(for: site).key
    }

    /// The key, and whether a saved one couldn't be read.
    static func read(for site: StreamSite) -> (key: String?, unreadable: Bool) {
        let url = file(site)
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, false) }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return (nil, true) }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key.isEmpty ? nil : key, false)
    }

    /// Whether a key is saved. The key itself is not read.
    static func hasKey(for site: StreamSite) -> Bool {
        FileManager.default.fileExists(atPath: file(site).path)
    }

    /// nil or empty deletes the key. False when it couldn't be saved or removed.
    @discardableResult
    static func set(_ key: String?, for site: StreamSite) -> Bool {
        let url = file(site)
        let files = FileManager.default
        guard let key, !key.isEmpty else {
            guard files.fileExists(atPath: url.path) else { return true }
            return (try? files.removeItem(at: url)) != nil
        }
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Made empty with its permissions first, so the key is never in a file others can read.
            try? files.removeItem(at: url)
            guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return false }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(key.utf8))
            return true
        } catch {
            try? files.removeItem(at: url)
            return false
        }
    }

    private static func file(_ site: StreamSite) -> URL {
        folder.appendingPathComponent(site.rawValue + ".key")
    }
}
