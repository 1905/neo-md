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
    static let firstCheckDelay: TimeInterval = 10
    static let checkInterval: TimeInterval = 6 * 3600
    static let minCheckGap: TimeInterval = 3600
    /// Larger feeds are rejected before the download.
    static let maxZipSize = 100 * 1024 * 1024

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private let bundleURL = Bundle.main.bundleURL
    private let fm = FileManager.default
    /// `~/Library/Caches/<bundle id>/Update`: downloads, the staged bundle, old bundles.
    private let updateDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "neo-md").appendingPathComponent("Update")
    /// `staged/<installed bundle name>`: the verified new bundle, waiting for the quit.
    private let stagedApp: URL
    private var timer: Timer?
    /// A check runs (feed, download, staging).
    private var busy = false
    /// A background task verifies or replaces `stagedApp`. The install at quit waits for the next quit.
    private var staging = false

    private init() {
        stagedApp = updateDir.appendingPathComponent("staged").appendingPathComponent(bundleURL.lastPathComponent)
    }

    /// The bundle can be replaced: it sits in an Applications folder, not on a disk image or a
    /// translocated path, and its folder and itself are writable.
    var isInstallable: Bool {
        let path = bundleURL.path
        return Bundle.main.isInApplicationsFolder
            && !path.hasPrefix("/Volumes/") && !path.contains("/AppTranslocation/")
            && fm.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
            && fm.isWritableFile(atPath: path)
    }

    // MARK: - Start and timer

    func start() {
        let staged = stagedVersion()
        let (dir, stagedDir) = (updateDir, stagedApp.deletingLastPathComponent())
        Task.detached(priority: .background) {
            Self.removeLeftovers(in: dir, stagedDir: staged == nil ? stagedDir : nil)
        }
        if let error = Settings.shared.updateInstallError {
            Settings.shared.updateInstallError = nil
            status = .failed(error)
        }
        if !isInstallable {
            status = .notInstallable
        } else if let staged {
            status = .staged(staged)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange),
                                               name: Settings.didChange, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstCheckDelay) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleTimer() }
        }
    }

    @objc private func settingsDidChange(_ note: Notification) {
        if Settings.shared.autoUpdate {
            scheduleTimer()
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
        let feedURL = Settings.shared.updateFeedURL ?? Self.defaultFeedURL
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("neo-md/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Self.session.data(for: request)
        try Self.checkHTTP(response, request)
        let feed = try UpdateFeed.decode(data)

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

        // Download to a file: the zip never sits in memory on the main thread.
        let zipRequest = URLRequest(url: feed.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                    timeoutInterval: 300)
        let (download, zipResponse) = try await Self.session.download(for: zipRequest)
        try Self.checkHTTP(zipResponse, zipRequest)
        let work = updateDir.appendingPathComponent("unpack-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zipFile = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: download, to: zipFile)

        let (staged, bundleID) = (stagedApp, Bundle.main.bundleIdentifier)
        staging = true
        defer { staging = false }
        try await Task.detached {
            try Self.verifyAndStage(zipFile: zipFile, feed: feed, publicKey: key, bundleID: bundleID,
                                    work: work, stagedApp: staged)
        }.value
        return .staged(feed.version)
    }

    /// No disk cache: the feed must be fresh, and zips do not belong in `Cache.db`.
    private static let session = URLSession(configuration: .ephemeral)

    private static func checkHTTP(_ response: URLResponse, _ request: URLRequest) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError("HTTP \(http.statusCode) for \(request.url?.lastPathComponent ?? "")")
        }
    }

    /// Verifies the zip in `work`, unzips it there, checks bundle ID, version and code signature,
    /// then moves the bundle to `stagedApp`, replacing an older staged copy. Deletes `work`.
    nonisolated private static func verifyAndStage(zipFile: URL, feed: UpdateFeed, publicKey: String,
                                                   bundleID: String?, work: URL, stagedApp: URL) throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: work) }
        try feed.verify(zip: Data(contentsOf: zipFile, options: .alwaysMapped), publicKey: publicKey)
        try run("/usr/bin/ditto", ["-x", "-k", zipFile.path, work.path])
        let version = feed.version

        // The zip holds one bundle. Its name can differ from the installed one (a renamed copy).
        let apps = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first, let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError("the update is not neo-md")
        }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("the update version does not match")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])

        let stagedDir = stagedApp.deletingLastPathComponent()
        try? fm.removeItem(at: stagedDir)
        try fm.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        try fm.moveItem(at: app, to: stagedApp)
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

    /// The version of the staged bundle, if it is newer than this one. Reads the plist file
    /// directly: `Bundle(url:)` caches per path and would miss a newer staged copy.
    private func stagedVersion() -> String? {
        let plist = stagedApp.appendingPathComponent("Contents/Info.plist")
        guard let version = NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String,
              UpdateVersion.isNewer(version, than: currentVersion) else { return nil }
        return version
    }

    /// Deletes old bundles from earlier installs, unpack folders, and `stagedDir` if given
    /// (a staged copy that is not newer).
    nonisolated private static func removeLeftovers(in dir: URL, stagedDir: URL?) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix("old-") || item.lastPathComponent.hasPrefix("unpack-") {
            try? fm.removeItem(at: item)
        }
        if let stagedDir { try? fm.removeItem(at: stagedDir) }
    }

    // MARK: - Install at quit

    /// Called from `applicationWillTerminate`. Swaps the staged bundle in with two renames.
    /// The running process keeps its mapped files, so moving its bundle is safe. On a failure
    /// the old bundle goes back and the error shows in Settings at the next start.
    func installStagedUpdate() {
        // While a background task replaces the staged copy, skip this quit: a later quit installs.
        guard Settings.shared.autoUpdate, !staging, isInstallable, stagedVersion() != nil else { return }
        let old = updateDir.appendingPathComponent("old-\(Int(Date().timeIntervalSince1970)).app")
        var movedOld = false
        do {
            try fm.moveItem(at: bundleURL, to: old)
            movedOld = true
            try fm.moveItem(at: stagedApp, to: bundleURL)
        } catch {
            if movedOld { try? fm.moveItem(at: old, to: bundleURL) }
            Settings.shared.updateInstallError = Self.message(error)
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

extension Bundle {
    /// The bundle sits directly in a folder named Applications (`/Applications` or `~/Applications`):
    /// an installed copy, not build output or a disk image.
    var isInApplicationsFolder: Bool {
        bundleURL.deletingLastPathComponent().lastPathComponent == "Applications"
    }
}
