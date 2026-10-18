import AppKit
import MDCore
import os

/// Silent updates from GitHub Releases (plans/2026-10-18-auto-update/spec.md).
/// Checks `latest.json`, downloads and verifies the signed zip, stages the new bundle in Caches,
/// and swaps it in when the app quits. No dialogs: the state shows only in Settings → General.
@MainActor
final class Updater {
    static let shared = Updater()
    /// Posted (object: the updater) after `status` changes.
    static let statusDidChange = Notification.Name("NeoMDUpdaterStatusDidChange")

    enum Status: Equatable {
        case idle, checking, upToDate, notInstallable
        case available(String), staged(String), failed(String)
    }

    private(set) var status: Status = .idle {
        didSet {
            Self.log.notice("status \(String(describing: self.status), privacy: .public)")
            NotificationCenter.default.post(name: Self.statusDidChange, object: self)
        }
    }

    private static let log = Logger(subsystem: "io.github.1905.neo-md", category: "update")
    static let defaultFeedURL = URL(string: "https://github.com/1905/neo-md/releases/latest/download/latest.json")!
    /// Test hook: another feed URL. The signature check still applies.
    static let feedURLKey = "NeoMDUpdateFeedURL"
    /// The error of the last failed install at quit, shown at the next start.
    private static let installErrorKey = "NeoMDUpdateInstallError"
    static let firstCheckDelay: TimeInterval = 10
    static let checkInterval: TimeInterval = 6 * 3600
    static let minCheckGap: TimeInterval = 3600
    /// Larger feeds are rejected before the download.
    static let maxZipSize = 100 * 1024 * 1024

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private let bundleURL = Bundle.main.bundleURL
    private let fm = FileManager.default
    private var timer: Timer?
    private var busy = false

    private var feedURL: URL {
        UserDefaults.standard.string(forKey: Self.feedURLKey).flatMap(URL.init(string:)) ?? Self.defaultFeedURL
    }

