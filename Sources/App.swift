import AppKit
import ServiceManagement
import SwiftUI

@main
struct LocalhostageApp: App {
    @State private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            Panel().environment(store)
        } label: {
            let n = store.visible.count
            Image(nsImage: Self.scrap)
            if n > 0 { Text("\(n)") }
        }
        .menuBarExtraStyle(.window)
    }

    /// Menu bar glyph: a tilted ransom-note scrap with ":" punched out. Template, so it follows the menu bar's tint.
    static let scrap: NSImage = {
        let img = NSImage(size: NSSize(width: 15, height: 16), flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.translateBy(x: rect.midX, y: rect.midY)
            cg.rotate(by: -8 * .pi / 180)
            cg.addPath(CGPath(roundedRect: CGRect(x: -5.5, y: -6.5, width: 11, height: 13), cornerWidth: 1.2, cornerHeight: 1.2, transform: nil))
            cg.fillPath()
            cg.setBlendMode(.destinationOut)
            for y in [1.3, -3.7] { cg.fillEllipse(in: CGRect(x: -1.25, y: y, width: 2.5, height: 2.5)) }
            return true
        }
        img.isTemplate = true
        return img
    }()
}

/// A server we've seen running, kept so it can be started again after it's freed.
struct Recent: Codable, Identifiable, Hashable {
    var id: String { launch.key }
    var launch: Launch
    var project: String
    var folder: String?
    var kind: String
    var command: String
    var port: Int
}

