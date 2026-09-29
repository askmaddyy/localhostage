// Self-check (binary name must start with "localhostage" so relaunched children stop their launcher search at it, like in the app):
// swiftc Sources/Scanner.swift Tests/main.swift -o /tmp/localhostage-check && /tmp/localhostage-check
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lhg-check-\(getpid())")
try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
try "ref: refs/heads/feature/test\n".write(to: dir.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)

// A server started from a shell, like a terminal would.
let sh = Process()
sh.executableURL = URL(fileURLWithPath: "/bin/sh")
sh.arguments = ["-c", "python3 -m http.server 48999 >/dev/null 2>&1 & wait"]
sh.currentDirectoryURL = dir
try sh.run()

func find(_ port: Int) async -> Listener? {
    for _ in 0..<30 {
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
    let npm = Process()
    npm.executableURL = URL(fileURLWithPath: "/bin/sh")
    npm.arguments = ["-c", "npm run dev >/dev/null 2>&1"]
    npm.currentDirectoryURL = npmDir
    try! npm.run()
    guard let n = await find(48997) else { fatalError("npm server not found") }
    print("  \(n.ports) \(n.kind) `\(n.command)` launcher=\(n.launcher) pid=\(n.pid)")
    precondition(n.ports == [48996, 48997], "ports \(n.ports)")
    precondition(n.kind == "Node", "kind \(n.kind)")
    precondition(n.command == "npm run dev", "command \(n.command)")
    precondition(n.launcher != n.pid, "launcher should be npm, not node")
    await Proc.killTree(n.launcher)
    precondition(!Proc.isAlive(n.pid) && !Proc.isAlive(n.launcher), "npm tree survived")
    try! n.launch!.start(log: dir.appendingPathComponent("npm.log"), header: n.command)
    guard let n2 = await find(48997) else { fatalError("npm relaunch did not listen") }
    precondition(n2.launch?.key == n.launch?.key && n2.command == "npm run dev")
    await Proc.killTree(n2.launcher)

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
sh.terminate()
try? FileManager.default.removeItem(at: dir)
