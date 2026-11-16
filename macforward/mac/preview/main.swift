// MacForward Preview: a menubar app showing what forward.sh is sending.
//
// forward.sh writes the outgoing picture, small, to
// /tmp/macforward.<uid>.lock/preview.jpg (renamed into place, ~15 fps) and
// what's on to .../status (key=value lines). The lock directory exists only
// while forward.sh runs, so no directory means "not running".
//
// Click the menubar icon for a preview popover; "Window" opens a resizable
// one that can float above everything (or launch with --window, e.g.
// open -a "MacForward Preview" --args --window). Right-click the icon for a
// menu; double-click the popover's picture to open the window.

import AppKit

let lockDir = "/tmp/macforward.\(getuid()).lock"
let previewPath = lockDir + "/preview.jpg"
let statusPath = lockDir + "/status"

// The controls work forward.sh's keys: each is appended, one a line, to
// .../requests and forward.sh gets a USR1, which handles it like a keypress.

// MARK: - State read from forward.sh

struct ForwardState: Equatable {
    var running = false
    var video = ""      // live, fallback, clip, clips-only
    var clip = ""
    var mic = ""        // live, clip
    var sync = false
    var host = ""
    var controls = ""   // none, mic, all
    var clips: [String] = []
    var pid: pid_t = 0

    static func read() -> ForwardState {
        var s = ForwardState()
        guard let p = try? String(contentsOfFile: lockDir + "/pid", encoding: .utf8),
              let pid = pid_t(p.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 else { return s }
        s.running = true
        s.pid = pid
        guard let text = try? String(contentsOfFile: statusPath, encoding: .utf8) else { return s }
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let v = String(kv[1])
            switch kv[0] {
            case "video": s.video = v
            case "clip": s.clip = v
            case "mic": s.mic = v
            case "sync": s.sync = v == "1"
            case "host": s.host = v
            case "controls": s.controls = v
            case "clips": s.clips = v.isEmpty ? [] : v.split(separator: "|").map(String.init)
            default: break
            }
        }
        return s
    }

    var badge: (String, NSColor) {
        if !running { return ("NOT RUNNING", .systemGray) }
        switch video {
        case "live": return ("● LIVE", .systemGreen)
        case "clip": return ("▶ CLIP", .systemPurple)
        case "fallback": return ("● FALLBACK", .systemOrange)
        case "clips-only": return ("● CLIPS ONLY", .systemOrange)
        default: return ("● STARTING", .systemGray)
        }
    }

    var detail: String {
        if !running { return "Start forward.sh to see the preview" }
        var parts: [String] = []
        if video != "live" && !clip.isEmpty { parts.append(clip) }
        if video == "live" { parts.append("camera") }
        if !mic.isEmpty { parts.append(mic == "live" ? "🎤 live mic" : "🔊 clip audio") }
        if sync { parts.append("🔗 synced") }
        if !host.isEmpty { parts.append("→ \(host)") }
        return parts.joined(separator: "  ·  ")
    }

    var symbol: String {
        if !running { return "video.slash" }
        switch video {
        case "live": return "video.fill"
        case "clip", "fallback", "clips-only": return "film.fill"
        default: return "video"
        }
    }
}

