#!/bin/bash
# Builds "Phone Mirror.app" into ~/Applications. Needs Xcode Command Line Tools (xcode-select --install)
if ! command -v scrcpy >/dev/null 2>&1; then
    brew install scrcpy
fi

if ! command -v adb >/dev/null 2>&1; then
    brew install android-platform-tools
fi
set -e
APP="$HOME/Applications/Phone Mirror.app"
WORK="$(mktemp -d)"
mkdir -p "$APP/Contents/MacOS"

cat > "$WORK/PhoneMirror.swift" << 'EOF'
import Cocoa
import CoreImage

let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

func findBin(_ name: String) -> String? {
    for d in searchDirs {
        let p = "\(d)/\(name)"
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return nil
}

func childEnv(adb: String) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = searchDirs.joined(separator: ":") + ":" + (env["PATH"] ?? "/usr/bin:/bin")
    env["ADB"] = adb
    env["ADB_MDNS_OPENSCREEN"] = "1"
    return env
}

func qrImage(_ s: String) -> NSImage? {
    guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    f.setValue(s.data(using: .utf8), forKey: "inputMessage")
    f.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = f.outputImage else { return nil }
    let scale = floor(260 / out.extent.width)
    let scaled = out.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let img = NSImage(size: rep.size)
    img.addRepresentation(rep)
    return img
}

