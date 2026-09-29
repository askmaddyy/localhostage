import AppKit
import Darwin

/// How to start a server again: exactly what was typed (argv of the top process below your shell), where
/// (its cwd), and with what environment. Replayed through `env`, so the command is looked up in the saved PATH
/// the same way your shell did (a venv's `python`, nvm's `node`), not re-guessed.
struct Launch: Codable, Hashable, Sendable {
    let cwd: String
    let args: [String]
    /// Full environment in memory; only `Proc.keptEnv` is ever written to disk (see `persisted`).
    let env: [String: String]

    /// argv[0] is compared by basename: a relaunch gets the resolved path where the original may have had a symlink.
    var key: String {
        ([cwd, ((args.first ?? "") as NSString).lastPathComponent] + args.dropFirst()).joined(separator: "\u{1F}")
    }

    var persisted: Launch { Launch(cwd: cwd, args: args, env: env.filter { Proc.keptEnv.contains($0.key) }) }

    /// argv[0] must resolve to a real executable, as the shell would find it. A rewritten process title
    /// ("next-server (v15)", "postgres: writer") or a login shell ("-zsh") doesn't, so it's never offered for Run.
    var isRunnable: Bool {
        guard let cmd = args.first, !cmd.isEmpty, !cmd.hasPrefix("-"), FileManager.default.fileExists(atPath: cwd) else { return false }
        let fm = FileManager.default
        if cmd.contains("/") {
            return fm.isExecutableFile(atPath: cmd.hasPrefix("/") ? cmd : (cwd as NSString).appendingPathComponent(cmd))
        }
        return (env["PATH"] ?? "").split(separator: ":").contains { fm.isExecutableFile(atPath: "\($0)/\(cmd)") }
    }

    /// Starts it detached, with stdout/stderr going to `log` (truncated each run). `onExit` gets the exit code.
    func start(log: URL, header: String, onExit: @escaping @Sendable (Int32) -> Void = { _ in }) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")  // PATH lookup from `env` below, like the shell
        p.arguments = ["--"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = env.filter { !Proc.isAgentMarker($0.key) }  // you pressed Run: it's yours now, not the agent's
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: Data("$ \(header)\n".utf8))
        let out = try FileHandle(forWritingTo: log)
        out.seekToEndOfFile()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { onExit($0.terminationStatus) }
        try p.run()
    }
}

struct Listener: Hashable, Sendable {
    let pid: pid_t
    let launcher: pid_t
    let ports: [Int]
    let project: String
    let branch: String?
    let folder: String?
    let command: String
    let kind: String
    let origin: String?
    let started: Date
    let memory: UInt64
    let cpu: Double
    let isDev: Bool
    let launch: Launch?
    /// The coding agent that started it (not one you typed in a terminal), e.g. "Claude Code". See `Proc.agent(of:)`.
    let agent: String?

    /// Auto-stop only ever touches servers an agent started, never protected ones. The row's countdown uses this too.
    var autoStoppable: Bool { agent != nil && isDev && !isProtected }

    func dueForAutoStop(after age: TimeInterval, now: Date = Date()) -> Bool {
        autoStoppable && now.timeIntervalSince(started) >= age
    }

    /// Skipped by Kill all; a single Kill asks "Sure?" first. System processes (only listed with "Show system servers") and data stores.
    var isProtected: Bool { !isDev || ["Postgres", "Redis", "MongoDB", "MySQL", "Docker"].contains(kind) }
    var canRelaunch: Bool { isDev && !isProtected && launch != nil }
}