    private var updateDir: URL {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "neo-md")
            .appendingPathComponent("Update")
    }

    private var stagedApp: URL { updateDir.appendingPathComponent("staged").appendingPathComponent(bundleURL.lastPathComponent) }

    /// The bundle can be replaced: it sits in an Applications folder (or the test feed is set),
    /// not on a disk image or a translocated path, and its folder and itself are writable.
    var isInstallable: Bool {
        let path = bundleURL.path
        let inApplications = bundleURL.deletingLastPathComponent().lastPathComponent == "Applications"
        let testFeed = UserDefaults.standard.string(forKey: Self.feedURLKey) != nil
        return (inApplications || testFeed)
            && !path.hasPrefix("/Volumes/") && !path.contains("/AppTranslocation/")
            && fm.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
            && fm.isWritableFile(atPath: path)
    }

    // MARK: - Start and timer

    func start() {
        removeLeftovers()
        if let error = UserDefaults.standard.string(forKey: Self.installErrorKey) {
            UserDefaults.standard.removeObject(forKey: Self.installErrorKey)
            status = .failed(error)
        }
        if !isInstallable {
            status = .notInstallable
        } else if let version = stagedVersion() {
            status = .staged(version)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: Settings.didChange, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstCheckDelay) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleTimer() }
        }
    }

    @objc private func settingsDidChange(_ note: Notification) {
        if Settings.shared.autoUpdate {
            if timer == nil { scheduleTimer() }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Checks now (if due) and then every `checkInterval`, while the setting is on.
    private func scheduleTimer() {
        guard Settings.shared.autoUpdate, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.check(force: false) }
        }
        check(force: false)
    }

    /// Settings "Check Now": ignores the 1 h gap. With the setting off it only reports.
    func checkNow() { check(force: true) }

    // MARK: - Check, download, stage

    private func check(force: Bool) {
        guard !busy, isInstallable else { return }
        if !force {
            guard Settings.shared.autoUpdate else { return }
            if let last = Settings.shared.lastUpdateCheck, Date().timeIntervalSince(last) < Self.minCheckGap { return }
        }
        busy = true
        status = .checking
        Task {
            defer { busy = false }
            do {
                status = try await runCheck(stage: Settings.shared.autoUpdate)
                Settings.shared.lastUpdateCheck = Date()
            } catch {
                status = .failed(Self.message(error))
            }
        }
    }

    private func runCheck(stage: Bool) async throws -> Status {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("neo-md/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let feed = try UpdateFeed.decode(try await Self.fetch(request))

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        guard UpdateVersion.isNewer(feed.version, than: currentVersion),
              !UpdateVersion.isNewer(feed.minimumSystemVersion, than: osVersion) else { return .upToDate }
        if stagedVersion() == feed.version { return .staged(feed.version) }
        guard stage else { return .available(feed.version) }
        guard feed.size > 0, feed.size <= Self.maxZipSize else { throw UpdateError("download size is out of range") }
        guard let key = Bundle.main.object(forInfoDictionaryKey: "NeoMDUpdatePublicKey") as? String else {
            throw UpdateFeed.VerifyError.badKey
        }

        let zip = try await Self.fetch(URLRequest(url: feed.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                                  timeoutInterval: 300))
        try feed.verify(zip: zip, publicKey: key)
        let dir = updateDir
        let appName = bundleURL.lastPathComponent
        let bundleID = Bundle.main.bundleIdentifier
        try await Task.detached {
            try Self.unpackAndStage(zip: zip, version: feed.version, bundleID: bundleID, appName: appName, in: dir)
        }.value
        return .staged(feed.version)
    }

    /// No disk cache: the feed must be fresh, and zips do not belong in `Cache.db`.
    private static let session = URLSession(configuration: .ephemeral)

    private static func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError("HTTP \(http.statusCode) for \(request.url?.lastPathComponent ?? "")")
        }
        return data
    }

    /// Unzips into a fresh folder, checks bundle ID, version and code signature,
    /// then moves the bundle to `staged/`, replacing an older staged copy.
    nonisolated private static func unpackAndStage(zip: Data, version: String, bundleID: String?,
                                                   appName: String, in dir: URL) throws {
        let fm = FileManager.default
        let work = dir.appendingPathComponent("unpack-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zipFile = work.appendingPathComponent("update.zip")
        try zip.write(to: zipFile)
        try run("/usr/bin/ditto", ["-x", "-k", zipFile.path, work.path])

        let app = work.appendingPathComponent(appName)
        guard let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError("the update is not \(appName)")
        }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("the update version does not match")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])

        let stagedDir = dir.appendingPathComponent("staged")
        try? fm.removeItem(at: stagedDir)
        try fm.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        try fm.moveItem(at: app, to: stagedDir.appendingPathComponent(appName))
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus))")
        }
    }

    /// The version of the staged bundle, if it is newer than this one.
    private func stagedVersion() -> String? {
        guard let version = Bundle(url: stagedApp)?
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              UpdateVersion.isNewer(version, than: currentVersion) else { return nil }
        return version
    }

    /// Deletes old bundles from earlier installs, unpack folders, and a staged copy that is not newer.
    private func removeLeftovers() {
        guard let items = try? fm.contentsOfDirectory(at: updateDir, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix("old-") || item.lastPathComponent.hasPrefix("unpack-") {
            try? fm.removeItem(at: item)
        }
        if stagedVersion() == nil { try? fm.removeItem(at: stagedApp.deletingLastPathComponent()) }
    }

    // MARK: - Install at quit

    /// Called from `applicationWillTerminate`. Swaps the staged bundle in with two renames.
    /// The running process keeps its mapped files, so moving its bundle is safe. On a failure
    /// the old bundle goes back and the error shows in Settings at the next start.
    func installStagedUpdate() {
        guard Settings.shared.autoUpdate, isInstallable, stagedVersion() != nil else { return }
        let old = updateDir.appendingPathComponent("old-\(Int(Date().timeIntervalSince1970)).app")
        do {
            try fm.moveItem(at: bundleURL, to: old)
        } catch {
            UserDefaults.standard.set(Self.message(error), forKey: Self.installErrorKey)
            return
        }
        do {
            try fm.moveItem(at: stagedApp, to: bundleURL)
        } catch {
            try? fm.moveItem(at: old, to: bundleURL)
            UserDefaults.standard.set(Self.message(error), forKey: Self.installErrorKey)
        }
    }

    private static func message(_ error: Error) -> String {
        switch error {
        case let error as UpdateError: error.message
        case let error as UpdateFeed.VerifyError: error.description
        default: error.localizedDescription
        }
    }
}

struct UpdateError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
