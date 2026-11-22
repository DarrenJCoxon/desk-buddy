// LumpDesk: a floating, draggable "virtual glass prism" desktop window for Lump,
// with built-in voice input (smart Shure -> MacBook mic selection + live audio meter),
// double-tap Option (⌥ ⌥) global hotkey, and Kokoro neural TTS via voice_worker.py (:47824).
// Build and launch: zsh tools/lumpdesk/build.sh

import AVFoundation
import Carbon.HIToolbox
import Cocoa
import CoreAudio
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

final class AppDelegate: NSObject, NSApplicationDelegate, AVCaptureFileOutputRecordingDelegate, NSMenuDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var micButton: MicButton!
    var statusBadge: NSTextField!
    var levelBarBg: NSView!
    var levelBarFill: NSView!
    var statusItem: NSStatusItem!
    var notchWindow: NSPanel?
    var notchIconView: NSImageView?
    var alwaysOnTop = true
    var prismVisible = true
    var currentSize: CGFloat = 180

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioFileLock = NSLock()
    private var recordingURL: URL?
    private var isRecording = false
    private var recordingMode = "dictate" // "dictate" (paste into active app) or "agent" (Lump runs & speaks)
    private var lastTranscript = ""
    private var lastReply = ""
    private var voiceState = "idle"
    private var currentColourHex = "4285F4"
    private var cachedIconHex = ""
    private var cachedMenuIcon: NSImage?
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
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
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
        setupMenuBarItem()
        setupNotchWing()
        registerGlobalHotKey()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

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
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let col = obj["colour"] as? String, !col.isEmpty, col != self.currentColourHex {
                self.currentColourHex = col
                DispatchQueue.main.async { self.updateMenuBarIcon() }
            }
            guard let mtg = obj["next_meeting"] as? [String: Any],
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

    private func loadPixels(_ url: URL) -> (px: [UInt8], w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (buf, w, h) : nil
    }

    private func renderLumpIcon(hex: String, targetSize: CGFloat) -> NSImage? {
        guard let kURL = Bundle.main.url(forResource: "awake-glow-k", withExtension: "png"),
              let wURL = Bundle.main.url(forResource: "awake-glow-w", withExtension: "png"),
              let k = loadPixels(kURL), let w = loadPixels(wURL), k.w == w.w, k.h == w.h else { return nil }
        let v = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x4285F4
        let cr = (v >> 16) & 255, cg = (v >> 8) & 255, cb = v & 255
        // Frame 0 is a square of size h x h at the left end of the strip
        let side = k.h
        var out = [UInt8](repeating: 0, count: side * side * 4)
        var minX = side, maxX = 0, minY = side, maxY = 0
        for y in 0..<side {
            for x in 0..<side {
                let si = (y * k.w + x) * 4
                let di = (y * side + x) * 4
                let kr = Int(k.px[si]), kg = Int(k.px[si + 1]), kb = Int(k.px[si + 2])
                let wr = Int(w.px[si]), wg = Int(w.px[si + 1]), wb = Int(w.px[si + 2])
                let a = k.px[si + 3]
                out[di]     = UInt8(max(0, min(255, kr + (wr - kr) * cr / 255)))
                out[di + 1] = UInt8(max(0, min(255, kg + (wg - kg) * cg / 255)))
                out[di + 2] = UInt8(max(0, min(255, kb + (wb - kb) * cb / 255)))
                out[di + 3] = a
                if a > 20 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard let prov = CGDataProvider(data: Data(out) as CFData),
              let full = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                 provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        // Tight crop around Lump's body so he looks big & crisp in the notch/menu bar
        let pad = 2
        let cx = max(0, minX - pad), cy = max(0, minY - pad)
        let cw = min(side - cx, (maxX - minX + 1) + pad * 2)
        let ch = min(side - cy, (maxY - minY + 1) + pad * 2)
        let cropRect = (maxX > minX && maxY > minY) ? CGRect(x: cx, y: cy, width: cw, height: ch) : CGRect(x: 0, y: 0, width: side, height: side)
        let cropped = full.cropping(to: cropRect) ?? full
        let img = NSImage(cgImage: cropped, size: NSSize(width: targetSize, height: targetSize))
        img.isTemplate = false
        return img
    }

    private func loadMenuIcon(size: CGFloat = 20) -> NSImage? {
        if cachedIconHex == currentColourHex, let cached = cachedMenuIcon {
            let copy = cached.copy() as? NSImage ?? cached
            copy.size = NSSize(width: size, height: size)
            return copy
        }
        if let painted = renderLumpIcon(hex: currentColourHex, targetSize: 32) {
            cachedIconHex = currentColourHex
            cachedMenuIcon = painted
            let copy = painted.copy() as? NSImage ?? painted
            copy.size = NSSize(width: size, height: size)
            return copy
        }
        let sym = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Lump")
        sym?.isTemplate = true
        return sym
    }

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "LumpDeskStatusItem"
        statusItem.isVisible = true
        if let btn = statusItem.button {
            if let icon = loadMenuIcon() {
                btn.image = icon
                btn.title = ""
            } else {
                btn.title = "Lump"
            }
            btn.toolTip = "Lump — Click for all actions (⌥ ⌥ to dictate)"
        }
        let barMenu = NSMenu()
        barMenu.delegate = self
        statusItem.menu = barMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildContextMenu().items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !prismVisible {
            togglePrismVisible()
        } else {
            ensureWindowOnScreen()
            window.orderFront(nil)
        }
        return true
    }

    private func updateMenuBarIcon() {
        guard let btn = statusItem?.button else { return }
        if isRecording {
            let img = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Lump Listening")
            img?.isTemplate = false
            btn.image = img
            btn.contentTintColor = .systemRed
            notchIconView?.image = img
            notchIconView?.contentTintColor = .systemRed
        } else if meetingRecorder.isActive {
            let img = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Lump Recording Meeting")
            img?.isTemplate = false
            btn.image = img
            btn.contentTintColor = .systemPurple
            notchIconView?.image = img
            notchIconView?.contentTintColor = .systemPurple
        } else {
            let menuIcon = loadMenuIcon(size: 20)
            let notchIcon = loadMenuIcon(size: 30)
            if let menuIcon = menuIcon {
                btn.image = menuIcon
                btn.title = ""
                notchIconView?.image = notchIcon
            } else {
                btn.image = nil
                btn.title = "Lump"
            }
            btn.contentTintColor = nil
            notchIconView?.contentTintColor = nil
        }
    }

    private func setupNotchWing() {
        notchWindow?.orderOut(nil)
        notchWindow = nil
        notchIconView = nil

        // Find a notched MacBook screen (safeAreaInsets.top > 0)
        guard #available(macOS 12.0, *),
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let rightArea = screen.auxiliaryTopRightArea else { return }

        let h = screen.safeAreaInsets.top
        let w: CGFloat = 40
        let overlap: CGFloat = 12
        let rect = NSRect(x: rightArea.minX - overlap, y: screen.frame.maxY - h, width: w + overlap, height: h)

        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bg = NSView(frame: NSRect(origin: .zero, size: rect.size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.cgColor
        bg.layer?.cornerRadius = 10
        bg.layer?.maskedCorners = [.layerMaxXMinYCorner]

        let iconSide = min(h - 6, 30)
        let iv = NSImageView(frame: NSRect(x: overlap + (w - iconSide) / 2, y: (h - iconSide) / 2, width: iconSide, height: iconSide))
        iv.image = loadMenuIcon(size: iconSide)
        iv.imageScaling = .scaleProportionallyUpOrDown
        bg.addSubview(iv)

        let clicker = DragOverlayView(frame: bg.bounds)
        clicker.onClick = { [weak self] in
            guard let self = self, let view = self.notchWindow?.contentView else { return }
            let m = self.buildContextMenu()
            m.popUp(positioning: nil, at: NSPoint(x: overlap, y: 0), in: view)
        }
        clicker.onRightClick = { [weak self] ev in
            guard let self = self, let view = self.notchWindow?.contentView else { return }
            NSMenu.popUpContextMenu(self.buildContextMenu(), with: ev, for: view)
        }
        bg.addSubview(clicker)

        panel.contentView = bg
        panel.orderFrontRegardless()
        notchWindow = panel
        notchIconView = iv
    }

    @objc func screensChanged() {
        ensureWindowOnScreen()
        setupNotchWing()
    }

    private func ensureWindowOnScreen() {
        let frame = window.frame
        let onAnyScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        if !onAnyScreen {
            let screen = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let origin = NSPoint(x: screen.maxX - frame.width - 28, y: screen.minY + 28)
            window.setFrameOrigin(origin)
        }
    }

    @objc func togglePrismVisible() {
        prismVisible.toggle()
        if prismVisible {
            ensureWindowOnScreen()
            window.orderFront(nil)
        } else {
            window.orderOut(nil)
        }
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
            self.updateMenuBarIcon()
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

    private func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var propSize: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize) == noErr else { return nil }
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var devs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize, &devs) == noErr else { return nil }
        for dev in devs {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfUID: CFString = "" as CFString
            var size = UInt32(MemoryLayout<CFString>.size)
            if AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &size, &cfUID) == noErr,
               (cfUID as String) == uid {
                return dev
            }
        }
        return nil
    }

    private func beginRecording() {
        postSimple("\(VOICE_BASE)/stop_speaking")

        guard let mic = resolveMicrophone() else {
            NSLog("LumpDesk: no audio input device found")
            return
        }
        activeMicName = mic.localizedName
        NSLog("LumpDesk: recording with AVAudioEngine on mic: \(activeMicName)")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Bind the exact selected microphone (Shure or MacBook) to the input AudioUnit
        if var devID = audioDeviceID(forUID: mic.uniqueID), let au = inputNode.audioUnit {
            AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 else {
            NSLog("LumpDesk: invalid input format (sr=\(hwFormat.sampleRate), ch=\(hwFormat.channelCount))")
            return
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lump_voice_\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: tmp, settings: hwFormat.settings)
            audioFileLock.lock()
            self.audioFile = file
            audioFileLock.unlock()

            inputNode.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                self.audioFileLock.lock()
                try? self.audioFile?.write(from: buffer)
                self.audioFileLock.unlock()

                if let chData = buffer.floatChannelData?[0] {
                    let frames = Int(buffer.frameLength)
                    var sum: Float = 0
                    for i in 0..<frames { sum += chData[i] * chData[i] }
                    let rms = sqrt(sum / max(1, Float(frames)))
                    let db = 20.0 * log10(max(rms, 1e-5))
                    let norm = CGFloat(max(0.0, min(1.0, (Double(db) + 55.0) / 55.0)))
                    DispatchQueue.main.async {
                        if self.isRecording {
                            self.window.contentView?.layer?.borderWidth = 1.8 + norm * 3.5
                            self.window.contentView?.layer?.borderColor = NSColor(
                                calibratedRed: 0.95,
                                green: 0.25 + norm * 0.35,
                                blue: 0.28 + norm * 0.25,
                                alpha: 0.55 + norm * 0.45
                            ).cgColor
                        }
                    }
                }
            }

            engine.prepare()
            try engine.start()
            self.audioEngine = engine
            self.recordingURL = tmp
            self.isRecording = true
            self.micButton.isRecording = true
            self.updateBadge()
        } catch {
            NSLog("LumpDesk: AVAudioEngine failed to start: \(error)")
        }
    }

    private func stopAndSendRecording() {
        isRecording = false
        micButton.isRecording = false
        voiceState = "transcribing"
        updateBadge()

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        audioFileLock.lock()
        audioFile = nil
        audioFileLock.unlock()

        guard let outputFileURL = recordingURL else {
            voiceState = "idle"
            updateBadge()
            return
        }
        recordingURL = nil

        guard let data = try? Data(contentsOf: outputFileURL), data.count > 2000 else {
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
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
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

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {}

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

    @objc func openNerveCentre() {
        if let url = URL(string: "http://127.0.0.1:47824/") {
            NSWorkspace.shared.open(url)
        }
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

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Lump Nerve Centre", action: #selector(openNerveCentre), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: isRecording ? "Stop Recording (⌥ ⌥)" : "Dictate into Active App (⌥ ⌥)", action: #selector(toggleDictation), keyEquivalent: "")
        menu.addItem(withTitle: "Ask Lump Agent", action: #selector(toggleRecording), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: meetingRecorder.isActive ? "Stop Meeting Notes & Summarize" : "Start Meeting Notes (Dual-Track)", action: #selector(toggleMeetingRecording), keyEquivalent: "")
        let autoMtg = NSMenuItem(title: "Auto-Record Calendar Meetings", action: #selector(toggleAutoRecordMeetings), keyEquivalent: "")
        autoMtg.state = isAutoRecordEnabled() ? .on : .off
        menu.addItem(autoMtg)
        menu.addItem(withTitle: "Open Lump-PA Folder", action: #selector(openPAFolder), keyEquivalent: "")
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
        let showPrismItem = NSMenuItem(title: prismVisible ? "Hide Floating Prism" : "Show Floating Prism", action: #selector(togglePrismVisible), keyEquivalent: "")
        menu.addItem(showPrismItem)
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
        menu.addItem(withTitle: "Reload Prism", action: #selector(reloadWidget), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LumpDesk", action: #selector(quitApp), keyEquivalent: "q")
        return menu
    }

    func showMenu(_ event: NSEvent) {
        NSMenu.popUpContextMenu(buildContextMenu(), with: event, for: window.contentView!)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
