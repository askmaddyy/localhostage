import AppKit
import SwiftUI

// Springs: critically damped by default; a little bounce only on the liquid-glass morphs.
private let settle = Animation.spring(duration: 0.4, bounce: 0)
private let droplet = Animation.spring(duration: 0.38, bounce: 0.22)

struct Panel: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private enum Entry: Identifiable {
        case live(Listener, String), empty, header, recent(Recent)
        var id: String {
            switch self {
            case .live(_, let id): id
            case .empty: "empty"
            case .header: "header"
            case .recent(let r): r.id
            }
        }
    }

    /// Live rows are keyed by their launch command, so a freed server keeps its identity
    /// and glides down into "Recently freed" (and back up when it's run again).
    private var entries: [Entry] {
        var out: [Entry] = []
        var used = Set<String>()
        for l in store.visible {
            var id = l.canRelaunch ? l.launch!.key : "pid-\(l.pid)"
            if used.contains(id) { id += "-\(l.pid)" }
            used.insert(id)
            out.append(.live(l, id))
        }
        if out.isEmpty { out.append(.empty) }
        let freed = store.freed.filter { !used.contains($0.id) }
        if !freed.isEmpty { out.append(.header); out += freed.map(Entry.recent) }
        return out
    }

    var body: some View {
        let items = entries
        VStack(spacing: 0) {
            Header()
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                        Group {
                            switch e {
                            case .live(let l, _): LiveRow(l: l)
                            case .empty: EmptyState()
                            case .header: SectionHeader(title: "Recently stopped")
                            case .recent(let r): RecentRow(r: r)
                            }
                        }
                        .opacity(revealed || reduceMotion ? 1 : 0)
                        .offset(y: revealed || reduceMotion ? 0 : 6)
                        .animation(settle.delay(Double(min(i, 10)) * 0.028), value: revealed)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            .frame(height: min(estimatedHeight(items), 520))
        }
        .frame(width: 380)
        .overlay(alignment: .bottom) { Toast() }
        .onAppear { store.isOpen = true; revealed = true }
        .onDisappear { store.isOpen = false; revealed = false }
    }

    private func estimatedHeight(_ items: [Entry]) -> CGFloat {
        items.reduce(12) { h, e in
            switch e {
            case .live: h + 66
            case .empty: h + 150
            case .header: h + 30
            case .recent: h + 50
            }
        }
    }
}

// MARK: - Header

private struct Header: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        let count = store.visible.count
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                (Text("local").foregroundStyle(.secondary) + Text("hostage").foregroundStyle(.primary))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .tracking(-0.4)
                Text(subtitle(count))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(count)))
                    .animation(settle, value: count)
            }
            Spacer()
            if store.freeable.count > 1 {
                Button { store.freeAll() } label: {
                    Text("Kill all")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 11).frame(height: 28)
                }
                .buttonStyle(Press())
                .glass(.red.opacity(0.55), interactive: true, in: Capsule())
                .foregroundStyle(.white)
                .help("Stop every dev server (skips system processes, databases and Docker)")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Menu {
                Toggle("Show system servers", isOn: $store.showAll.animation(settle))
                Picker("Auto-stop agent servers", selection: $store.autoStopHours) {
                    Text("Off").tag(0.0)
                    ForEach([1.0, 4.0, 12.0, 24.0], id: \.self) { h in Text("After \(Int(h)) hour\(h == 1 ? "" : "s")").tag(h) }
                }
                Toggle("Sounds", isOn: $store.sounds)
                Toggle("Open at login", isOn: $store.openAtLogin)
                Divider()
                Button("Quit localhostage") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).contentShape(Circle())
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
            .glass(interactive: true, in: Circle())
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .animation(droplet, value: store.freeable.count > 1)
    }

    private func subtitle(_ n: Int) -> String {
        switch n {
        case 0: "Every port is free"
        case 1: "1 port held hostage"
        default: "\(n) ports held hostage"
        }
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
    }
}

// MARK: - Live row

private struct LiveRow: View {
    @Environment(Store.self) private var store
    let l: Listener
    @State private var hover = false
    @State private var armed = false
    @Namespace private var ns

