import Foundation
import Darwin

/// `NativeScreen --mcp`: what MCP clients run. It never starts AppKit; it connects to the running app's socket
/// (`MCPServer.socketPath`), opening the app first if needed, and copies bytes both ways until either side closes.
/// Nothing else may be written to stdout, which carries the protocol.
enum MCPStdioBridge {
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)

        var fd = connectToApp()
        if fd < 0 {
            let enabled = UserDefaults.standard.bool(forKey: MCPServer.enabledDefaultsKey)
            guard enabled else {
                failFirstRequest("AI agent access is turned off. In Native Screen, open Settings > AI Agents and turn on “Allow AI agents to control Native Screen”.")
            }
            launchApp()
            let deadline = Date().addingTimeInterval(20)
            while fd < 0 && Date() < deadline {
                usleep(250_000)
                fd = connectToApp()
            }
            guard fd >= 0 else {
                failFirstRequest("Native Screen did not start its AI agent server. Open Native Screen and check Settings > AI Agents.")
            }
        }

        let socketFD = fd
        // stdin -> app
        Thread.detachNewThread {
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = read(STDIN_FILENO, &chunk, chunk.count)
                if n <= 0 { exit(0) }
                if !writeAll(socketFD, chunk, n) { exit(0) }
            }
        }
        // app -> stdout
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(socketFD, &chunk, chunk.count)
            if n <= 0 {
                fputs("Native Screen closed the connection.\n", stderr)
                exit(0)
            }
            if !writeAll(STDOUT_FILENO, chunk, n) { exit(0) }
        }
    }

    private static func connectToApp() -> Int32 {
        guard var addr = MCPServer.unixAddress(MCPServer.socketPath) else { return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    /// Opens the app bundle this executable belongs to, in the background.
    private static func launchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", Bundle.main.bundlePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, count - offset) }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }

    /// Answers the client's first request (normally `initialize`) with the reason, so it shows up in the client.
    private static func failFirstRequest(_ message: String) -> Never {
        fputs(message + "\n", stderr)
        var id: Any = NSNull()
        if let line = readLine(),
           let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           let requestId = object["id"] {
            id = requestId
        }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]
        if var data = try? JSONSerialization.data(withJSONObject: response) {
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        }
        exit(1)
    }
}