/// Reads listening TCP sockets straight from libproc: no lsof, no subprocesses. A full scan is ~10ms.
actor Scanner {
    private struct Static { let start: Int; let args: [String]; let path: String; let cwd: String?; let origin: String?; let launcher: pid_t; let byApp: Bool; let agent: String?; let launch: Launch? }
    private var cache: [pid_t: Static] = [:]
    private var lastCPU: [pid_t: (ticks: UInt64, at: UInt64)] = [:]

    func scan() -> [Listener] {
        var out: [Listener] = []
        var seen = Set<pid_t>()
        for pid in Proc.userPids() {
            let ports = Proc.listeningPorts(pid)
            guard !ports.isEmpty, let bsd = Proc.bsdInfo(pid) else { continue }
            seen.insert(pid)

            let start = Int(bsd.pbi_start_tvsec)
            if cache[pid]?.start != start {
                let cwd = Proc.cwd(pid)
                let (launcher, byUser) = Proc.launcher(of: pid)
                let (largs, ownEnv) = Proc.argsAndEnv(launcher)
                let env = ownEnv["PATH"] == nil ? Proc.loginEnv.merging(ownEnv) { $1 } : ownEnv
                let exe = Proc.path(launcher)
                let origin = Proc.origin(of: pid)
                // an orphan living inside an app bundle is that app's helper (updaters etc.), not something you ran
                let ours = byUser && !Proc.isGUIApp(launcher) && (origin != nil || !exe.contains(".app/") || exe.contains(".framework/"))
                let launch = (Proc.cwd(launcher) ?? cwd).map { Launch(cwd: $0, args: largs, env: env) }.flatMap { ours && $0.isRunnable ? $0 : nil }
                cache[pid] = Static(start: start, args: Proc.argsAndEnv(pid).args, path: Proc.path(pid), cwd: cwd,
                                    origin: origin, launcher: launcher, byApp: !byUser, agent: Proc.agent(of: pid), launch: launch)
            }
            let s = cache[pid]!
            let name = Proc.name(pid)
            let (mem, ticks) = Proc.usage(pid)
            let now = mach_absolute_time()
            var cpu = 0.0
            if let prev = lastCPU[pid], now > prev.at, ticks >= prev.ticks {
                cpu = Double(ticks - prev.ticks) / Double(now - prev.at) * 100
            }
            lastCPU[pid] = (ticks, now)

            let git = s.cwd.flatMap(Proc.git)
            let kind = Kinds.detect(name: name, args: s.args)
            let folder = git?.root ?? s.cwd.flatMap { $0 == "/" || $0 == NSHomeDirectory() ? nil : $0 }
            out.append(Listener(
                pid: pid, launcher: s.launcher, ports: ports,
                project: folder.map { ($0 as NSString).lastPathComponent } ?? name,
                branch: git?.branch, folder: folder,
                command: Proc.pretty(s.launch?.args ?? s.args, fallback: name), kind: kind, origin: s.origin,
                started: Date(timeIntervalSince1970: TimeInterval(start)),
                memory: mem, cpu: cpu,
                // an unrecognised process a GUI app started is that app's helper (Chrome extension hosts etc.)
                isDev: Kinds.isDev(path: s.path, kind: kind, origin: s.origin) && (s.origin != nil || (!Proc.isApp(pid) && !(s.byApp && kind == "Process"))),
                launch: s.launch, agent: s.agent))
        }
        cache = cache.filter { seen.contains($0.key) }
        lastCPU = lastCPU.filter { seen.contains($0.key) }
        return out.sorted { $0.ports[0] < $1.ports[0] }
    }
}

enum Proc {
    static func userPids() -> [pid_t] { list(UInt32(PROC_UID_ONLY), UInt32(getuid())) }
    static func allPids() -> [pid_t] { list(UInt32(PROC_ALL_PIDS), 0) }

