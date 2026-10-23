// In-app updates for the Mac app — the same flow as the Windows app (desktop/updater.cjs):
// latest-mac.yml on the release server says the newest version, its DMG and the DMG's SHA-512.
// The studio's own update card drives it through window.ebdaai.update; "Update now" downloads
// and checks the DMG, and "Restart & update" swaps EBDAAI.app in place and reopens it.

import Cocoa
import CryptoKit

final class Updater: NSObject, URLSessionDownloadDelegate {
    static let checkEvery: TimeInterval = 4 * 60 * 60
    let feed = (ProcessInfo.processInfo.environment["EBDAAI_UPDATE_FEED"]
        ?? "https://github.com/mowshcashy/ebdaai-releases/releases/latest/download")
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    struct Latest { let version: String, path: String, sha512: String, notes: String }

    private(set) var status = "idle"
    private var available: Latest?
    private var progress = 0
    private var error: String?
    private var dmg: URL?
    private var timer: Timer?
    private var downloadDone: ((URL?, Error?) -> Void)?

    /** Every change of state goes here (the page's onChange listeners). */
    var onChange: (([String: Any]) -> Void)?

    var state: [String: Any] {
        var a: Any = NSNull()
        if let v = available { a = ["version": v.version, "path": v.path, "notes": v.notes] }
        return ["status": status, "current": current, "available": a, "progress": progress,
                "error": error.map { $0 as Any } ?? NSNull(), "platform": "mac"]
    }

