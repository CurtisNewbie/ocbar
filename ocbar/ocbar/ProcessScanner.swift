import Foundation

struct DiscoveredServer {
    let pid: Int32
    let port: Int
}

class ProcessScanner {
    func scan() -> [DiscoveredServer] {
        let output = runShell("ps aux")
        return parsePs(output)
    }

    static func cwd(pid: Int32) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "lsof -p \(pid) -a -d cwd -Fn 2>/dev/null | grep '^n' | head -1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("n") else { return "" }
        return String(path.dropFirst())
    }

    static func port(pid: Int32) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") {
            guard line.contains(" (LISTEN)"),
                  let range = line.range(of: "TCP ") else { continue }
            let hostPort = line[range.upperBound...].prefix(while: { $0 != " " })
            guard let sep = hostPort.lastIndex(of: ":") else { continue }
            let portStr = hostPort[hostPort.index(after: sep)...]
            guard let port = Int(portStr), port > 0 else { continue }
            return port
        }
        return 0
    }

    private func runShell(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parsePs(_ output: String) -> [DiscoveredServer] {
        var results: [DiscoveredServer] = []
        for line in output.components(separatedBy: "\n") {
            guard line.contains("opencode"),
                  !line.contains("grep") else { continue }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2, let pid = Int32(cols[1]) else { continue }

            var port = 0
            let parts = line.components(separatedBy: " ")
            for (i, part) in parts.enumerated() where part == "--port" {
                if i + 1 < parts.count, let p = Int(parts[i + 1]), p > 0 {
                    port = p
                    break
                }
            }
            if port == 0 {
                port = ProcessScanner.port(pid: pid)
            }

            if port > 0, !results.contains(where: { $0.pid == pid }) {
                results.append(DiscoveredServer(pid: pid, port: port))
            }
        }
        return results
    }
}