/// Press one of forward.sh's keys (f, l, m, s, 1-9, q).
func sendKey(_ key: String) {
    let s = Poller.shared.state
    guard s.running, s.pid > 0 else { return }
    let fd = open(lockDir + "/requests", O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { NSSound.beep(); return }
    let line = key + "\n"
    _ = line.withCString { write(fd, $0, strlen($0)) }
    close(fd)
    kill(s.pid, SIGUSR1)
    Poller.shared.poke()
}

// MARK: - Poller: one timer feeds every visible preview

final class Poller {
    static let shared = Poller()
    private var timer: Timer?
    private var lastMod: Date?
    private(set) var image: CGImage?
    private(set) var frameDate: Date?
    private(set) var state = ForwardState()
    private var observers: [ObjectIdentifier: () -> Void] = [:]
    var onStateChange: ((ForwardState) -> Void)?

    func start() {
        tick()
        // Slow while nothing is on screen, just to keep the menubar icon current.
        schedule(interval: 1.0)
    }

    func add(_ o: AnyObject, _ f: @escaping () -> Void) {
        observers[ObjectIdentifier(o)] = f
        schedule(interval: 1.0 / 20)
        tick()
    }

    func remove(_ o: AnyObject) {
        observers.removeValue(forKey: ObjectIdentifier(o))
        if observers.isEmpty { schedule(interval: 1.0) }
    }

    /// Re-read soon after a key is sent, so the controls catch up quickly.
    func poke() {
        for d in [0.1, 0.3, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.tick() }
        }
    }

    private func schedule(interval: TimeInterval) {
        if let t = timer, abs(t.timeInterval - interval) < 0.001 { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let s = ForwardState.read()
        if s != state {
            state = s
            onStateChange?(s)
        }
        if !observers.isEmpty {
            if s.running, let attrs = try? FileManager.default.attributesOfItem(atPath: previewPath),
               let mod = attrs[.modificationDate] as? Date {
                if mod != lastMod,
                   let data = try? Data(contentsOf: URL(fileURLWithPath: previewPath)),
                   let src = CGImageSourceCreateWithData(data as CFData, nil),
                   let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    lastMod = mod
                    image = img
                    frameDate = mod
                }
            } else if !s.running {
                image = nil
                frameDate = nil
                lastMod = nil
            }
        }
        observers.values.forEach { $0() }
    }
}

// MARK: - Preview view (picture + status badge + detail line)

final class PreviewView: NSView {
    private let picture = CALayer()
    private let badge = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: "")
    private let footerHeight: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        picture.contentsGravity = .resizeAspect
        picture.backgroundColor = NSColor.black.cgColor
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(picture)

        badge.font = .boldSystemFont(ofSize: 11)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.alignment = .center
        addSubview(badge)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NSColor(white: 0.85, alpha: 1)
        detail.lineBreakMode = .byTruncatingMiddle
        addSubview(detail)

        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = NSColor(white: 0.6, alpha: 1)
        placeholder.alignment = .center
        addSubview(placeholder)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        picture.frame = CGRect(x: 0, y: footerHeight, width: b.width, height: b.height - footerHeight)
        detail.frame = NSRect(x: 8, y: 3, width: b.width - 16, height: 16)
        placeholder.frame = NSRect(x: 8, y: footerHeight + (b.height - footerHeight) / 2 - 9,
                                   width: b.width - 16, height: 18)
        badge.sizeToFit()
        let bw = badge.frame.width + 12
        badge.frame = NSRect(x: 8, y: b.height - 26, width: bw, height: 18)
    }

    func refresh() {
        let p = Poller.shared
        let s = p.state
        let (text, color) = s.badge
        badge.stringValue = text
        badge.layer?.backgroundColor = color.withAlphaComponent(0.85).cgColor
        detail.stringValue = s.detail
        picture.contents = p.image

        if !s.running {
            placeholder.stringValue = "forward.sh isn't running"
        } else if p.image == nil {
            placeholder.stringValue = s.video.isEmpty ? "Starting…" :
                "No preview (forward.sh started with PREVIEW=0, or an older forward.sh)"
        } else if let d = p.frameDate, Date().timeIntervalSince(d) > 2 {
            placeholder.stringValue = "⚠︎ Picture stalled \(Int(Date().timeIntervalSince(d))) s"
        } else {
            placeholder.stringValue = ""
        }
        placeholder.isHidden = placeholder.stringValue.isEmpty
        if !placeholder.isHidden && p.image != nil {
            // A stall: keep the last frame but dim it under the warning.
            picture.opacity = 0.4
        } else {
            picture.opacity = 1
        }
        needsLayout = true
    }
}

// MARK: - Controls (forward.sh's keys as buttons)

