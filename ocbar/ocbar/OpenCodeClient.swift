import Foundation

class OpenCodeClient {
    let port: Int
    private var base: String { "http://127.0.0.1:\(port)" }

    init(port: Int) { self.port = port }

    func health() async -> Bool {
        guard let url = URL(string: "\(base)/global/health"),
              let (_, resp) = try? await URLSession.shared.data(from: url) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func projectPath() async -> String {
        guard let url = URL(string: "\(base)/project/current"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["worktree"] as? String else { return "" }
        return path
    }

    func sessionStatus() async -> [String: String] {
        guard let url = URL(string: "\(base)/session/status"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return [:] }
        return raw.compactMapValues { $0["type"] }
    }

    func eventStream() -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let url = URL(string: "\(base)/event") else {
                continuation.finish(); return
            }
            let task = Task {
                do {
                    let (bytes, _) = try await URLSession.shared.bytes(from: url)
                    var eventType = ""
                    var dataLine = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLine = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        } else if line.isEmpty, !dataLine.isEmpty {
                            continuation.yield(SSEEvent(type: eventType, data: dataLine))
                            eventType = ""; dataLine = ""
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