@MainActor @Observable
final class Store {
    var listeners: [Listener] = []
    var recents: [Recent] = Store.loadRecents()
    var dying: Set<pid_t> = []
    var starting: [String: Date] = [:]
    var toast: String?
    var showAll = UserDefaults.standard.bool(forKey: "showAll") {
        didSet { UserDefaults.standard.set(showAll, forKey: "showAll") }
    }
    var sounds = UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sounds, forKey: "sounds") }
    }
    var isOpen = false {
        didSet { if isOpen { Task { await refresh() } } }
    }
    var openAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard openAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                say("Couldn't change login item: \(error.localizedDescription)")
                openAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private let scanner = Scanner()

    var visible: [Listener] { showAll ? listeners : listeners.filter(\.isDev) }
    var freeable: [Listener] { visible.filter { !$0.isProtected } }
    var freed: [Recent] {
        let running = Set(listeners.compactMap { $0.launch?.key })
        return Array(recents.filter { !running.contains($0.id) }.prefix(6))
    }

    init() {
        Task { self.welcomeOnce() }
        // ponytail: fixed polling, 2s open / 5s closed. A libproc scan is ~10ms; move to kqueue if it ever shows in Instruments.
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(isOpen ? 2 : 5))
            }
        }
    }

    func refresh() async {
        let fresh = await scanner.scan()
        if fresh != listeners {
            withAnimation(.spring(duration: 0.4, bounce: 0)) { listeners = fresh }
        }
        remember(fresh)
        for (key, since) in starting {
            let r = recents.first { $0.id == key }
            // up = the same launch is running, or its port is held by something running from its folder
            let up = fresh.contains { l in
                l.launch?.key == key || (r.map { l.ports.contains($0.port) && l.launch?.cwd == $0.launch.cwd } ?? false)
            }
            if up {
                starting[key] = nil
            } else if Date().timeIntervalSince(since) > 25, let r {
                starting[key] = nil
                say("\(r.project) didn't open :\(r.port) in 25s. Right-click it for the log.")
            }
        }
    }

    // MARK: Free

    func free(_ l: Listener) {
        guard !dying.contains(l.pid) else { return }
        dying.insert(l.pid)
        Task {
            await Proc.killTree(l.launcher)
            toFront([l])
            if sounds { NSSound(named: "Pop")?.play() }
            withAnimation(.spring(duration: 0.45, bounce: 0)) {
                listeners.removeAll { $0.launcher == l.launcher }
                dying.remove(l.pid)
            }
            say(Quips.released(l.ports[0]))
            await refresh()
        }
    }

    func freeAll() {
        let targets = freeable
        targets.forEach { dying.insert($0.pid) }
        Task {
            await withTaskGroup(of: Void.self) { g in
                for launcher in Set(targets.map(\.launcher)) { g.addTask { await Proc.killTree(launcher) } }
            }
            toFront(targets)
            if sounds { NSSound(named: "Pop")?.play() }
            withAnimation(.spring(duration: 0.5, bounce: 0)) {
                listeners.removeAll { l in targets.contains { $0.pid == l.pid } }
                dying.subtract(targets.map(\.pid))
            }
            say("Mass release. \(targets.count) ports walk free.")
            await refresh()
        }
    }

    // MARK: Run again

    func run(_ r: Recent) {
        do {
            try r.launch.start(log: Self.logURL(r), header: r.command) { code in
                Task { @MainActor in self.exited(r, code) }
            }
            withAnimation(.snappy) { starting[r.id] = Date() }
            say("Taking :\(r.port) hostage again.")
        } catch {
            say("Couldn't start \(r.project): \(error.localizedDescription)")
        }
    }

    /// A crash before the port comes up is reported now, not after the 25s timeout.
    private func exited(_ r: Recent, _ code: Int32) {
        guard code != 0, starting.removeValue(forKey: r.id) != nil else { return }
        say("\(r.project) exited (code \(code)). Right-click it for the log.")
    }

    func forget(_ r: Recent) {
        withAnimation(.spring(duration: 0.4, bounce: 0)) { recents.removeAll { $0.id == r.id } }
        saveRecents()
    }

    static func logURL(_ r: Recent) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/localhostage/\(r.project)-\(r.port).log")
    }

    private func remember(_ fresh: [Listener]) {
        var changed = false
        for l in fresh where l.canRelaunch {
            let r = Recent(launch: l.launch!, project: l.project, folder: l.folder,
                           kind: l.kind, command: l.command, port: l.ports[0])
            if let i = recents.firstIndex(where: { $0.id == r.id }) {
                if recents[i] != r { recents[i] = r; changed = true }
            } else {
                recents.insert(r, at: 0); changed = true
            }
        }
        if recents.count > 20 { recents = Array(recents.prefix(20)) }
        if changed { saveRecents() }
    }

    /// "Recently stopped" is newest-first.
    private func toFront(_ killed: [Listener]) {
        let keys = Set(killed.compactMap { $0.launch?.key })
        recents = recents.filter { keys.contains($0.id) } + recents.filter { !keys.contains($0.id) }
        saveRecents()
    }

    private static let recentsURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("localhostage")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recents.json")
    }()

    private static func loadRecents() -> [Recent] {
        (try? JSONDecoder().decode([Recent].self, from: Data(contentsOf: recentsURL))) ?? []
    }

    private func saveRecents() {
        let onDisk = recents.map { r in var r = r; r.launch = r.launch.persisted; return r }
        try? JSONEncoder().encode(onDisk).write(to: Self.recentsURL, options: .atomic)
    }

    // MARK: Misc

    private var welcome: NSWindow?

    /// A menu bar app shows nothing on launch, so first-timers think it didn't open. Tell them once where it is.
    private func welcomeOnce() {
        guard !UserDefaults.standard.bool(forKey: "welcomed") else { return }
        UserDefaults.standard.set(true, forKey: "welcomed")
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Welcome { w.close() }.environment(self))
        w.contentView = host
        w.setContentSize(host.fittingSize)
        w.center()
        welcome = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func say(_ text: String) {
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if toast == text { withAnimation(.easeOut(duration: 0.2)) { toast = nil } }
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        say("Copied.")
    }
}

enum Quips {
    static func released(_ port: Int) -> String {
        [":\(port) walked free.", "Negotiations worked. :\(port) is free.", "No ransom paid. :\(port) is free.",
         ":\(port) is going home to its family.", ":\(port) released unharmed."].randomElement()!
    }
    static let none = ["No hostages. Every port is free.", "All quiet. Nobody's holding a port.", "Zero hostages. Suspiciously peaceful."]
}
