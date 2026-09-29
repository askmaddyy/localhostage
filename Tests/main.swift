// Self-check (binary name must start with "localhostage" so relaunched children stop their launcher search at it, like in the app):
// swiftc Sources/Scanner.swift Tests/main.swift -o /tmp/localhostage-check && /tmp/localhostage-check
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lhg-check-\(getpid())")
try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
try "ref: refs/heads/feature/test\n".write(to: dir.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)

// A server typed into a terminal (an interactive zsh on a pty)
let server = typeInTerminal("python3 -m http.server 48999", in: dir)

/// Types `cmd` into an interactive zsh on a pseudo-terminal, the way a real terminal runs what you type.
/// With `agent: true`, a process named like Claude Code runs it as `zsh -c "<cmd>"` instead, as agents do.
func typeInTerminal(_ cmd: String, in dir: URL, agent: Bool = false) -> Process {
    let term = Process()
    if agent {
        // a real binary named like Claude Code that runs `zsh -c <cmd>` and waits, as agents do
        let sim = dir.appendingPathComponent("claude-sim")
        if !FileManager.default.fileExists(atPath: sim.path) {
            try! """
            #include <unistd.h>
            #include <sys/wait.h>
            int main(int c, char **v) { pid_t p = fork(); if (!p) { execl("/bin/zsh", "zsh", "-f", "-c", v[1], (char *)0); _exit(127); } int s; waitpid(p, &s, 0); return 0; }
            """
                .write(to: dir.appendingPathComponent("sim.c"), atomically: true, encoding: .utf8)
            shell("cc -o claude-sim sim.c", in: dir)
        }
        term.executableURL = sim
        term.arguments = [cmd]
    } else {
        term.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        term.arguments = ["-q", "/dev/null", "/bin/zsh", "-f", "-i"]
    }
    term.currentDirectoryURL = dir
    let input = Pipe()
    term.standardInput = input
    term.standardOutput = FileHandle.nullDevice
    try! term.run()
    input.fileHandleForWriting.write(Data("\(cmd)\n".utf8))
    return term
}

func shell(_ cmd: String, in dir: URL) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    p.currentDirectoryURL = dir
    try! p.run(); p.waitUntilExit()
    precondition(p.terminationStatus == 0, "setup failed: \(cmd)")
}