    var body: some View {
        let dying = store.dying.contains(l.pid)
        HStack(spacing: 11) {
            KindIcon(kind: l.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(l.project).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let b = l.branch { BranchChip(name: b) }
                }
                Text(l.command)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(meta)
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)

            GlassGroup {
                HStack(spacing: 6) {
                    Text(verbatim: ":\(l.ports[0])")
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        .fixedSize()
                        .padding(.horizontal, 10).frame(height: 28)
                        .glass(in: Capsule())
                        .glassID("port", ns)
                    if hover && !dying {
                        Button { NSWorkspace.shared.open(URL(string: "http://localhost:\(l.ports[0])")!) } label: {
                            Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28)
                        }
                        .buttonStyle(Press())
                        .glass(interactive: true, in: Circle())
                        .glassID("open", ns)
                        .help("Open localhost:\(l.ports[0])")
                        .accessibilityLabel("Open in browser")
                    }
                    if !dying {
                        Button(action: tapKill) {
                            Text(armed ? "Sure?" : "Kill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .fixedSize()
                                .contentTransition(.interpolate)
                                .padding(.horizontal, 11).frame(height: 28)
                        }
                        .buttonStyle(Press())
                        .foregroundStyle(hover || armed ? .white : Color.red)
                        .glass(hover || armed ? .red.opacity(armed ? 0.95 : 0.75) : .red.opacity(0.12), interactive: true, in: Capsule())
                        .glassID("kill", ns)
                        .help(l.isProtected ? "\(l.isDev ? l.kind : "System process") - click twice to stop it" : "Stop this server and free :\(l.ports[0])")
                        .accessibilityLabel("Kill port \(l.ports[0])")
                    } else {
                        ProgressView().controlSize(.small).frame(width: 40, height: 28).glassID("kill", ns)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(hover ? 0.055 : 0)))
        .opacity(dying ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(droplet) { hover = h } }
        .contextMenu {
            Button("Open in Browser") { NSWorkspace.shared.open(URL(string: "http://localhost:\(l.ports[0])")!) }
            if let f = l.folder { Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: f) } }
            Divider()
            Button("Copy URL") { store.copy("http://localhost:\(l.ports[0])") }
            Button("Copy Command") { store.copy(l.launch.map { $0.args.joined(separator: " ") } ?? l.command) }
            Button("Copy PID") { store.copy("\(l.pid)") }
        }
    }

    private var meta: String {
        var parts = [uptime(l.started)]
        // right after uptime so it's never truncated off the end of the line
        if l.autoStoppable, store.autoStopHours > 0 {
            let left = store.autoStopHours * 3600 - Date().timeIntervalSince(l.started)
            parts.append(left > 60 ? "auto-stops in \(uptime(Date().addingTimeInterval(-left)))" : "auto-stopping")
        }
        parts.append(l.memory.formatted(.byteCount(style: .memory)))
        if l.cpu >= 1 { parts.append("\(Int(l.cpu))% CPU") }
        if l.ports.count > 1 { parts.append("+" + l.ports.dropFirst().map(String.init).joined(separator: ", ")) }
        if let o = l.agent ?? l.origin { parts.append("via \(o)") }
        return parts.joined(separator: "  ·  ")
    }

    private func tapKill() {
        if l.isProtected && !armed {
            withAnimation(droplet) { armed = true }
            Task { try? await Task.sleep(for: .seconds(3)); withAnimation(droplet) { armed = false } }
            return
        }
        armed = false
        store.free(l)
    }
}

// MARK: - Recent row

private struct RecentRow: View {
    @Environment(Store.self) private var store
    let r: Recent
    @State private var hover = false

    var body: some View {
        let starting = store.starting[r.id] != nil
        HStack(spacing: 11) {
            KindIcon(kind: r.kind, muted: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.project).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    Text(verbatim: ":\(r.port)").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                }
                Text(r.command)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button { store.run(r) } label: {
                HStack(spacing: 5) {
                    if starting {
                        ProgressView().controlSize(.mini)
                        Text("Starting")
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                        Text("Run")
                    }
                }
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 11).frame(height: 28)
            }
            .buttonStyle(Press())
            .disabled(starting)
            .glass(hover ? .green.opacity(0.35) : nil, interactive: true, in: Capsule())
            .help("Start `\(r.command)` in \(r.launch.cwd)")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(hover ? 0.045 : 0)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.snappy(duration: 0.2)) { hover = h } }
        .contextMenu {
            Button("Open Log") { NSWorkspace.shared.open(Store.logURL(r)) }
            if let f = r.folder { Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: f) } }
            Button("Copy Command") { store.copy(r.launch.args.joined(separator: " ")) }
            Divider()
            Button("Forget") { store.forget(r) }
        }
    }
}

