// LumpDesk: a floating, draggable "virtual glass prism" desktop window for Lump,
// with built-in voice input (smart Shure -> MacBook mic selection + live audio meter),
// double-tap Option (⌥ ⌥) global hotkey, and Kokoro neural TTS via voice_worker.py (:47824).
// Build and launch: zsh tools/lumpdesk/build.sh

import AVFoundation
import Carbon.HIToolbox
import Cocoa
import WebKit

let WIDGET_URL = URL(string: "http://127.0.0.1:47823/widget?widget=1")!
let BRIDGE_STATUS_URL = URL(string: "http://127.0.0.1:47823/status")!
let SOUND_URL = URL(string: "http://127.0.0.1:47823/sound")!
let VOICE_BASE = "http://127.0.0.1:47824"
let PREF_MIC_KEY = "LumpDeskPreferredMicUID"
let PREF_AUTO_MEETING_KEY = "LumpDeskAutoRecordMeetings"

final class DragOverlayView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    private var downLoc: NSPoint = .zero
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?(event)
            return
        }
        downLoc = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        let cur = event.locationInWindow
        let dx = cur.x - downLoc.x
        let dy = cur.y - downLoc.y
        if !didDrag && hypot(dx, dy) > 4 {
            didDrag = true
        }
        if didDrag {
            var origin = win.frame.origin
            origin.x += dx
            origin.y += dy
            win.setFrameOrigin(origin)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

final class MicButton: NSButton {
    var isRecording = false {
        didSet { updateStyle() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        title = ""
        imagePosition = .imageOnly
        updateStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateStyle() {
        layer?.cornerRadius = bounds.width / 2
        layer?.borderWidth = 1.2
        if isRecording {
            layer?.backgroundColor = NSColor(calibratedRed: 0.92, green: 0.22, blue: 0.24, alpha: 0.92).cgColor
            layer?.borderColor = NSColor(white: 1.0, alpha: 0.6).cgColor
            if let img = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop") {
                image = img
            }
            contentTintColor = .white
        } else {
            layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.78).cgColor
            layer?.borderColor = NSColor(white: 1.0, alpha: 0.22).cgColor
            if let img = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Talk to Lump") {
                image = img
            }
            contentTintColor = NSColor(white: 0.95, alpha: 0.95)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, AVCaptureFileOutputRecordingDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var micButton: MicButton!
    var statusBadge: NSTextField!
    var levelBarBg: NSView!
    var levelBarFill: NSView!
    var alwaysOnTop = true
    var currentSize: CGFloat = 180

    private var captureSession: AVCaptureSession?
    private var fileOutput: AVCaptureAudioFileOutput?
    private var levelTimer: Timer?
    private var recordingURL: URL?
    private var isRecording = false
    private var recordingMode = "dictate" // "dictate" (paste into active app) or "agent" (Lump runs & speaks)
    private var lastTranscript = ""
    private var lastReply = ""
    private var voiceState = "idle"
    private var activeMicName = ""
    private let meetingRecorder = MeetingRecorder()
    private var autoRecordedStarts: Set<Int> = []

    private var optionDown = false
    private var otherKeyDuringOption = false
    private var lastOptionTap: TimeInterval = 0

    // MARK: - Microphone Discovery & Auto Selection

    private func availableMicrophones() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices
    }

    private func preferredMicUID() -> String {
        return UserDefaults.standard.string(forKey: PREF_MIC_KEY) ?? "auto"
    }

    private func resolveMicrophone() -> AVCaptureDevice? {
        let devs = availableMicrophones()
        let pref = preferredMicUID()
        if pref != "auto", let exact = devs.first(where: { $0.uniqueID == pref }) {
            return exact
        }
        // Auto mode: prefer physical Shure hardware first, then MacBook mic, then system default
        let shureKeywords = ["shure", "mv7", "mv6", "mv88", "sm7"]
        if let shure = devs.first(where: { d in
            let n = d.localizedName.lowercased()
            return shureKeywords.contains(where: { n.contains($0) })
        }) {
            return shure
        }
        if let mac = devs.first(where: { $0.localizedName.lowercased().contains("macbook") }) {
            return mac
        }
        return AVCaptureDevice.default(for: .audio) ?? devs.first
    }

    // MARK: - Double-tap Option Hotkey

    private func handleFlagEvent(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.option, .command, .control, .shift])
        if mods == [.option] {
            if !optionDown {
                optionDown = true
                otherKeyDuringOption = false
            }
        } else if mods.isEmpty {
            if optionDown {
                optionDown = false
                if !otherKeyDuringOption {
                    let now = Date().timeIntervalSinceReferenceDate
                    if now - lastOptionTap < 0.38 {
                        lastOptionTap = 0
                        DispatchQueue.main.async { self.toggleRecordingWithMode("dictate") }
                    } else {
                        lastOptionTap = now
                    }
                }
            }
        } else {
            otherKeyDuringOption = true
        }
    }

    private func registerGlobalHotKey() {
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] ev in
            guard let self = self else { return }
            if ev.type == .keyDown {
                self.otherKeyDuringOption = true
            } else {
                self.handleFlagEvent(ev)
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] ev in
            guard let self = self else { return ev }
            if ev.type == .keyDown {
                self.otherKeyDuringOption = true
            } else {
                self.handleFlagEvent(ev)
            }
            return ev
        }
    }

    // MARK: - Window Setup

    func applicationDidFinishLaunching(_ note: Notification) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let origin = NSPoint(x: screen.maxX - currentSize - 32, y: screen.minY + 32)
        let rect = NSRect(origin: origin, size: NSSize(width: currentSize, height: currentSize))

        window = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isMovable = false

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.cornerRadius = 26
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.borderWidth = 1.5
        container.layer?.borderColor = NSColor(white: 1.0, alpha: 0.16).cgColor

        let cfg = WKWebViewConfiguration()
        webView = WKWebView(frame: container.bounds, configuration: cfg)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: WIDGET_URL))
        container.addSubview(webView)

        let overlay = DragOverlayView(frame: container.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClick = { [weak self] in self?.triggerTap() }
        overlay.onRightClick = { [weak self] ev in self?.showMenu(ev) }
        container.addSubview(overlay)

        // Status pill (top-left)
        statusBadge = NSTextField(labelWithString: "")
        statusBadge.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        statusBadge.textColor = .white
        statusBadge.wantsLayer = true
        statusBadge.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        statusBadge.layer?.cornerRadius = 9
        statusBadge.alignment = .center
        statusBadge.isHidden = true
        statusBadge.frame = NSRect(x: 12, y: rect.height - 30, width: 108, height: 18)
        statusBadge.autoresizingMask = [.minYMargin, .maxXMargin]
        container.addSubview(statusBadge)

        // Live audio level meter (below status pill while recording)
        levelBarBg = NSView(frame: NSRect(x: 12, y: rect.height - 38, width: 108, height: 5))
        levelBarBg.wantsLayer = true
        levelBarBg.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.18).cgColor
        levelBarBg.layer?.cornerRadius = 2.5
        levelBarBg.isHidden = true
        levelBarBg.autoresizingMask = [.minYMargin, .maxXMargin]
        levelBarFill = NSView(frame: NSRect(x: 0, y: 0, width: 4, height: 5))
        levelBarFill.wantsLayer = true
        levelBarFill.layer?.backgroundColor = NSColor(calibratedRed: 0.25, green: 0.90, blue: 0.45, alpha: 0.95).cgColor
        levelBarFill.layer?.cornerRadius = 2.5
        levelBarBg.addSubview(levelBarFill)
        container.addSubview(levelBarBg)

        // Mic button (bottom-right)
        let btnSize: CGFloat = 34
        micButton = MicButton(frame: NSRect(x: rect.width - btnSize - 10, y: 10, width: btnSize, height: btnSize))
        micButton.autoresizingMask = [.minXMargin, .maxYMargin]
        micButton.target = self
        micButton.action = #selector(toggleRecording)
        micButton.toolTip = "Click or double-tap ⌥ Option to talk to Lump (again to send)"
        container.addSubview(micButton)

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        registerGlobalHotKey()

        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.pollVoiceHealth()
        }
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkCalendarAutoMeeting()
        }
    }

    private func isAutoRecordEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: PREF_AUTO_MEETING_KEY) == nil { return true }
        return UserDefaults.standard.bool(forKey: PREF_AUTO_MEETING_KEY)
    }

    private func checkCalendarAutoMeeting() {
        let now = Date().timeIntervalSince1970
        // Auto-stop if an auto-started meeting has passed its end time
        if meetingRecorder.isActive, let endT = meetingRecorder.autoStartedEndTime, now > endT + 60 {
            DispatchQueue.main.async {
                self.meetingRecorder.stop()
                self.updateBadge()
            }
            return
        }
        guard isAutoRecordEnabled(), !meetingRecorder.isActive else { return }

        URLSession.shared.dataTask(with: BRIDGE_STATUS_URL) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mtg = obj["next_meeting"] as? [String: Any],
                  let start = mtg["start"] as? TimeInterval else { return }
            let startKey = Int(start)
            guard !self.autoRecordedStarts.contains(startKey) else { return }
            let elapsed = now - start
            // Auto-start within 0..5 minutes of scheduled start time
            if elapsed >= -15 && elapsed <= 300 {
                self.autoRecordedStarts.insert(startKey)
                let title = (mtg["summary"] as? String) ?? (mtg["title"] as? String) ?? "Calendar Meeting"
                let endT = (mtg["end"] as? TimeInterval) ?? (start + 3600)
                DispatchQueue.main.async {
                    self.meetingRecorder.start(title: title, mic: self.resolveMicrophone(), endTime: endT)
                    self.updateBadge()
                }
            }
        }.resume()
    }

    private func setVoiceMood(_ mood: String?) {
        let js = mood == nil
            ? "window.__lumpSetVoiceMood && window.__lumpSetVoiceMood(null)"
            : "window.__lumpSetVoiceMood && window.__lumpSetVoiceMood('\(mood!)')"
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func updateBadge() {
        DispatchQueue.main.async {
            self.statusBadge.isHidden = true
            self.levelBarBg.isHidden = true
            if self.isRecording {
                self.setVoiceMood("awake")
                self.window.contentView?.layer?.borderColor = NSColor(calibratedRed: 0.95, green: 0.28, blue: 0.30, alpha: 0.85).cgColor
                self.window.contentView?.layer?.borderWidth = 2.0
            } else if self.meetingRecorder.isActive {
                self.setVoiceMood("working")
                self.window.contentView?.layer?.borderColor = NSColor(calibratedRed: 0.65, green: 0.32, blue: 0.96, alpha: 0.85).cgColor
                self.window.contentView?.layer?.borderWidth = 2.5
            } else if self.voiceState == "transcribing" || self.voiceState == "working" {
                self.setVoiceMood("working")
                self.window.contentView?.layer?.borderColor = NSColor(calibratedRed: 0.26, green: 0.52, blue: 0.96, alpha: 0.70).cgColor
                self.window.contentView?.layer?.borderWidth = 2.0
            } else if self.voiceState == "speaking" {
                self.setVoiceMood("done")
                self.window.contentView?.layer?.borderColor = NSColor(calibratedRed: 0.16, green: 0.75, blue: 0.50, alpha: 0.75).cgColor
                self.window.contentView?.layer?.borderWidth = 2.0
            } else {
                self.setVoiceMood(nil)
                self.window.contentView?.layer?.borderColor = NSColor(white: 1.0, alpha: 0.16).cgColor
                self.window.contentView?.layer?.borderWidth = 1.5
            }
        }
    }

    private func pollVoiceHealth() {
        guard let url = URL(string: "\(VOICE_BASE)/health") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.voiceState = (obj["state"] as? String) ?? "idle"
            self.lastTranscript = (obj["last_transcript"] as? String) ?? ""
            self.lastReply = (obj["last_reply"] as? String) ?? ""
            self.updateBadge()
        }.resume()
    }

    // MARK: - Recording (AVCaptureSession with explicit mic device + live meter)

    @objc func toggleRecording() {
        toggleRecordingWithMode("agent")
    }

    @objc func toggleDictation() {
        toggleRecordingWithMode("dictate")
    }

    private func toggleRecordingWithMode(_ mode: String) {
        if isRecording {
            stopAndSendRecording()
        } else {
            recordingMode = mode
            startRecordingWithPermission()
        }
    }

    private func startRecordingWithPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.beginRecording() }
                }
            }
        default:
            let alert = NSAlert()
            alert.messageText = "Microphone Permission Needed"
            alert.informativeText = "Allow LumpDesk in System Settings → Privacy & Security → Microphone so you can talk to Lump."
            alert.runModal()
        }
    }

    private func beginRecording() {
        postSimple("\(VOICE_BASE)/stop_speaking")

        guard let mic = resolveMicrophone() else {
            NSLog("LumpDesk: no audio input device found")
            return
        }
        activeMicName = mic.localizedName
        NSLog("LumpDesk: recording with mic: \(activeMicName)")

        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: mic)
            guard session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureAudioFileOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)

            session.startRunning()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lump_voice_\(UUID().uuidString).m4a")
            output.startRecording(to: tmp, outputFileType: .m4a, recordingDelegate: self)

            captureSession = session
            fileOutput = output
            recordingURL = tmp
            isRecording = true
            micButton.isRecording = true
            updateBadge()

            levelTimer?.invalidate()
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                self?.updateLevelMeter()
            }
        } catch {
            NSLog("LumpDesk: failed to start recording: \(error)")
        }
    }

    private func updateLevelMeter() {
        guard let conn = fileOutput?.connection(with: .audio),
              let ch = conn.audioChannels.first else { return }
        // Pulse the prism rim brightness & thickness subtly with your voice level
        let db = max(-55.0, min(0.0, Double(ch.averagePowerLevel)))
        let norm = CGFloat((db + 55.0) / 55.0)
        self.window.contentView?.layer?.borderWidth = 1.8 + norm * 3.2
        self.window.contentView?.layer?.borderColor = NSColor(
            calibratedRed: 0.95,
            green: 0.25 + norm * 0.35,
            blue: 0.28 + norm * 0.25,
            alpha: 0.55 + norm * 0.45
        ).cgColor
    }

    private func stopAndSendRecording() {
        levelTimer?.invalidate()
        levelTimer = nil
        isRecording = false
        micButton.isRecording = false
        voiceState = "transcribing"
        updateBadge()
        fileOutput?.stopRecording()
    }

    private func pasteTextIntoActiveApp(_ text: String) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        let trusted = AXIsProcessTrusted()
        if !trusted {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            // Keep transcribed text on clipboard so user can Cmd+V immediately until Accessibility is granted
            return
        }

        // Send synthetic Cmd+V to the currently focused app
        let src = CGEventSource(stateID: .hidSystemState)
        let keyV: CGKeyCode = 9 // 'v'
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: true),
           let up = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: false) {
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }

        // Restore previous clipboard contents shortly after paste completes
        if let prev = previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if pb.string(forType: .string) == text {
                    pb.clearContents()
                    pb.setString(prev, forType: .string)
                }
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        captureSession?.stopRunning()
        captureSession = nil
        fileOutput = nil

        guard let data = try? Data(contentsOf: outputFileURL), data.count > 1000 else {
            try? FileManager.default.removeItem(at: outputFileURL)
            voiceState = "idle"
            updateBadge()
            return
        }
        try? FileManager.default.removeItem(at: outputFileURL)

        let mode = recordingMode
        let path = mode == "dictate" ? "/transcribe" : "/transcribe_and_run"
        guard let endpoint = URL(string: "\(VOICE_BASE)\(path)") else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req) { [weak self] respData, _, _ in
            guard let self = self else { return }
            if mode == "dictate" {
                if let respData = respData,
                   let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                   let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    self.lastTranscript = text
                    DispatchQueue.main.async {
                        self.pasteTextIntoActiveApp(text)
                    }
                }
                self.voiceState = "idle"
                self.updateBadge()
            }
        }.resume()
    }

    // MARK: - Actions & Menu

    private func postSimple(_ urlStr: String) {
        guard let url = URL(string: urlStr) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        URLSession.shared.dataTask(with: req).resume()
    }

    @objc func selectMic(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String {
            UserDefaults.standard.set(uid, forKey: PREF_MIC_KEY)
        }
    }

    @objc func toggleMeetingRecording() {
        if meetingRecorder.isActive {
            meetingRecorder.stop()
        } else {
            meetingRecorder.start(title: "", mic: resolveMicrophone())
        }
        updateBadge()
    }

    @objc func toggleAutoRecordMeetings() {
        UserDefaults.standard.set(!isAutoRecordEnabled(), forKey: PREF_AUTO_MEETING_KEY)
    }

    @objc func openPAFolder() {
        let path = NSString(string: "~/Documents/Lump-PA").expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc func triggerTap() {
        webView.evaluateJavaScript("window.__lumpWidgetTap && window.__lumpWidgetTap()", completionHandler: nil)
    }

    @objc func stopSpeaking() { postSimple("\(VOICE_BASE)/stop_speaking") }
    @objc func resetVoiceSession() { postSimple("\(VOICE_BASE)/reset") }

    @objc func showLastReply() {
        let alert = NSAlert()
        alert.messageText = "Last Voice Exchange"
        let heard = lastTranscript.isEmpty ? "(nothing yet)" : lastTranscript
        let said = lastReply.isEmpty ? "(no reply yet)" : lastReply
        let mic = activeMicName.isEmpty ? (resolveMicrophone()?.localizedName ?? "Default") : activeMicName
        alert.informativeText = "Mic: \(mic)\n\nYou: \(heard)\n\nLump: \(said)"
        alert.runModal()
    }

    @objc func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        window.level = alwaysOnTop ? .floating : .normal
    }

    @objc func setSize(_ sender: NSMenuItem) {
        let s = CGFloat(sender.tag)
        currentSize = s
        var f = window.frame
        let dy = s - f.height
        f.origin.y -= dy
        f.size = NSSize(width: s, height: s)
        window.setFrame(f, display: true, animate: true)
    }

    @objc func toggleSound() {
        var req = URLRequest(url: SOUND_URL)
        req.httpMethod = "POST"
        req.httpBody = "toggle".data(using: .utf8)
        URLSession.shared.dataTask(with: req).resume()
    }

    @objc func reloadWidget() { webView.load(URLRequest(url: WIDGET_URL)) }
    @objc func quitApp() { NSApp.terminate(nil) }

    func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: isRecording ? "Stop Recording (⌥ ⌥)" : "Dictate into Active App (⌥ ⌥)", action: #selector(toggleDictation), keyEquivalent: "")
        menu.addItem(withTitle: "Ask Lump Agent (Mic Button)", action: #selector(toggleRecording), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: meetingRecorder.isActive ? "Stop Meeting Notes & Summarize" : "Start Meeting Notes (Dual-Track)", action: #selector(toggleMeetingRecording), keyEquivalent: "")
        let autoMtg = NSMenuItem(title: "Auto-Record Calendar Meetings", action: #selector(toggleAutoRecordMeetings), keyEquivalent: "")
        autoMtg.state = isAutoRecordEnabled() ? .on : .off
        menu.addItem(autoMtg)
        menu.addItem(withTitle: "Open Lump-PA Folder (Today & Meetings)", action: #selector(openPAFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Stop Speaking", action: #selector(stopSpeaking), keyEquivalent: "")
        menu.addItem(withTitle: "Show Last Reply", action: #selector(showLastReply), keyEquivalent: "")
        menu.addItem(withTitle: "New Voice Conversation", action: #selector(resetVoiceSession), keyEquivalent: "")

        // Microphone submenu
        let micMenu = NSMenu()
        let pref = preferredMicUID()
        let autoResolved = resolveMicrophone()?.localizedName ?? "Default"
        let autoItem = NSMenuItem(title: "Auto: Shure → MacBook (now: \(autoResolved))", action: #selector(selectMic(_:)), keyEquivalent: "")
        autoItem.representedObject = "auto"
        autoItem.state = pref == "auto" ? .on : .off
        micMenu.addItem(autoItem)
        micMenu.addItem(.separator())
        for dev in availableMicrophones() {
            let it = NSMenuItem(title: dev.localizedName, action: #selector(selectMic(_:)), keyEquivalent: "")
            it.representedObject = dev.uniqueID
            it.state = pref == dev.uniqueID ? .on : .off
            micMenu.addItem(it)
        }
        let micParent = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micParent.submenu = micMenu
        menu.addItem(micParent)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Tap Lump (Random Gag)", action: #selector(triggerTap), keyEquivalent: "")

        let topItem = NSMenuItem(title: "Always on Top", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        topItem.state = alwaysOnTop ? .on : .off
        menu.addItem(topItem)

        let sizeMenu = NSMenu()
        for (label, px) in [("Small (180px)", 180), ("Medium (240px)", 240), ("Large (320px)", 320)] {
            let it = NSMenuItem(title: label, action: #selector(setSize(_:)), keyEquivalent: "")
            it.tag = px
            it.state = Int(currentSize) == px ? .on : .off
            sizeMenu.addItem(it)
        }
        let sizeParent = NSMenuItem(title: "Prism Size", action: nil, keyEquivalent: "")
        sizeParent.submenu = sizeMenu
        menu.addItem(sizeParent)

        menu.addItem(withTitle: "Mute / Unmute Sound", action: #selector(toggleSound), keyEquivalent: "")
        menu.addItem(withTitle: "Reload", action: #selector(reloadWidget), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LumpDesk", action: #selector(quitApp), keyEquivalent: "q")

        NSMenu.popUpContextMenu(menu, with: event, for: window.contentView!)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