final class ControlsView: NSView {
    static let height: CGFloat = 66
    private let picture = NSSegmentedControl(labels: ["Live camera", "Fallback"],
                                             trackingMode: .selectOne, target: nil, action: nil)
    private let mic = NSSegmentedControl(labels: ["Live mic", "Clip audio"],
                                         trackingMode: .selectOne, target: nil, action: nil)
    private let sync = NSButton(checkboxWithTitle: "Sync mic to picture", target: nil, action: nil)
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    private let clipRow = NSStackView()
    private var clipButtons: [NSButton] = []
    private var clipNames: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        for c in [picture, mic] { c.target = self; c.controlSize = .small; c.font = .systemFont(ofSize: 11) }
        picture.action = #selector(pictureChanged)
        mic.action = #selector(micChanged)
        sync.target = self; sync.action = #selector(syncChanged)
        sync.controlSize = .small; sync.font = .systemFont(ofSize: 11)
        stop.target = self; stop.action = #selector(stopClicked)
        stop.controlSize = .small; stop.bezelStyle = .rounded; stop.font = .systemFont(ofSize: 11)
        stop.toolTip = "Stop forward.sh (the target loses the camera)"

        clipRow.orientation = .horizontal
        clipRow.spacing = 4

        let row1 = NSStackView(views: [label("Picture"), picture, clipRow])
        let row2 = NSStackView(views: [label("Mic"), mic, sync, NSView(), stop])
        for r in [row1, row2] {
            r.orientation = .horizontal; r.spacing = 8; r.alignment = .centerY
            r.setHuggingPriority(.defaultLow, for: .horizontal)
        }
        let col = NSStackView(views: [row1, row2])
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 6
        col.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: leadingAnchor),
            col.trailingAnchor.constraint(equalTo: trailingAnchor),
            col.topAnchor.constraint(equalTo: topAnchor),
            col.bottomAnchor.constraint(equalTo: bottomAnchor),
            row2.trailingAnchor.constraint(equalTo: col.trailingAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = .secondaryLabelColor
        l.widthAnchor.constraint(equalToConstant: 42).isActive = true
        return l
    }

    /// "1-wave.mp4" -> "1 wave"
    private func shortName(_ n: String, _ i: Int) -> String {
        var b = (n as NSString).deletingPathExtension
        if b.hasPrefix("\(i)-") || b.hasPrefix("\(i)_") || b.hasPrefix("\(i) ") { b.removeFirst("\(i)-".count) }
        return b.isEmpty ? "\(i)" : "\(i) \(b)"
    }

    func refresh() {
        let s = Poller.shared.state
        let canVideo = s.running && s.controls == "all"
        let canMic = s.running && (s.controls == "all" || s.controls == "mic")

        if s.clips != clipNames {
            clipNames = s.clips
            clipButtons.forEach { $0.removeFromSuperview() }
            clipButtons = s.clips.enumerated().map { (i, n) in
                let b = NSButton(title: "▶ " + shortName(n, i + 1), target: self, action: #selector(clipClicked(_:)))
                b.tag = i + 1
                b.controlSize = .small; b.bezelStyle = .rounded; b.font = .systemFont(ofSize: 11)
                b.toolTip = "Play \(n) once, then back to the fallback (key \(i + 1))"
                b.lineBreakMode = .byTruncatingTail
                b.widthAnchor.constraint(lessThanOrEqualToConstant: 110).isActive = true
                clipRow.addArrangedSubview(b)
                return b
            }
        }

        picture.isEnabled = canVideo
        picture.setEnabled(s.controls == "all", forSegment: 0)
        picture.selectedSegment = !s.running || s.video.isEmpty ? -1 : (s.video == "live" ? 0 : 1)
        picture.setLabel(s.controls == "mic" ? "Clips only" : "Fallback", forSegment: 1)
        mic.isEnabled = canMic
        mic.selectedSegment = !s.running || s.mic.isEmpty ? -1 : (s.mic == "live" ? 0 : 1)
        sync.isEnabled = canVideo
        sync.state = s.sync ? .on : .off
        let canClips = s.running && s.controls != "none"
        clipButtons.forEach { b in
            b.isEnabled = canClips
            b.state = (s.video == "clip" && s.clip == s.clips[b.tag - 1]) ? .on : .off
        }
        stop.isEnabled = s.running
    }

    @objc private func pictureChanged() {
        sendKey(picture.selectedSegment == 0 ? "l" : "f")
    }

    @objc private func micChanged() {
        let want = mic.selectedSegment == 0 ? "live" : "clip"
        if Poller.shared.state.mic != want { sendKey("m") }
    }

    @objc private func syncChanged() { sendKey("s") }

    @objc private func clipClicked(_ b: NSButton) { sendKey(String(b.tag)) }

    @objc private func stopClicked() {
        let a = NSAlert()
        a.messageText = "Stop forward.sh?"
        a.informativeText = "The target loses the camera and mic until you start forward.sh again."
        a.addButton(withTitle: "Stop")
        a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { sendKey("q") }
    }
}

