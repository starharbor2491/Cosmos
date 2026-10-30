// Cosmos Engine Check: Chromium started as Cosmos.app starts it, from inside an app bundle with Cosmos's helper apps,
// for the tests that need a process of their own. Chromium's sandbox lets a helper read only the app the browser process
// is, so it cannot be checked in a test runner; and Chromium stops only once in a process, so quitting cannot either.
//
// Usage: CosmosEngineCheck <data folder> <address> <seconds> [<keychain name>]
// Shows <address> for <seconds> in a window that is never on screen, prints a line for each of Chromium's processes
// ("renderer sandboxed", "utility network.mojom.NetworkService unsandboxed", ...), then quits as Cosmos does. With a
// keychain name (a test's own, "Cosmos Test …"), Chromium keeps its key in the login Keychain as Cosmos's does, under that
// name instead of Cosmos's; the check says whether the item was there ("keychain item made"), deletes it, and asks the
// user nothing meanwhile. A check that is killed first leaves the item behind.
import AppKit
import CosmosCEF
import Security

/// Non-zero when the process is in a sandbox (libsystem_sandbox; the call is variadic, and these three are its fixed
/// arguments).
@_silgen_name("sandbox_check")
private func sandbox_check(_ pid: pid_t, _ operation: UnsafePointer<CChar>?, _ type: Int32) -> Int32

let arguments = CommandLine.arguments
guard arguments.count == 4 || arguments.count == 5, let seconds = Double(arguments[3]), let frameworks = Bundle.main.privateFrameworksURL else {
    FileHandle.standardError.write(Data("usage: CosmosEngineCheck <data folder> <address> <seconds> [<keychain name>], from inside its app\n".utf8))
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

let keychainName = arguments.count == 5 ? arguments[4] : nil
// The check deletes the item at the end, so it only takes a name of a test's own.
if let keychainName, !keychainName.hasPrefix("Cosmos Test ") {
    FileHandle.standardError.write(Data("the keychain name must start with \"Cosmos Test \"\n".utf8))
    exit(2)
}
// A Keychain item that would need the user's yes fails instead of asking.
if keychainName != nil { SecKeychainSetUserInteractionAllowed(false) }

/// Whether the item Chromium keeps its key in is in the Keychain, after which it is deleted.
func removeKeychainItem(_ name: String) {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "\(name) Safe Storage",
                                kSecAttrAccount as String: name]
    print(SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess ? "keychain item made" : "no keychain item")
    print(SecItemDelete(query as CFDictionary) == errSecSuccess ? "keychain item deleted" : "keychain item not deleted")
}

let app = CosmosApplication.shared
app.setActivationPolicy(.prohibited)
let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
guard CosmosCEFRuntime.start(withMainBundle: nil,
                             framework: frameworks.appendingPathComponent("Chromium Embedded Framework.framework").path,
                             helper: frameworks.appendingPathComponent("Cosmos Helper.app/Contents/MacOS/Cosmos Helper").path,
                             rootCache: root.path, globalCache: root.appendingPathComponent("Default").path,
                             switches: keychainName == nil ? ["--use-mock-keychain"] : [], keychainName: keychainName,
                             sandboxed: true) else {
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
            if let keychainName { removeKeychainItem(keychainName) }
            exit(0)
        }
    }
}
app.run()
