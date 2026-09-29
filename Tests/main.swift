// Self-check (binary name must start with "localhostage" so relaunched children stop their launcher search at it, like in the app):
// swiftc Sources/Scanner.swift Tests/main.swift -o /tmp/localhostage-check && /tmp/localhostage-check
import Foundation

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
    precondition(kill(l.pid, 0) != 0, "process alive")
    let after = await Scanner().scan()
    precondition(!after.contains { $0.ports.contains(48999) }, "still listening")

    // Run again from the captured launch
    let log = dir.appendingPathComponent("run.log")
    try! l.launch!.start(log: log, header: l.command)
    guard let again = await find(48999) else { fatalError("relaunch did not listen") }
    precondition(again.launch?.key == l.launch?.key, "relaunch key changed")
    await Proc.killTree(again.launcher)
    precondition(kill(again.pid, 0) != 0)
    print("PASS")
    sem.signal()
}
sem.wait()
sh.terminate()
try? FileManager.default.removeItem(at: dir)