    private static func list(_ type: UInt32, _ info: UInt32) -> [pid_t] {
        let n = proc_listpids(type, info, nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) / MemoryLayout<pid_t>.size + 64)
        let got = proc_listpids(type, info, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(got) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func listeningPorts(_ pid: pid_t) -> [Int] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        var ports = Set<Int>()
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let len = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, len) == len,
                  si.psi.soi_kind == Int32(SOCKINFO_TCP),
                  si.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let len = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, len) == len ? info : nil
    }

    static func parent(_ pid: pid_t) -> pid_t? { bsdInfo(pid).map { pid_t($0.pbi_ppid) } }

    /// Zombies (dead, not yet reaped by their parent - e.g. servers we started with Run) count as gone.
    /// (libproc returns no info at all for a zombie.)
    static func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 && (bsdInfo(pid).map { $0.pbi_status != UInt32(SZOMB) } ?? false) }

    private static func string(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        return string(buf)
    }

    static func path(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        proc_pidpath(pid, &buf, UInt32(buf.count))
        return string(buf)
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let len = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, len) == len else { return nil }
        let s = withUnsafeBytes(of: info.pvi_cdir.vip_path) { string(Array($0.bindMemory(to: CChar.self))) }
        return s.isEmpty ? nil : s
    }

    /// The environment a new terminal gets, resolved once from your login shell (as VS Code does). Used when a
    /// process hid its own: ruby, zsh and others reuse that memory for their process title.
    static let loginEnv: [String: String] = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-ilc", "printf '\\n__lhg__\\n'; /usr/bin/env -0"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let marker = text.range(of: "\n__lhg__\n") else { return [:] }
        var env: [String: String] = [:]
        for kv in text[marker.upperBound...].split(separator: "\0") {
            if let eq = kv.firstIndex(of: "=") { env[String(kv[..<eq])] = String(kv[kv.index(after: eq)...]) }
        }
        return env
    }()

    /// The only env vars written to disk (for Run after the app restarts). Secrets in the environment never are.
    static let keptEnv: Set<String> = [
        "PATH", "HOME", "USER", "SHELL", "LANG", "LC_ALL", "NODE_ENV", "PORT", "HOST", "VIRTUAL_ENV", "CONDA_PREFIX",
        "NVM_DIR", "NVM_BIN", "PYENV_VERSION", "JAVA_HOME", "GOPATH", "GOROOT", "BUN_INSTALL", "PNPM_HOME", "VOLTA_HOME",
        "CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN", "GEM_HOME", "GEM_PATH", "RBENV_VERSION", "TMPDIR",
    ]

    /// KERN_PROCARGS2 layout: [argc:int32][exec path\0][\0 padding][argv...\0][env...\0]
    static func argsAndEnv(_ pid: pid_t) -> (args: [String], env: [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return ([], [:]) }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return ([], [:]) }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        func next() -> String {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: buf[start..<min(i, size)], as: UTF8.self)
        }
        var args: [String] = []
        while args.count < argc, i < size { args.append(next()) }
        // node/npm overwrite argv with a title ("npm run dev", "", "", ...) and zero-pad the rest of the old argv
        // area: skip that padding to reach the environment, then split the title back into words
        if args.last == "" { while i < size, buf[i] == 0 { i += 1 } }
        while args.last == "" { args.removeLast() }
        if args.count == 1, args[0].contains(" "), !args[0].contains("/") { args = args[0].split(separator: " ").map(String.init) }
        var env: [String: String] = [:]
        while i < size {
            let kv = next()
            if kv.isEmpty { break }
            if let eq = kv.firstIndex(of: "=") {
                env[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
            }
        }
        return (args, env)
    }

    /// (phys footprint bytes, cpu time in mach ticks - same unit as mach_absolute_time, so the ratio is unitless)
    static func usage(_ pid: pid_t) -> (UInt64, UInt64) {
        var ru = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return ok == 0 ? (ru.ri_phys_footprint, ru.ri_user_time + ru.ri_system_time) : (0, 0)
    }

    static func git(_ dir: String) -> (root: String, branch: String?)? {
        let fm = FileManager.default
        var url = URL(fileURLWithPath: dir)
        for _ in 0..<12 {
            let dotgit = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotgit.path, isDirectory: &isDir) {
                var head = dotgit.appendingPathComponent("HEAD")
                if !isDir.boolValue, let s = try? String(contentsOf: dotgit, encoding: .utf8), s.hasPrefix("gitdir: ") {
                    // worktree / submodule
                    let dir = s.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
                    head = URL(fileURLWithPath: dir, relativeTo: url).appendingPathComponent("HEAD")
                }
                let h = (try? String(contentsOf: head, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
                let branch = h.map { $0.hasPrefix("ref: refs/heads/") ? String($0.dropFirst(16)) : String($0.prefix(7)) }
                return (url.path, branch)
            }
            if url.path == "/" || url.path == NSHomeDirectory() { break }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "login", "tmux", "screen", "nu", "xonsh", "launchd"]

    /// The top-most ancestor below the shell/terminal/app that started it: `npm run dev` rather than
    /// the `next-server` it spawned. Freeing kills this whole tree; Run replays its argv.
    /// `byUser` is false when a GUI app spawned it (Ollama's helpers, editor language servers): not ours to relaunch.
    static func launcher(of pid: pid_t) -> (pid: pid_t, byUser: Bool) {
        var cur = pid
        for _ in 0..<16 {
            guard let p = parent(cur), p > 1, bsdInfo(p)?.pbi_uid == getuid() else { break }
            // agents and localhostage itself first: we're a (menu bar) app too, and what Run starts is still yours
            if isAgent(p) { break }
            if isGUIApp(p) { return (cur, false) }
            // An interactive/login shell (`-zsh`, no -c, no script) is your terminal: stop. A shell running a script
            // (`./start.sh`) or a `sh -c` from npm/yarn/make is part of the job: keep climbing, unless an agent or
            // app ran it (Claude Code's `zsh -c`, a VS Code task) - then the command it ran is what you typed.
            if shells.contains(name(p).lowercased()) {
                let a = argsAndEnv(p).args
                let interactive = (a.first ?? "").hasPrefix("-") || !a.dropFirst().contains { !$0.hasPrefix("-") }
                guard !interactive, let gp = parent(p), gp > 1, isUs(gp) || (!isAgent(gp) && !isGUIApp(gp)) else { break }
            }
            cur = p
        }
        return (cur, true)
    }

    /// localhostage itself: a server we started with Run must resolve to the same launch it was recorded with.
    private static func isUs(_ p: pid_t) -> Bool { Kinds.originName(name(p).lowercased(), args: []) == "localhostage" }

    private static func isAgent(_ p: pid_t) -> Bool { Kinds.originName(name(p).lowercased(), args: argsAndEnv(p).args) != nil }

    /// A real app (Dock or menu bar). NSRunningApplication exists for every pid; plain processes are `.prohibited`.
    static func isApp(_ p: pid_t) -> Bool { (NSRunningApplication(processIdentifier: p)?.activationPolicy ?? .prohibited) != .prohibited }

    /// An app (Chrome, Ollama.app, menu bar apps) (Chrome, Ollama.app, menu bar apps), or its binary sits in an app bundle.
    /// Bundled runtimes (Xcode's Python.app in a .framework) and Xcode's command-line tools (make, git) don't count.
    static func isGUIApp(_ p: pid_t) -> Bool {
        if isApp(p) { return true }
        let pp = path(p)
        return pp.contains(".app/") && !pp.contains(".framework/") && !pp.contains(".app/Contents/Developer/")
    }

    /// Which coding agent started this server, if one did. You typed it (never auto-stopped) whenever an interactive
    /// shell sits in its ancestry. Otherwise: an agent parent (`zsh -c` from Claude Code), or the agent's own marker
    /// env var, which children inherit and which survives the agent exiting and the server being orphaned.
    static func agent(of pid: pid_t) -> String? {
        if isGUIApp(pid) { return nil }  // an app's own process (Claude Helper, the claude binary itself): never
        var p = parent(pid)
        for _ in 0..<16 {
            guard let cur = p, cur > 1 else { break }
            let n = name(cur).lowercased()
            let args = argsAndEnv(cur).args
            if shells.contains(n) {
                let interactive = (args.first ?? "").hasPrefix("-") || !args.dropFirst().contains { !$0.hasPrefix("-") }
                if interactive { return nil }
            } else if isUs(cur) {
                return nil  // started with Run
            } else if name(cur).hasPrefix("Claude") {
                break  // the Claude desktop app (not the `claude` CLI): its terminal tabs and MCP servers are yours
            } else if let o = Kinds.originName(n, args: args), Kinds.agents.contains(o) {
                return o
            } else if isGUIApp(cur) || Kinds.originName(n, args: args) != nil {
                break  // a terminal or app with no interactive shell below it: fall back to markers
            }
            p = parent(cur)
        }
        return agentMarker(argsAndEnv(pid).env)
    }

    /// Env vars coding agents set on everything they run (verified: Claude Code sets CLAUDECODE=1 and AI_AGENT).
    static func isAgentMarker(_ key: String) -> Bool {
        key == "CLAUDECODE" || key == "AI_AGENT" || key.hasPrefix("CLAUDE_CODE_")
    }

    static func agentMarker(_ env: [String: String]) -> String? {
        if env["CLAUDECODE"] == "1" { return "Claude Code" }
        guard let id = env["AI_AGENT"]?.split(separator: "_").first.map({ $0.lowercased() }), !id.isEmpty else { return nil }
        return ["claude-code": "Claude Code", "codex": "Codex", "cursor": "Cursor", "conductor": "Conductor"][id] ?? id
    }

    /// First recognisable app or agent up the parent chain.
    static func origin(of pid: pid_t) -> String? {
        var p = parent(pid)
        for _ in 0..<16 {
            guard let cur = p, cur > 1 else { return nil }
            if name(cur).hasPrefix("Claude") { return "Claude" }  // desktop app; the agent CLI is lowercase `claude`
            let n = name(cur).lowercased()
            let args = n == "node" ? argsAndEnv(cur).args : []
            if let hit = Kinds.originName(n, args: args) { return hit }
            p = parent(cur)
        }
        return nil
    }

    private static let interpreters: Set<String> = ["node", "python", "python3", "ruby", "bun", "deno", "php", "perl"]

    static func pretty(_ args: [String], fallback: String) -> String {
        guard !args.isEmpty else { return fallback }
        var a = args.map { $0.contains("/") ? ($0 as NSString).lastPathComponent : $0 }
        // `node /opt/homebrew/bin/npm run dev` -> `npm run dev`
        if a.count > 1, interpreters.contains(a[0].lowercased()), args[1].contains("/"), !args[1].hasPrefix("-") { a.removeFirst() }
        return a.prefix(12).joined(separator: " ")
    }

    // ponytail: kills the launcher's whole tree, so a `concurrently` running two servers loses both. Fine for dev.
    static func killTree(_ root: pid_t) async {
        var parent: [pid_t: pid_t] = [:]
        for p in allPids() { if let pp = self.parent(p) { parent[p] = pp } }
        var targets: [pid_t] = [root]
        var frontier = [root]
        while let p = frontier.popLast() {
            let kids = parent.filter { $0.value == p }.map(\.key)
            targets += kids; frontier += kids
        }
        for p in targets { kill(p, SIGTERM) }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if !targets.contains(where: isAlive) { return }
        }
        for p in targets where isAlive(p) { kill(p, SIGKILL) }
        // SIGKILL is async too: wait for the exit so the next scan sees the port free
        for _ in 0..<10 where targets.contains(where: isAlive) { try? await Task.sleep(for: .milliseconds(50)) }
    }
}

