import Foundation
import Darwin
import Observation

/// Lets AI agents (Claude, Codex, Cursor...) drive the app through the Model Context Protocol. See ADR-52 in `spec/06`.
///
/// The app is the MCP server; it listens on a Unix socket only the current user can open. Clients start
/// `NativeScreen --mcp` (`MCPStdioBridge`), which pipes their stdin and stdout to this socket, so recording keeps the
/// app's own screen, camera and microphone permissions, and every edit lands in the editor the user sees.
@Observable
@MainActor
public final class MCPServer {
    public static let shared = MCPServer()

    /// Settings key, also read by the bridge before the app is running.
    nonisolated static let enabledDefaultsKey = "NativeScreen.Settings.AIAgentsEnabled"

    /// `~/Library/Application Support/NativeScreen/mcp.sock`.
    nonisolated static var socketPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("NativeScreen/mcp.sock").path
    }

    public private(set) var isListening = false
    public private(set) var connectedClients: [String] = []
    public private(set) var lastError: String?

    @ObservationIgnored private var listenFD: Int32 = -1
    @ObservationIgnored private var acceptSource: DispatchSourceRead?
    @ObservationIgnored private var connections: [ObjectIdentifier: MCPConnection] = [:]
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "NativeScreen.MCP.io")
    @ObservationIgnored let tools = MCPToolbox()

    private init() {}

    /// Starts or stops listening to match `AppSettings.aiAgentsEnabled`.
    public func applySetting() {
        if AppSettings.shared.aiAgentsEnabled {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard !isListening else { return }
        lastError = nil
        let path = Self.socketPath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return fail("socket() failed: \(errno)") }
        guard var addr = Self.unixAddress(path) else {
            close(fd)
            return fail("Socket path is too long: \(path)")
        }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return fail("bind() failed: \(errno)")
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            close(fd)
            unlink(path)
            return fail("listen() failed: \(errno)")
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            Task { @MainActor [weak self] in self?.adopt(clientFD: client) }
        }
        source.resume()
        acceptSource = source
        isListening = true
    }

    /// Called when the app quits.
    public func shutdown() {
        stop()
    }

    private func stop() {
        guard isListening else { return }
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(Self.socketPath)
        for connection in connections.values { connection.close() }
        connections.removeAll()
        connectedClients.removeAll()
        isListening = false
    }

    private func fail(_ message: String) {
        lastError = message
        NSLog("NativeScreen MCP: %@", message)
    }

    private func adopt(clientFD: Int32) {
        // The socket file is 0600 already; also refuse peers running as another user.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(clientFD, &uid, &gid) == 0, uid == getuid() else {
            close(clientFD)
            return
        }
        var on: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let connection = MCPConnection(fd: clientFD, queue: ioQueue)
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection else { return }
            self.handle(message, from: connection)
        }
        connection.onClose = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.connections[ObjectIdentifier(connection)] = nil
            self.refreshClientList()
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    private func refreshClientList() {
        connectedClients = connections.values.compactMap(\.clientName).sorted()
    }

    // MARK: - JSON-RPC

    nonisolated static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private func handle(_ message: [String: Any], from connection: MCPConnection) {
        let method = message["method"] as? String
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        guard let method else { return } // a response to a request we never send
        let isNotification = (id == nil)

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? Self.supportedProtocolVersions[0]
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String {
                connection.clientName = name
            } else {
                connection.clientName = "MCP client"
            }
            let wasEmpty = connectedClients.isEmpty
            refreshClientList()
            if wasEmpty {
                ProjectWorkspaceStore.shared.activeSession?.showToast("AI agent connected")
            }
            connection.reply(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "nativescreen", "title": "Native Screen", "version": Self.appVersion],
                "instructions": tools.instructions,
            ])
        case "notifications/initialized", "notifications/roots/list_changed":
            break
        case "ping":
            connection.reply(id: id, result: [:])
        case "tools/list":
            connection.reply(id: id, result: ["tools": tools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else {
                connection.replyError(id: id, code: -32602, message: "Missing tool name")
                return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let progressToken = (params["_meta"] as? [String: Any])?["progressToken"]
            let progress: MCPProgress? = progressToken.map { token in
                MCPProgress { [weak connection] fraction, text in
                    connection?.notify(method: "notifications/progress", params: [
                        "progressToken": token,
                        "progress": fraction,
                        "total": 1.0,
                        "message": text,
                    ])
                }
            }
            let task = Task { @MainActor [weak self, weak connection] in
                guard let self else { return }
                let result = await self.tools.call(name: name, arguments: arguments, progress: progress)
                connection?.finishTask(requestKey: Self.key(for: id))
                guard !Task.isCancelled else { return }
                connection?.reply(id: id, result: result)
            }
            connection.track(task: task, requestKey: Self.key(for: id))
        case "notifications/cancelled":
            if let requestId = params["requestId"] {
                connection.cancelTask(requestKey: Self.key(for: requestId))
            }
        case "resources/list":
            connection.reply(id: id, result: ["resources": []])
        case "prompts/list":
            connection.reply(id: id, result: ["prompts": []])
        default:
            if !isNotification {
                connection.replyError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    private static func key(for id: Any?) -> String {
        switch id {
        case let s as String: return "s:" + s
        case let n as NSNumber: return "n:" + n.stringValue
        default: return "?"
        }
    }

    nonisolated static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    nonisolated static func unixAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }
}

/// Reports progress of a long tool call back to the client that asked for it.
public struct MCPProgress {
    let send: (Double, String) -> Void
    init(_ send: @escaping (Double, String) -> Void) { self.send = send }
    func report(_ fraction: Double, _ message: String) { send(fraction, message) }
}

/// One client on the socket. Messages are newline-delimited JSON-RPC, as on MCP's stdio transport.
@MainActor
final class MCPConnection {
    let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var isClosed = false
    var clientName: String?
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func start() {
        let fd = self.fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = read(fd, &chunk, chunk.count)
            let data = n > 0 ? Data(chunk[0..<n]) : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data {
                    self.receive(data)
                } else {
                    self.close()
                }
            }
        }
        source.resume()
        readSource = source
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: line) else {
                replyError(id: nil, code: -32700, message: "Parse error")
                continue
            }
            if let batch = object as? [[String: Any]] {
                batch.forEach { onMessage?($0) }
            } else if let message = object as? [String: Any] {
                onMessage?(message)
            }
        }
    }

    func reply(id: Any?, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    func replyError(id: Any?, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    func notify(method: String, params: [String: Any]) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func send(_ object: [String: Any]) {
        guard !isClosed, var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        let fd = self.fd
        queue.async {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
    }

    func track(task: Task<Void, Never>, requestKey: String) {
        tasks[requestKey] = task
    }

    func finishTask(requestKey: String) {
        tasks[requestKey] = nil
    }

    func cancelTask(requestKey: String) {
        tasks.removeValue(forKey: requestKey)?.cancel()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        readSource?.cancel()
        readSource = nil
        let fd = self.fd
        queue.async { Darwin.close(fd) }
        onClose?()
    }
}