/// Types `typed` into an interactive zsh on a pty in `dir`, like a terminal. Checks the app records exactly that
/// command, Kill takes the whole job down, and Run (the app's own code path) brings the port back.
func roundTrip(_ name: String, dir: URL, typed: String, port: Int, expect: String?, tries: Int = 30, agent: Bool = false) async {
    let term = typeInTerminal(typed, in: dir, agent: agent)
    guard let l = await find(port, tries: tries) else { fatalError("\(name): never listened") }
    precondition(expect == nil || l.command == expect, "\(name): recorded `\(l.command)`")
    guard let launch = l.launch else { fatalError("\(name): not offered for Run") }
    await Proc.killTree(l.launcher)
    precondition(!Proc.isAlive(l.pid) && !Proc.isAlive(l.launcher), "\(name): survived Kill")
    let gone = await Scanner().scan()
    precondition(!gone.contains { $0.ports.contains(port) }, "\(name): port still held")
    let log = dir.appendingPathComponent("\(name).log")
    // replay with only what's saved to disk: Run must also work after the app restarts
    try! launch.persisted.start(log: log, header: l.command)
    guard let again = await find(port, tries: tries) else {
        fatalError("\(name): Run didn't bring it back:\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? ""))
    }
    precondition(again.launch?.key == launch.key, "\(name): relaunch identity changed")
    await Proc.killTree(again.launcher)
    term.terminate()
    print("  ok  \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) `\(l.command)`")
}

func find(_ port: Int, tries: Int = 30) async -> Listener? {
    for _ in 0..<tries {
        if let l = await Scanner().scan().first(where: { $0.ports.contains(port) }) { return l }
        try? await Task.sleep(for: .milliseconds(200))
    }
    return nil
}

let sem = DispatchSemaphore(value: 0)
Task {
    let t0 = Date()
    let all = await Scanner().scan()
    print("scan took \(Int(Date().timeIntervalSince(t0) * 1000))ms, \(all.count) listeners")
    // macOS's own listeners (AirPlay receiver in ControlCenter) must be protected from Kill all
    if let cc = all.first(where: { $0.ports.contains(7000) }) { precondition(!cc.isDev && cc.isProtected, "system process not protected") }
    if let ol = all.first(where: { $0.ports.contains(11434) }) { precondition(!ol.isProtected, "ollama should be a normal server") }
    guard let l = await find(48999) else { fatalError("server not found") }
    print("  \(l.ports) \(l.kind) \(l.project) [\(l.branch ?? "-")] `\(l.command)` launcher=\(l.launcher) pid=\(l.pid)")
    precondition(l.kind == "Python", "kind \(l.kind)")
    precondition(l.project == dir.lastPathComponent, "project \(l.project)")
    precondition(l.branch == "feature/test", "branch \(String(describing: l.branch))")
    precondition(l.isDev && l.canRelaunch)
    precondition(l.launcher == l.pid, "launcher should stop at the shell")
    precondition(l.command.lowercased().hasPrefix("python") && l.command.hasSuffix("-m http.server 48999"), "command \(l.command)")

    // Free
    await Proc.killTree(l.launcher)
    precondition(!Proc.isAlive(l.pid), "process alive")
    let after = await Scanner().scan()
    precondition(!after.contains { $0.ports.contains(48999) }, "still listening")

    // Run again from the captured launch
    let log = dir.appendingPathComponent("run.log")
    try! l.launch!.start(log: log, header: l.command)
    guard let again = await find(48999) else { fatalError("relaunch did not listen") }
    precondition(again.launch?.key == l.launch?.key, "relaunch key changed")
    await Proc.killTree(again.launcher)
    precondition(!Proc.isAlive(again.pid))

    // npm wrapper around a node server on two ports: launcher is `npm run dev`, Kill takes npm too, Run replays npm
    let npmDir = dir.appendingPathComponent("npmapp")
    try! FileManager.default.createDirectory(at: npmDir, withIntermediateDirectories: true)
    try! #"{"name":"npmapp","scripts":{"dev":"node server.js"}}"#.write(to: npmDir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try! "const h=require('http');h.createServer((q,r)=>r.end('ok')).listen(48997);h.createServer().listen(48996);".write(to: npmDir.appendingPathComponent("server.js"), atomically: true, encoding: .utf8)
    // Real toolchains, typed into an interactive shell on a pty exactly like a terminal. Each must round-trip:
    // the app sees the typed command, Kill frees the port, Run brings it back. No guessing allowed.
    let rust = dir.appendingPathComponent("rustapp")
    try! FileManager.default.createDirectory(at: rust.appendingPathComponent("src"), withIntermediateDirectories: true)
    try! "[package]\nname = \"rustapp\"\nversion = \"0.1.0\"\nedition = \"2021\"\n".write(to: rust.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
    try! "fn main() { let l = std::net::TcpListener::bind(\"127.0.0.1:48974\").unwrap(); for s in l.incoming() { drop(s); } }".write(to: rust.appendingPathComponent("src/main.rs"), atomically: true, encoding: .utf8)
    shell("cargo build -q", in: rust)  // warm build so `cargo run` starts fast

    let envapp = dir.appendingPathComponent("envapp")
    try! FileManager.default.createDirectory(at: envapp, withIntermediateDirectories: true)
    try! "require('http').createServer((q,r)=>r.end('ok')).listen(+process.env.PORT)".write(to: envapp.appendingPathComponent("server.js"), atomically: true, encoding: .utf8)

    let venv = dir.appendingPathComponent("venvapp")
    try! FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)
    try! "import sys, http.server\nassert sys.prefix != sys.base_prefix, 'not in venv'\nhttp.server.test(HandlerClass=http.server.SimpleHTTPRequestHandler, port=48978)".write(to: venv.appendingPathComponent("server.py"), atomically: true, encoding: .utf8)
    shell("uv venv -q .venv", in: venv)

    let scripted = dir.appendingPathComponent("scriptapp")
    try! FileManager.default.createDirectory(at: scripted, withIntermediateDirectories: true)
    try! "#!/bin/bash\necho starting\npython3 -m http.server 48975\n".write(to: scripted.appendingPathComponent("start.sh"), atomically: true, encoding: .utf8)
    shell("chmod +x start.sh", in: scripted)
    try! "dev:\n\tpython3 -m http.server 48976\n".write(to: scripted.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)

    await roundTrip("npm", dir: npmDir, typed: "npm run dev", port: 48997, expect: "npm run dev")
    await roundTrip("env var", dir: envapp, typed: "PORT=48980 node server.js", port: 48980, expect: "node server.js")
    await roundTrip("bun", dir: npmDir, typed: "bun server.js", port: 48997, expect: "bun server.js")
    await roundTrip("venv", dir: venv, typed: "source .venv/bin/activate && python server.py", port: 48978, expect: "python server.py")
    await roundTrip("uv run", dir: venv, typed: "uv run --no-project python -m http.server 48977", port: 48977, expect: nil)
    await roundTrip("make", dir: scripted, typed: "make dev", port: 48976, expect: "make dev")
    await roundTrip("script", dir: scripted, typed: "./start.sh", port: 48975, expect: "bash start.sh")
    // `cargo run` execs the built binary (it's gone from the tree), so the binary itself is what's replayed
    await roundTrip("cargo", dir: rust, typed: "cargo run -q", port: 48974, expect: "rustapp", tries: 100)
    await roundTrip("agent", dir: npmDir, typed: "npm run dev", port: 48997, expect: "npm run dev", agent: true)
    await roundTrip("ruby", dir: scripted, typed: "ruby -run -e httpd . -p 48973", port: 48973, expect: "ruby -run -e httpd . -p 48973")

    // a Run that dies immediately reports its exit code right away
    let exitCode = await withCheckedContinuation { c in
        try! Launch(cwd: "/", args: ["false"], env: ["PATH": "/usr/bin"])
            .start(log: dir.appendingPathComponent("false.log"), header: "false") { c.resume(returning: $0) }
    }
    precondition(exitCode == 1, "exit code \(exitCode)")

    // orphan: the shell that started it is gone, it must still show and die
    let orphanShell = Process()
    orphanShell.executableURL = URL(fileURLWithPath: "/bin/sh")
    orphanShell.arguments = ["-c", "python3 -m http.server 48995 >/dev/null 2>&1 &"]
    try! orphanShell.run(); orphanShell.waitUntilExit()
    guard let o = await find(48995) else { fatalError("orphan not found") }
    precondition(o.isDev && Proc.parent(o.pid) == 1, "orphan should be dev and reparented to launchd")
    await Proc.killTree(o.launcher)
    precondition(!Proc.isAlive(o.pid))

    // stubborn: ignores SIGTERM, must be SIGKILLed after the grace period
    let stubborn = Process()
    stubborn.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    stubborn.arguments = ["python3", "-c", "import signal,socket,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);s=socket.socket();s.bind(('',48994));s.listen();time.sleep(600)"]
    try! stubborn.run()
    guard let st = await find(48994) else { fatalError("stubborn not found") }
    let k0 = Date()
    await Proc.killTree(st.launcher)
    precondition(!Proc.isAlive(st.pid), "stubborn survived SIGKILL")
    print("  stubborn server killed after \(String(format: "%.1f", Date().timeIntervalSince(k0)))s")

    // scale: 40 extra listeners
    var crowd: [Process] = []
    for i in 0..<40 {
        let c = Process()
        c.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        c.arguments = ["python3", "-c", "import socket,time;s=socket.socket();s.bind(('',\(48900 + i)));s.listen();time.sleep(600)"]
        try! c.run(); crowd.append(c)
    }
    _ = await find(48939)
    let scanner = Scanner()
    _ = await scanner.scan()  // warm cache, as the app is after the first tick
    let t1 = Date()
    let big = await scanner.scan()
    let ms = Date().timeIntervalSince(t1) * 1000
    print("  steady-state scan with \(big.count) listeners: \(Int(ms))ms")
    precondition(big.filter { (48900..<48940).contains($0.ports[0]) }.count == 40)
    precondition(ms < 100, "scan too slow")
    crowd.forEach { $0.terminate() }

    print("PASS")
    sem.signal()
}
sem.wait()
server.terminate()
try? FileManager.default.removeItem(at: dir)