enum Kinds {
    private static let origins: [(String, String)] = [
        ("claude", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor"), ("code helper", "VS Code"),
        ("conductor", "Conductor"), ("zed", "Zed"), ("ghostty", "Ghostty"), ("iterm", "iTerm"), ("warp", "Warp"),
        ("terminal", "Terminal"), ("wezterm", "WezTerm"), ("alacritty", "Alacritty"), ("kitty", "kitty"),
        ("localhostage", "localhostage"),
    ]

    /// Origins that are coding agents (the rest are terminals and editors you type into).
    static let agents: Set<String> = ["Claude Code", "Codex", "Conductor"]

    static func originName(_ lowerName: String, args: [String]) -> String? {
        let names = [lowerName] + args.prefix(2).map { ($0 as NSString).lastPathComponent.lowercased() }
        return origins.first { o in names.contains { $0.hasPrefix(o.0) } }?.1
    }

    // Order matters: frameworks before runtimes. Padded keys match whole words.
    private static let table: [(String, [String])] = [
        ("Vite", ["vite"]), ("Next.js", ["next-server", " next "]), ("Nuxt", ["nuxt"]),
        ("Astro", [" astro "]), ("Remix", ["remix"]), ("SvelteKit", ["svelte-kit", "sveltekit"]),
        ("Storybook", ["storybook"]), ("Expo", [" expo ", "metro"]), ("Webpack", ["webpack"]),
        ("Jupyter", ["jupyter"]), ("Streamlit", ["streamlit"]), ("Uvicorn", ["uvicorn", "fastapi"]),
        ("Django", ["manage.py runserver", "django"]), ("Flask", [" flask "]), ("Gunicorn", ["gunicorn"]),
        ("Rails", [" rails ", "puma"]), ("Hugo", [" hugo "]), ("Postgres", ["postgres"]), ("Redis", ["redis-server"]),
        ("MongoDB", ["mongod "]), ("MySQL", ["mysqld"]), ("Ollama", ["ollama"]),
        ("Docker", ["com.docker", " docker", "orbstack", "colima"]),
        ("Bun", [" bun "]), ("Deno", [" deno "]), ("Python", [" python"]), ("Node", [" node "]), ("Ruby", [" ruby"]),
        ("Java", [" java "]), ("PHP", [" php"]),
    ]

    static func detect(name: String, args: [String]) -> String {
        let hay = " " + ([name] + args.prefix(6).map { ($0 as NSString).lastPathComponent }).joined(separator: " ").lowercased() + " "
        return table.first { $0.1.contains { hay.contains($0) } }?.0 ?? "Process"
    }

    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"]

    /// Hides OS daemons and GUI apps' helper servers (AirPlay, Spotify, Figma...). Anything started
    /// from a terminal/agent, or recognised as a runtime (orphaned `node`, Xcode's Python.app), counts.
    static func isDev(path: String, kind: String, origin: String?) -> Bool {
        // /System also holds runtimes (macOS's ruby, perl): a server you started from a terminal is yours
        if systemPrefixes.contains(where: path.hasPrefix) { return origin != nil }
        return origin != nil || kind != "Process" || !path.contains(".app/Contents/")
    }
}