final class PreviewController: NSViewController {
    let preview = PreviewView(frame: .zero)
    let controls = ControlsView(frame: .zero)
    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 292 + ControlsView.height))
        for sub in [preview, controls] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            preview.topAnchor.constraint(equalTo: v.topAnchor),
            controls.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            controls.topAnchor.constraint(equalTo: preview.bottomAnchor),
            controls.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            controls.heightAnchor.constraint(equalToConstant: ControlsView.height),
        ])
        view = v
    }
    override func viewWillAppear() {
        super.viewWillAppear()
        Poller.shared.add(self) { [weak self] in
            self?.preview.refresh()
            self?.controls.refresh()
        }
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        Poller.shared.remove(self)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private(set) var window: NSWindow?
    private var floatItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let pc = PreviewController()
        popover.contentViewController = pc
        popover.contentSize = NSSize(width: 480, height: 292 + ControlsView.height)
        popover.behavior = .transient
        popover.animates = false

        Poller.shared.onStateChange = { [weak self] s in self?.updateIcon(s) }
        updateIcon(ForwardState())
        Poller.shared.start()
        if CommandLine.arguments.contains("--window") { openWindow() }
    }

    private func updateIcon(_ s: ForwardState) {
        let img = NSImage(systemSymbolName: s.symbol, accessibilityDescription: "MacForward")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.toolTip = s.running ? "MacForward: \(s.badge.0)" : "MacForward: not running"
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if rightClick {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Show Preview", action: #selector(showPopover), keyEquivalent: "")
        m.addItem(withTitle: "Open Window", action: #selector(openWindow), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit MacForward Preview", action: #selector(NSApplication.terminate(_:)),
                  keyEquivalent: "q")
        m.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil   // so a left click shows the popover again
    }

    @objc private func showPopover() {
        guard let b = item.button else { return }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }

    @objc func openWindow() {
        popover.performClose(nil)
        if window == nil {
            let h = 382 + ControlsView.height
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: h),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "MacForward Preview"
            w.contentViewController = PreviewController()
            w.setContentSize(NSSize(width: 640, height: h))
            w.contentMinSize = NSSize(width: 420, height: 160 + ControlsView.height)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.setFrameAutosaveName("MacForwardPreviewWindow")
            if !w.setFrameUsingName("MacForwardPreviewWindow") { w.center() }

            // A pin button in the title bar toggles always-on-top.
            let pin = NSButton(image: NSImage(systemSymbolName: "pin.fill",
                                              accessibilityDescription: "Keep on top")!,
                               target: self, action: #selector(togglePin(_:)))
            pin.bezelStyle = .accessoryBarAction
            pin.isBordered = false
            pin.toolTip = "Keep on top"
            pin.state = .on
            let acc = NSTitlebarAccessoryViewController()
            acc.view = pin
            acc.view.frame = NSRect(x: 0, y: 0, width: 28, height: 22)
            acc.layoutAttribute = .trailing
            w.addTitlebarAccessoryViewController(acc)
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePin(_ b: NSButton) {
        let on = window?.level != .floating
        window?.level = on ? .floating : .normal
        b.image = NSImage(systemSymbolName: on ? "pin.fill" : "pin.slash",
                          accessibilityDescription: "Keep on top")
        b.toolTip = on ? "Keep on top (on)" : "Keep on top (off)"
    }
}

// The popover has an "Open Window" affordance too: double-click the picture.
extension PreviewView {
    override func mouseDown(with e: NSEvent) {
        guard e.clickCount == 2, let d = NSApp.delegate as? AppDelegate else { return }
        if window !== d.window { d.openWindow() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menubar only, no Dock icon
app.run()
