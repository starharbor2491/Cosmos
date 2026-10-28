import Foundation

/// A message Chromium sent without being asked (`Page.loadEventFired`, ...).
public struct CDPEvent: @unchecked Sendable {
    public let method: String
    public let params: [String: Any]
    /// The target session it came from; nil for the browser itself.
    public let sessionID: String?
}

public struct CDPError: Error, Equatable, CustomStringConvertible {
    public let code: Int
    public let message: String
    public var description: String { "CDP \(code): \(message)" }
    static let closed = CDPError(code: -1, message: "The connection to Chromium is closed")
}

/// Splits what arrives on the pipe into messages: Chromium ends each JSON message with a NUL byte.
enum CDPFraming {
    static func split(_ buffer: inout Data) -> [Data] {
        var out: [Data] = []
        while let nul = buffer.firstIndex(of: 0) {
            out.append(buffer[buffer.startIndex..<nul])
            buffer = buffer[(nul + 1)...]
        }
        if buffer.isEmpty { buffer = Data() } else { buffer = Data(buffer) }
        return out
    }

    static func encode(id: Int, method: String, params: [String: Any], sessionID: String?) -> Data? {
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionID { message["sessionId"] = sessionID }
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        data.append(0)
        return data
    }
}

/// The DevTools protocol over the pipe Chromium opens with `--remote-debugging-pipe` (no network port: nothing else on the
/// Mac can reach it). Replies are matched to requests by id; events go to `onEvent` on the main actor, in order.
public final class CDPConnection: @unchecked Sendable {
    private let reader: FileHandle
    private let writer: FileHandle
    private let lock = NSLock()
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var isClosed = false
    private let writeQueue = DispatchQueue(label: "cosmos.cdp.write")

    /// Every event, on the main actor.
    public var onEvent: (@MainActor (CDPEvent) -> Void)?
    /// Chromium went away (it quit or crashed).
    public var onClose: (@MainActor () -> Void)?

    public init(readFrom reader: FileHandle, writeTo writer: FileHandle) {
        self.reader = reader
        self.writer = writer
    }

    public func start() {
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "cosmos.cdp.read"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func readLoop() {
        var buffer = Data()
        let fd = reader.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            for message in CDPFraming.split(&buffer) { handle(message) }
        }
        close()
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = object["id"] as? Int {
            lock.lock()
            let continuation = waiting.removeValue(forKey: id)
            lock.unlock()
            if let error = object["error"] as? [String: Any] {
                continuation?.resume(throwing: CDPError(code: error["code"] as? Int ?? 0, message: error["message"] as? String ?? ""))
            } else {
                continuation?.resume(returning: object["result"] as? [String: Any] ?? [:])
            }
        } else if let method = object["method"] as? String {
            let event = CDPEvent(method: method, params: object["params"] as? [String: Any] ?? [:], sessionID: object["sessionId"] as? String)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onEvent?(event) }
            }
        }
    }

    /// Sends a command and waits for its answer.
    @discardableResult
    public func send(_ method: String, _ params: [String: Any] = [:], session: String? = nil) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !isClosed else { lock.unlock(); continuation.resume(throwing: CDPError.closed); return }
            nextID += 1
            let id = nextID
            waiting[id] = continuation
            lock.unlock()
            guard let data = CDPFraming.encode(id: id, method: method, params: params, sessionID: session) else {
                lock.lock(); let c = waiting.removeValue(forKey: id); lock.unlock()
                c?.resume(throwing: CDPError(code: -2, message: "Could not encode \(method)"))
                return
            }
            write(data)
        }
    }

    /// Sends a command whose answer does not matter (input events, acknowledgements). Sent in the order of the calls.
    public func post(_ method: String, _ params: [String: Any] = [:], session: String? = nil) {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        nextID += 1
        let id = nextID
        lock.unlock()
        if let data = CDPFraming.encode(id: id, method: method, params: params, sessionID: session) { write(data) }
    }

    private func write(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            do { try self.writer.write(contentsOf: data) } catch { self.close() }
        }
    }

    public func close() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        let pending = waiting
        waiting.removeAll()
        lock.unlock()
        for c in pending.values { c.resume(throwing: CDPError.closed) }
        try? writer.close()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onClose?() }
        }
    }
}
