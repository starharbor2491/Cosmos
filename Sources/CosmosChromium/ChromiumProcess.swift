import Foundation
import Darwin

/// One running Chromium, started headless with `--remote-debugging-pipe`: it reads commands from its descriptor 3 and
/// writes answers to its descriptor 4. It has no windows and no Dock icon; Cosmos draws everything.
final class ChromiumProcess {
    let pid: pid_t
    let connection: CDPConnection
    private var exitSource: DispatchSourceProcess?
    /// Called on the main actor when the process ends.
    var onExit: (@MainActor (Int32) -> Void)?

    /// The command line, apart from the executable. Pure, so it can be tested.
    static func arguments(userDataDirectory: URL, extraFlags: [String]) -> [String] {
        [
            "--headless",
            "--remote-debugging-pipe",
            "--user-data-dir=\(userDataDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            // Lets Cosmos load and drive extensions over the pipe (Extensions.loadUnpacked, triggerAction).
            "--enable-unsafe-extension-debugging",
            // Chromium is re-downloaded on every update and signed ad hoc, so the Keychain would ask about it each time.
            "--use-mock-keychain",
            "--password-store=basic",
            "--disable-features=Translate,MediaRouter,DialMediaRouteProvider",
            // `--headless` and the pipe each make `navigator.webdriver` true, which sites such as Google's sign-in refuse.
            "--disable-blink-features=AutomationControlled",
            "--window-size=1280,800",
        ] + extraFlags + ["about:blank"]
    }

    /// Cosmos's environment, with Chromium's crash folder inside its own data: Chromium picks that folder before it reads
    /// `--user-data-dir`, and would otherwise use the one in `~/Library/Application Support/Chromium`.
    static func environment(userDataDirectory: URL, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var env = inherited
        env["BREAKPAD_DUMP_LOCATION"] = userDataDirectory.appendingPathComponent("Crashpad").path
        return env.map { "\($0.key)=\($0.value)" }
    }

    init(executable: URL, arguments: [String], environment: [String]) throws {
        var commands: [Int32] = [0, 0]   // Cosmos writes [1], Chromium reads [0]
        var answers: [Int32] = [0, 0]    // Chromium writes [1], Cosmos reads [0]
        guard pipe(&commands) == 0, pipe(&answers) == 0 else { throw CDPError(code: Int(errno), message: "Could not make the pipe to Chromium") }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // dup2 clears close-on-exec, so Chromium sees the pipe at 3 and 4 whatever numbers it has here.
        posix_spawn_file_actions_adddup2(&actions, commands[0], 3)
        posix_spawn_file_actions_adddup2(&actions, answers[1], 4)
        let devNull = open("/dev/null", O_RDWR)
        if devNull >= 0 {
            posix_spawn_file_actions_adddup2(&actions, devNull, 0)
            posix_spawn_file_actions_adddup2(&actions, devNull, 1)
            posix_spawn_file_actions_adddup2(&actions, devNull, 2)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Nothing else of Cosmos's leaks into Chromium.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = [executable.path] + arguments
        var cArgs = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var cEnv = environment.map { strdup($0) } + [nil]
        defer { cEnv.forEach { free($0) } }
        var child: pid_t = 0
        let result = posix_spawn(&child, executable.path, &actions, &attributes, &cArgs, &cEnv)
        close(commands[0]); close(answers[1])
        if devNull >= 0 { close(devNull) }
        guard result == 0 else {
            close(commands[1]); close(answers[0])
            throw CDPError(code: Int(result), message: "Chromium did not start (\(String(cString: strerror(result))))")
        }
        pid = child
        connection = CDPConnection(readFrom: FileHandle(fileDescriptor: answers[0], closeOnDealloc: true),
                                   writeTo: FileHandle(fileDescriptor: commands[1], closeOnDealloc: true))
        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.pid, &status, WNOHANG)
            self.exitSource?.cancel()
            MainActor.assumeIsolated { self.onExit?(status) }
        }
        source.resume()
        exitSource = source
        connection.start()
    }

    /// Asks Chromium to close, and makes sure it does.
    func terminate() {
        connection.post("Browser.close")
        let pid = self.pid
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    deinit { exitSource?.cancel() }
}
