// EBDAAI for macOS — a native window around the local EBDAAI server.
// Starts the bundled Node server, waits for it, and shows the studio in a WKWebView.
// Quitting the app stops the server.

import Cocoa
import WebKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandlerWithReply {
    var window: NSWindow!
    var webView: WKWebView!
    var server: Process?
    var port = 3000
    var studioURL: URL { URL(string: "http://127.0.0.1:\(port)/studio")! }
    var downloadTargets: [ObjectIdentifier: URL] = [:]
    let updater = Updater()

    let resources = Bundle.main.resourceURL!
    let fm = FileManager.default
    lazy var dataDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/EBDAAI/data")
    lazy var logFile = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/EBDAAI/server.log")

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildWindow()
        showLoading("يشغّل إبداعي…")
        startServer()
        updater.onChange = { [weak self] s in self?.pushUpdateState(s) }
        updater.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) {
        guard let s = server, s.isRunning else { return }
        s.terminate()
        // Give Node a moment to exit cleanly, then make sure it is gone.
        let deadline = Date().addingTimeInterval(3)
        while s.isRunning && Date() < deadline { usleep(100_000) }
        if s.isRunning { kill(s.processIdentifier, SIGKILL) }
    }

    // MARK: Server

    func startServer() {
        port = freePort(from: 3000)
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: logFile.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logFile)

        var env = ProcessInfo.processInfo.environment
        env["NODE_ENV"] = "production"
        env["PORT"] = String(port)
        env["HOSTNAME"] = "127.0.0.1"
        env["EBDAEA_DATA_DIR"] = dataDir.path
        if env["COMFYUI_URL"] == nil, let comfy = findComfyUI() { env["COMFYUI_URL"] = comfy }

        let p = Process()
        p.executableURL = resources.appendingPathComponent("node/bin/node")
        p.arguments = [resources.appendingPathComponent("app/server.js").path]
        p.currentDirectoryURL = resources.appendingPathComponent("app")
        p.environment = env
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.serverExited(proc.terminationStatus) }
        }
        do {
            try p.run()
            server = p
            waitForServer(tries: 120)
        } catch {
            showError("ما قدر يشغّل السيرفر: \(error.localizedDescription)")
        }
    }

    func waitForServer(tries: Int) {
        guard tries > 0 else { showError("السيرفر ما رد. شوف السجل: \(logFile.path)"); return }
        var req = URLRequest(url: studioURL)
        req.timeoutInterval = 1
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let http = resp as? HTTPURLResponse, http.statusCode < 500 {
                    self.webView.load(URLRequest(url: self.studioURL))
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitForServer(tries: tries - 1) }
                }
            }
        }.resume()
    }

    func serverExited(_ status: Int32) {
        // Normal on quit; otherwise tell the user where the log is.
        if NSApp.isRunning && !isTerminating { showError("السيرفر وقف (\(status)). شوف السجل: \(logFile.path)") }
    }
    var isTerminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        return .terminateNow
    }

    // Comfy Desktop listens on 8000, a manual ComfyUI on 8188.
    func findComfyUI() -> String? {
        for p in [8000, 8188] {
            let url = "http://127.0.0.1:\(p)"
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            var req = URLRequest(url: URL(string: url + "/system_stats")!)
            req.timeoutInterval = 1.5
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                ok = (resp as? HTTPURLResponse)?.statusCode == 200
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 2)
            if ok { return url }
        }
        return nil
    }

    func freePort(from start: Int) -> Int {
        for p in start..<(start + 100) where portIsFree(p) { return p }
        return start
    }

    func portIsFree(_ p: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(p).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    // MARK: Window

    func buildWindow() {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()
        config.userContentController.addUserScript(WKUserScript(source: Self.bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "ebdaai")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.setValue(false, forKey: "drawsBackground")

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "EBDAAI"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0x0B/255, green: 0x0D/255, blue: 0x12/255, alpha: 1)
        window.minSize = NSSize(width: 900, height: 600)
        window.contentView = webView
        window.setFrameAutosaveName("EBDAAIMain")
        if !window.setFrameUsingName("EBDAAIMain") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showLoading(_ text: String) {
        webView.loadHTMLString(page(text, color: "#9AA4B8", spinner: true), baseURL: nil)
    }

    func showError(_ text: String) {
        webView.loadHTMLString(page(text, color: "#FF6B6B", spinner: false), baseURL: nil)
    }

    func page(_ text: String, color: String, spinner: Bool) -> String {
        let esc = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <html dir="rtl"><body style="margin:0;height:100vh;display:flex;flex-direction:column;gap:18px;align-items:center;justify-content:center;background:#0B0D12;color:\(color);font:15px -apple-system,'SF Arabic',sans-serif;-webkit-user-select:text">
        \(spinner ? "<div style='width:34px;height:34px;border:3px solid #1E6BFF33;border-top-color:#1E6BFF;border-radius:50%;animation:s .8s linear infinite'></div><style>@keyframes s{to{transform:rotate(360deg)}}</style>" : "")
        <div style="max-width:560px;text-align:center;line-height:1.7">\(esc)</div></body></html>
        """
    }

    // MARK: Menu

    func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(); let sub = NSMenu(title: title)
            items.forEach(sub.addItem); top.submenu = sub; main.addItem(top)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; return i
        }
        add("EBDAAI", [
            item("عن EBDAAI", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            item("التحقق من التحديثات…", #selector(checkForUpdates), ""),
            .separator(),
            item("مجلد البيانات", #selector(openDataDir), ""),
            item("سجل السيرفر", #selector(openLog), ""),
            .separator(),
            item("إخفاء EBDAAI", #selector(NSApplication.hide(_:)), "h"),
            item("إخفاء الباقي", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("إنهاء EBDAAI", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add("تحرير", [
            item("تراجع", Selector(("undo:")), "z"),
            item("إعادة", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("قص", #selector(NSText.cut(_:)), "x"),
            item("نسخ", #selector(NSText.copy(_:)), "c"),
            item("لصق", #selector(NSText.paste(_:)), "v"),
            item("تحديد الكل", #selector(NSText.selectAll(_:)), "a"),
        ])
        add("عرض", [
            item("إعادة تحميل", #selector(reload), "r"),
            item("الاستوديو", #selector(goHome), "1"),
            item("رجوع", #selector(goBack), "["),
            item("تقدّم", #selector(goForward), "]"),
            .separator(),
            item("تكبير", #selector(zoomIn), "+"),
            item("تصغير", #selector(zoomOut), "-"),
            item("الحجم الأصلي", #selector(zoomReset), "0"),
            .separator(),
            item("افتح في المتصفح", #selector(openInBrowser), "b", [.command, .shift]),
            item("ملء الشاشة", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        add("نافذة", [
            item("تصغير", #selector(NSWindow.miniaturize(_:)), "m"),
            item("تكبير النافذة", #selector(NSWindow.zoom(_:)), ""),
        ])
        NSApp.mainMenu = main
    }

    @objc func reload() { if webView.url?.scheme == "http" { webView.reload() } else { webView.load(URLRequest(url: studioURL)) } }
    @objc func goHome() { webView.load(URLRequest(url: studioURL)) }
    @objc func goBack() { webView.goBack() }
    @objc func goForward() { webView.goForward() }
    @objc func zoomIn() { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
    @objc func zoomOut() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc func zoomReset() { webView.pageZoom = 1 }
    @objc func openInBrowser() { NSWorkspace.shared.open(webView.url?.scheme == "http" ? webView.url! : studioURL) }
    @objc func openDataDir() { NSWorkspace.shared.open(dataDir) }
    @objc func openLog() { NSWorkspace.shared.open(logFile) }

    // MARK: Bridge — window.ebdaai for the studio page: version, folder picker, in-app updates
    // (the same shape as desktop/preload.cjs, so UpdateCard and the rest work unchanged).

    static let bridgeJS = """
    (() => {
      if (!/^(127\\.0\\.0\\.1|localhost)$/.test(location.hostname)) return;
      const call = (op, arg) => window.webkit.messageHandlers.ebdaai.postMessage({ op, arg: arg ?? null });
      const subs = new Set();
      window.__ebdaaiUpdateState = (s) => subs.forEach((f) => { try { f(s); } catch {} });
      window.ebdaai = Object.freeze({
        platform: "mac",
        version: () => call("version"),
        pickFolder: (title) => call("pickFolder", title || ""),
        update: Object.freeze({
          state: () => call("update", "state"),
          check: () => call("update", "check"),
          download: () => call("update", "download"),
          install: () => call("update", "install"),
          onChange: (cb) => { subs.add(cb); return () => subs.delete(cb); },
        }),
      });
    })();
    """

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard isLocal(message.frameInfo.request.url) || ["127.0.0.1", "localhost"].contains(message.frameInfo.securityOrigin.host),
              let body = message.body as? [String: Any], let op = body["op"] as? String else { replyHandler(nil, "not allowed"); return }
        let arg = body["arg"] as? String
        switch (op, arg) {
        case ("version", _): replyHandler(updater.current, nil)
        case ("pickFolder", _):
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.message = arg ?? ""; panel.prompt = "اختيار"
            panel.beginSheetModal(for: window) { r in replyHandler(r == .OK ? panel.url?.path : nil, nil) }
        case ("update", "state"): replyHandler(updater.state, nil)
        case ("update", "check"): updater.check(quiet: false) { replyHandler($0, nil) }
        case ("update", "download"): updater.download { replyHandler($0, nil) }
        case ("update", "install"): updater.install { replyHandler($0, nil) }
        default: replyHandler(nil, "unknown: \(op)")
        }
    }

    func pushUpdateState(_ s: [String: Any]) {
        guard isLocal(webView.url), webView.url?.scheme == "http",
              let json = try? JSONSerialization.data(withJSONObject: s), let text = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__ebdaaiUpdateState && window.__ebdaaiUpdateState(\(text))")
    }

    /** From the menu: say so when there's nothing new; otherwise offer it right away. */
    @objc func checkForUpdates() {
        updater.check(quiet: false) { [weak self] s in
            guard let self else { return }
            let a = NSAlert()
            switch s["status"] as? String {
            case "available":
                let v = (s["available"] as? [String: Any])?["version"] as? String ?? ""
                a.messageText = "فيه تحديث جديد — \(v)"
                a.informativeText = "عندك \(self.updater.current)."
                a.addButton(withTitle: "حدّث الحين"); a.addButton(withTitle: "بعدين")
                if a.runModal() == .alertFirstButtonReturn { self.updater.download { if $0["status"] as? String == "ready" { self.updater.install() } } }
            case "latest", "ready", "downloading":
                a.messageText = s["status"] as? String == "latest" ? "عندك آخر نسخة (\(self.updater.current))" : "التحديث قاعد يتجهّز…"
                a.runModal()
            default:
                a.messageText = "ما قدر يتحقق من التحديثات"
                a.informativeText = s["error"] as? String ?? ""
                a.runModal()
            }
        }
    }

    // MARK: Navigation — the studio stays in the window, everything else opens in the browser

    func isLocal(_ url: URL?) -> Bool {
        guard let host = url?.host else { return url?.scheme == "about" || url?.scheme == "blob" || url?.scheme == "data" }
        return host == "127.0.0.1" || host == "localhost"
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.shouldPerformDownload { decisionHandler(.download); return }
        if let url = action.request.url, !isLocal(url), action.targetFrame?.isMainFrame != false {
            NSWorkspace.shared.open(url); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !response.canShowMIMEType || isAttachment(response.response) { decisionHandler(.download) } else { decisionHandler(.allow) }
    }

    func isAttachment(_ r: URLResponse) -> Bool {
        let cd = (r as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        return cd.lowercased().hasPrefix("attachment")
    }

    // target=_blank / window.open
    func webView(_ webView: WKWebView, createWebViewWith config: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isLocal(url) && url.scheme == "http" { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    // MARK: Downloads

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.directoryURL = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { completionHandler(nil); return }
            try? self?.fm.removeItem(at: url)
            self?.downloadTargets[ObjectIdentifier(download)] = url
            completionHandler(url)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = downloadTargets.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadTargets.removeValue(forKey: ObjectIdentifier(download))
        alert("فشل التنزيل", error.localizedDescription)
    }

    // MARK: File inputs and JS dialogs

    func webView(_ webView: WKWebView, runOpenPanelWith params: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = params.allowsMultipleSelection
        panel.canChooseDirectories = params.allowsDirectories
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { r in completionHandler(r == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        alert(message, nil); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message
        a.addButton(withTitle: "موافق"); a.addButton(withTitle: "إلغاء")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "موافق"); a.addButton(withTitle: "إلغاء")
        completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    // Microphone / camera for local pages only.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == "127.0.0.1" || origin.host == "localhost" ? .grant : .deny)
    }

    func alert(_ title: String, _ info: String?) {
        let a = NSAlert(); a.messageText = title; if let info { a.informativeText = info }; a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