func randomString(_ n: Int) -> String {
    let chars = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    return String((0..<n).map { _ in chars.randomElement()! })
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let imageView = NSImageView()
    let status = NSTextField(wrappingLabelWithString: "")
    var cancelled = false
    var logStarted = false
    var scrcpyRunning = false
    var activity: NSObjectProtocol?
    var adb = ""
    var scrcpy = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        // Stop macOS from throttling (App Nap) this app and the adb/scrcpy it starts
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Mirroring phone over Wi-Fi")
        guard let a = findBin("adb"), let s = findBin("scrcpy") else {
            let al = NSAlert()
            al.messageText = "adb / scrcpy not found"
            al.informativeText = "Install with:\nbrew install scrcpy android-platform-tools"
            al.runModal()
            NSApp.terminate(nil); return
        }
        adb = a; scrcpy = s
        buildWindow()
        startPairing()
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 470),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Phone Mirror"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = window.contentView!

        imageView.frame = NSRect(x: 30, y: 170, width: 300, height: 280)
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.white.cgColor
        imageView.layer?.cornerRadius = 12
        content.addSubview(imageView)

        status.frame = NSRect(x: 30, y: 80, width: 300, height: 76)
        status.alignment = .center
        content.addSubview(status)

        let launchBtn = NSButton(title: "Already connected → launch now", target: self, action: #selector(launchExisting))
        launchBtn.frame = NSRect(x: 60, y: 42, width: 240, height: 28)
        content.addSubview(launchBtn)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelBtn.frame = NSRect(x: 130, y: 10, width: 100, height: 28)
        content.addSubview(cancelBtn)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setStatus(_ s: String) { DispatchQueue.main.async { self.status.stringValue = s } }

    @objc func cancel() { cancelled = true; NSApp.terminate(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if scrcpyRunning { sender.orderOut(nil); return false }   // keep the app alive while mirroring
        cancelled = true
        NSApp.terminate(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    @discardableResult
    func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = args
        p.environment = childEnv(adb: adb)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Returns [(name, type, address)] from `adb mdns services`
    func mdnsServices() -> [(String, String, String)] {
        run(["mdns", "services"]).split(separator: "\n").compactMap { line in
            let c = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            return c.count >= 3 ? (c[0], c[1], c[2]) : nil
        }
    }

    func onlineDevices() -> [String] {
        run(["devices"]).split(separator: "\n").dropFirst().compactMap { (l: Substring) -> String? in
            let c = l.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            return (c.count >= 2 && c[1] == "device") ? c[0] : nil
        }
    }

    /// Wait until the phone answers 3 times in a row (wireless links flap right after pairing)
    func waitStable(_ s: String) {
        var good = 0
        for _ in 0..<40 where good < 3 {
            let up = onlineDevices().contains(s)
            if !up { run(["reconnect", "offline"]) }
            let ok = up && run(["-s", s, "shell", "echo", "ok"])
                .trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
            good = ok ? good + 1 : 0
            Thread.sleep(forTimeInterval: 1)
        }
    }

    func startPairing() {
        let name = "ADB_WIFI_" + randomString(6)
        let pass = randomString(8)
        imageView.image = qrImage("WIFI:T:ADB;S:\(name);P:\(pass);;")
        setStatus("On your phone:\nDeveloper options → Wireless debugging →\nPair device with QR code, then scan.")

        DispatchQueue.global().async {
            self.run(["kill-server"])
            self.run(["start-server"])
            var pairAddr: String?
            let deadline = Date().addingTimeInterval(180)
            while !self.cancelled && Date() < deadline && pairAddr == nil {
                for (n, t, a) in self.mdnsServices() where n == name && t.contains("pairing") { pairAddr = a }
                if pairAddr == nil { Thread.sleep(forTimeInterval: 1) }
            }
            guard let addr = pairAddr else {
                if !self.cancelled { self.setStatus("Timed out waiting for the phone.\nReopen the app to try again.") }
                return
            }
            self.setStatus("Pairing…")
            let out = self.run(["pair", addr, pass])
            guard out.contains("Successfully paired") else {
                self.setStatus("Pairing failed:\n\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
                return
            }
            self.setStatus("Paired. Connecting…")
            let host = String(addr.split(separator: ":")[0])
            var serial: String?
            var explicitTried = false
            for i in 0..<40 where serial == nil {
                let devs = self.onlineDevices()
                if let auto = devs.first(where: { $0.contains("_adb-tls-connect") }) {
                    // drop any duplicate ip:port transport to the same phone
                    for d in devs where d.hasPrefix(host + ":") { self.run(["disconnect", d]) }
                    serial = auto
                } else if i >= 6 && !explicitTried {
                    explicitTried = true
                    for (_, t, a) in self.mdnsServices() where t.contains("connect") && a.hasPrefix(host + ":") {
                        self.run(["connect", a])
                    }
                } else if explicitTried, let d = devs.first(where: { $0.hasPrefix(host + ":") }) {
                    serial = d
                }
                if serial == nil { Thread.sleep(forTimeInterval: 1) }
            }
            guard let s = serial else {
                self.setStatus("Paired, but couldn't connect.\nMake sure Wireless debugging is still on.")
                return
            }
            self.setStatus("Connected. Waiting for the link to settle…")
            self.waitStable(s)
            self.setStatus("Starting scrcpy…")
            DispatchQueue.main.async { self.launch(s) }
        }
    }

    @objc func launchExisting() {
        DispatchQueue.global().async {
            let devs = self.onlineDevices()
            let dev = devs.first(where: { $0.contains("_adb-tls-connect") }) ?? devs.first
            if let d = dev { DispatchQueue.main.async { self.launch(d) } }
            else { self.setStatus("No connected device found.\nScan the QR code instead.") }
        }
    }

    func launch(_ serial: String, attempt: Int = 1) {
        cancelled = true
        imageView.image = nil
        let started = Date()
        scrcpyRunning = true
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PhoneMirror.log")
        if !logStarted { logStarted = true; FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let log = try? FileHandle(forWritingTo: logURL)
        log?.seekToEndOfFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: scrcpy)
        p.arguments = ["-s", serial, "--turn-screen-off"]
        p.environment = childEnv(adb: adb)
        p.standardOutput = log ?? FileHandle.nullDevice
        p.standardError = log ?? FileHandle.nullDevice
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                self.scrcpyRunning = false
                if proc.terminationStatus == 0 { NSApp.terminate(nil); return }
                let ranLong = Date().timeIntervalSince(started) >= 20
                let next = ranLong ? 1 : attempt + 1
                if next <= 3 {
                    self.status.stringValue = ranLong
                        ? "Connection dropped, reconnecting…"
                        : "scrcpy failed, retrying (\(next)/3)…"
                    self.window.makeKeyAndOrderFront(nil)
                    DispatchQueue.global().async {
                        self.waitStable(serial)
                        DispatchQueue.main.async { self.launch(serial, attempt: next) }
                    }
                    return
                }
                let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                let tail = text.split(separator: "\n").suffix(12).joined(separator: "\n")
                let al = NSAlert()
                al.messageText = "scrcpy exited (code \(proc.terminationStatus))"
                al.informativeText = tail + "\n\nFull log: ~/Library/Logs/PhoneMirror.log"
                NSApp.activate(ignoringOtherApps: true)
                al.runModal()
                NSApp.terminate(nil)
            }
        }
        do { try p.run() } catch {
            let al = NSAlert()
            al.messageText = "Couldn't start scrcpy"
            al.informativeText = "\(error)"
            al.runModal()
            NSApp.terminate(nil)
        }
        // hide this window once scrcpy has stayed up for a few seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if p.isRunning { self.window.orderOut(nil) }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
EOF

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Phone Mirror</string>
<key>CFBundleDisplayName</key><string>Phone Mirror</string>
<key>CFBundleIdentifier</key><string>local.phonemirror</string>
<key>CFBundleExecutable</key><string>PhoneMirror</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>11.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppSleepDisabled</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Finds your phone on the local network for wireless debugging.</string>
<key>NSBonjourServices</key><array>
<string>_adb-tls-pairing._tcp</string>
<string>_adb-tls-connect._tcp</string>
</array>
</dict></plist>
EOF

swiftc -O "$WORK/PhoneMirror.swift" -o "$APP/Contents/MacOS/PhoneMirror"
codesign --force --sign - "$APP" 2>/dev/null || true
rm -rf "$WORK"
echo "Built: $APP"
open -R "$APP"
