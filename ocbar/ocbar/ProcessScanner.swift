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
            guard line.contains("opencode --port"),
                  !line.contains("grep") else { continue }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2, let pid = Int32(cols[1]) else { continue }
            let parts = line.components(separatedBy: " ")
            for (i, part) in parts.enumerated() {
                if part == "--port", i + 1 < parts.count, let port = Int(parts[i + 1]), port > 0 {
                    if !results.contains(where: { $0.pid == pid }) {
                        results.append(DiscoveredServer(pid: pid, port: port))
                    }
                }
            }
        }
        return results
    }
}
