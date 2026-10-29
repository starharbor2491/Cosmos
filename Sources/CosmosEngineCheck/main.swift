// Cosmos Engine Check: Chromium started as Cosmos.app starts it, from inside an app bundle with Cosmos's helper apps,
// for the tests that need a process of their own. Chromium's sandbox lets a helper read only the app the browser process
// is, so it cannot be checked in a test runner; and Chromium stops only once in a process, so quitting cannot either.
//
// Usage: CosmosEngineCheck <data folder> <address> <seconds>
// Shows <address> for <seconds> in a window that is never on screen, prints a line for each of Chromium's processes
// ("renderer sandboxed", "utility network.mojom.NetworkService unsandboxed", ...), then quits as Cosmos does.
import AppKit
import CosmosCEF

/// Non-zero when the process is in a sandbox (libsystem_sandbox; the call is variadic, and these three are its fixed
/// arguments).
@_silgen_name("sandbox_check")
private func sandbox_check(_ pid: pid_t, _ operation: UnsafePointer<CChar>?, _ type: Int32) -> Int32

let arguments = CommandLine.arguments
guard arguments.count == 4, let seconds = Double(arguments[3]), let frameworks = Bundle.main.privateFrameworksURL else {
    FileHandle.standardError.write(Data("usage: CosmosEngineCheck <data folder> <address> <seconds>, from inside its app\n".utf8))
    exit(2)
}

/// Chromium's processes, as children of this one: what each is and whether it is sandboxed.
func report() {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-axo", "pid=,ppid=,args="]
    let out = Pipe()
    ps.standardOutput = out
    try? ps.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let pid = pid_t(fields[0]), pid_t(fields[1]) == getpid() else { continue }
        func value(_ name: String) -> String? {
            fields[2].split(separator: " ").first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        guard let type = value("type") else { continue }
        let kind = [type, value("utility-sub-type")].compactMap { $0 }.joined(separator: " ")
        print("\(kind) \(sandbox_check(pid, nil, 0) != 0 ? "sandboxed" : "unsandboxed")")
    }
}

let app = CosmosApplication.shared
app.setActivationPolicy(.prohibited)
let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
guard CosmosCEFRuntime.start(withMainBundle: nil,
                             framework: frameworks.appendingPathComponent("Chromium Embedded Framework.framework").path,
                             helper: frameworks.appendingPathComponent("Cosmos Helper.app/Contents/MacOS/Cosmos Helper").path,
                             rootCache: root.path, globalCache: root.appendingPathComponent("Default").path,
                             switches: ["--use-mock-keychain"], sandboxed: true) else {
    print("not started: \(CosmosCEFRuntime.lastError ?? "")")
    exit(1)
}
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
CosmosCEFRuntime.whenReady {
    let browser = CosmosCEFBrowser(in: window.contentView!, context: CosmosCEFContext.global, url: arguments[2])
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        report()
        browser.close()
        CosmosCEFRuntime.shutdown { stopped in
            print(stopped ? "stopped" : "left running")
            exit(0)
        }
    }
}
app.run()