// MARK: - Pieces

private struct EmptyState: View {
    @State private var line = Quips.none.randomElement()!
    @State private var bounce = 0
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: bounce)
                .frame(width: 54, height: 54)
                .glass(.green.opacity(0.18), in: Circle())
            Text(line).font(.system(size: 13, weight: .semibold))
            Text("Start a dev server and it shows up here.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
        .onAppear { line = Quips.none.randomElement()!; bounce += 1 }
    }
}

private struct BranchChip: View {
    let name: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 8, weight: .bold))
            Text(name).font(.system(size: 10, weight: .medium, design: .monospaced)).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.primary.opacity(0.07), in: Capsule())
        .foregroundStyle(.secondary)
    }
}

private struct KindIcon: View {
    let kind: String
    var muted = false
    var body: some View {
        let tint = muted ? Color.secondary : Kind.color(kind)
        Image(systemName: Kind.symbol(kind))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(muted ? 0.1 : 0.16), in: Circle())
            .help(kind)
    }
}

private struct Toast: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if let t = store.toast {
                Text(t)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 14).frame(height: 32)
                    .glass(in: Capsule())
                    .padding(.bottom, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .id(t)
            }
        }
    }
}

struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: configuration.isPressed)
    }
}

// MARK: - Liquid Glass with a pre-Tahoe fallback

private struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: 3) { content } } else { content }
    }
}

extension View {
    @ViewBuilder
    func glass(_ tint: Color? = nil, interactive: Bool = false, in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(tint ?? .clear, in: shape).background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func glassID(_ id: String, _ ns: Namespace.ID) -> some View {
        if #available(macOS 26, *) { glassEffectID(id, in: ns) } else { self }
    }
}

enum Kind {
    static func color(_ k: String) -> Color {
        switch k {
        case "Vite": .purple
        case "Next.js", "Process", "Ollama": .gray
        case "Nuxt", "Node", "Django": .green
        case "Astro", "Remix", "Storybook", "Rails", "Redis", "Ruby", "Java": .pink
        case "SvelteKit", "Jupyter", "Streamlit", "Hugo", "Bun": .orange
        case "Expo", "Webpack", "Docker", "Postgres", "Deno", "PHP": .blue
        case "Python", "Uvicorn", "Flask", "Gunicorn", "MySQL": .yellow
        case "MongoDB": .mint
        default: .teal
        }
    }

    static func symbol(_ k: String) -> String {
        switch k {
        case "Vite": "bolt.fill"
        case "Next.js", "Nuxt", "Astro", "Remix", "SvelteKit", "Hugo": "globe"
        case "Storybook": "book.fill"
        case "Expo": "iphone"
        case "Jupyter": "book.pages.fill"
        case "Postgres", "Redis", "MongoDB", "MySQL": "cylinder.split.1x2.fill"
        case "Docker": "shippingbox.fill"
        case "Ollama": "brain"
        case "Python", "Uvicorn", "Flask", "Gunicorn", "Django", "Streamlit": "chevron.left.forwardslash.chevron.right"
        default: "terminal.fill"
        }
    }
}

private func uptime(_ since: Date) -> String {
    let s = Int(Date().timeIntervalSince(since))
    switch s {
    case ..<60: return "\(s)s"
    case ..<3600: return "\(s / 60)m"
    case ..<86400: return "\(s / 3600)h \(s % 3600 / 60)m"
    default: return "\(s / 86400)d"
    }
}

struct Welcome: View {
    @Environment(Store.self) private var store
    let done: () -> Void
    @State private var shown = false

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .scaleEffect(shown ? 1 : 0.8).opacity(shown ? 1 : 0)
            Text("localhostage lives in your menu bar")
                .font(.system(size: 17, weight: .bold, design: .rounded))
            Text("Click \(Image(nsImage: LocalhostageApp.scrap)) at the top of your screen to see every dev server holding a port.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Kill frees the port. Run starts it again.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
            Text("If macOS asks about your Desktop or Documents folder, that's only to show git branch names. Saying no is fine.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Open at login", isOn: Bindable(store).openAtLogin)
                .toggleStyle(.switch).controlSize(.small).padding(.top, 4)
            Button("Got it", action: done)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .multilineTextAlignment(.center)
        .padding(28).frame(width: 420)
        .onAppear { withAnimation(.spring(duration: 0.5, bounce: 0.2)) { shown = true } }
    }
}