    private func set(_ s: String? = nil, progress p: Int? = nil, error e: String?? = nil) {
        if let s { status = s }
        if let p { progress = p }
        if let e { error = e }
        let snapshot = state
        DispatchQueue.main.async { self.onChange?(snapshot) }
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.check() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkEvery, repeats: true) { [weak self] _ in self?.check() }
    }

    // MARK: Check

    func check(quiet: Bool = true, done: (([String: Any]) -> Void)? = nil) {
        if ["downloading", "ready", "installing"].contains(status) { done?(state); return }
        set("checking", error: .some(nil))
        var req = URLRequest(url: URL(string: "\(feed)/latest-mac.yml?t=\(Int(Date().timeIntervalSince1970))")!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 30
        req.setValue("EBDAAI/\(current) (Macintosh)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let data, code == 200, let latest = Self.parseLatest(String(decoding: data, as: UTF8.self)) {
                self.available = Self.newer(latest.version, than: self.current) ? latest : nil
                self.set(self.available == nil ? "latest" : "available")
            } else {
                let why = err?.localizedDescription ?? (code == 200 ? "latest-mac.yml is missing version / path" : "HTTP \(code)")
                self.set(quiet ? "idle" : "error", error: .some(why))
            }
            DispatchQueue.main.async { done?(self.state) }
        }.resume()
    }

    /** The few fields of latest-mac.yml we need (electron-builder's format). */
    static func parseLatest(_ text: String) -> Latest? {
        func pick(_ key: String) -> String? {
            guard let r = text.range(of: "(?m)^\(key):[ \\t]*['\"]?(.+?)['\"]?[ \\t]*$", options: .regularExpression) else { return nil }
            return String(text[r]).replacingOccurrences(of: "^\(key):[ \\t]*['\"]?", with: "", options: .regularExpression)
                .replacingOccurrences(of: "['\"]?[ \\t]*$", with: "", options: .regularExpression)
        }
        guard let version = pick("version"), let path = pick("path") else { return nil }
        var notes = ""
        if let r = text.range(of: "(?m)^releaseNotes:[ \\t]*[|>]-?[ \\t]*\\n((?:[ \\t]+.*\\n?)*)", options: .regularExpression) {
            notes = String(text[r]).components(separatedBy: "\n").dropFirst()
                .map { $0.replacingOccurrences(of: "^[ \\t]{2}", with: "", options: .regularExpression) }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Latest(version: version, path: path, sha512: pick("sha512") ?? "", notes: notes)
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let pa = a.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 }
        let pb = b.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) where (i < pa.count ? pa[i] : 0) != (i < pb.count ? pb[i] : 0) {
            return (i < pa.count ? pa[i] : 0) > (i < pb.count ? pb[i] : 0)
        }
        return false
    }

    // MARK: Download

    func download(done: (([String: Any]) -> Void)? = nil) {
        guard let a = available, status != "downloading" else { done?(state); return }
        set("downloading", progress: 0, error: .some(nil))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ebdaai-update")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent((a.path as NSString).lastPathComponent)
        let path = a.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? a.path
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        downloadDone = { [weak self] file, err in
            guard let self else { return }
            session.finishTasksAndInvalidate()
            do {
                if let err { throw err }
                guard let file else { throw Fail("The download stopped") }
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: file, to: target)
                if !a.sha512.isEmpty, try Self.sha512(of: target) != a.sha512 {
                    try? FileManager.default.removeItem(at: target)
                    throw Fail("The downloaded update is damaged (checksum mismatch) — try again")
                }
                self.dmg = target
                self.set("ready", progress: 100)
            } catch {
                self.set("error", error: .some(error.localizedDescription))
            }
            DispatchQueue.main.async { done?(self.state) }
        }
        session.downloadTask(with: URL(string: "\(feed)/\(path)")!).resume()
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten got: Int64, totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        let p = Int(Double(got) / Double(total) * 100)
        if p != progress { set(progress: p) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { downloadDone?(nil, Fail("HTTP \(code) for the update")); downloadDone = nil; return }
        // The temp file is removed when this returns: keep it.
        let keep = location.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.moveItem(at: location, to: keep); downloadDone?(keep, nil) } catch { downloadDone?(nil, error) }
        downloadDone = nil
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { downloadDone?(nil, error); downloadDone = nil }
    }

    static func sha512(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA512()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return Data(hasher.finalize()).base64EncodedString()
    }

    // MARK: Install

    /** Copies the new EBDAAI.app next to this one, then a small script swaps them once we quit and reopens it. */
    func install(done: (([String: Any]) -> Void)? = nil) {
        guard let dmg, status == "ready" else { done?(state); return }
        let app = Bundle.main.bundleURL
        let parent = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path), !app.path.contains("/AppTranslocation/") else {
            set("error", error: .some("Move EBDAAI to the Applications folder first, then update — انقل إبداعي لمجلد التطبيقات وبعدين حدّث"))
            done?(state); return
        }
        set("installing")
        DispatchQueue.global().async {
            do {
                let mount = try Self.attach(dmg)
                defer { _ = Self.run("/usr/bin/hdiutil", ["detach", mount, "-quiet", "-force"]) }
                let fresh = URL(fileURLWithPath: mount).appendingPathComponent("EBDAAI.app")
                guard FileManager.default.fileExists(atPath: fresh.path) else { throw Fail("EBDAAI.app isn't in the update") }
                let stage = parent.appendingPathComponent(".EBDAAI-update.app")
                try? FileManager.default.removeItem(at: stage)
                guard Self.run("/usr/bin/ditto", [fresh.path, stage.path]) == 0 else { throw Fail("Couldn't copy the update") }
                _ = Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stage.path])

                let script = """
                while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
                rm -rf "$1" && mv "$2" "$1" && open "$1"
                """
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = ["-c", script, "ebdaai-update", app.path, stage.path]
                try p.run()
                try? FileManager.default.removeItem(at: dmg)
                DispatchQueue.main.async {
                    done?(self.state)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
                }
            } catch {
                self.set("error", error: .some(error.localizedDescription))
                DispatchQueue.main.async { done?(self.state) }
            }
        }
    }

    /** Mounts the DMG out of sight → its mount point. */
    static func attach(_ dmg: URL) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-plist"]
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let points = (plist?["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
        guard let mount = points.first else { throw Fail("Couldn't open the update") }
        return mount
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

struct Fail: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}
