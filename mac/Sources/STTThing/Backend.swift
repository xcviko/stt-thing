import Foundation

/// Messages from backend/stt_server.py (one JSON object per stdout line).
enum BackendEvent {
    case ready(device: String)
    case level(speech: Bool)
    case update(seg: Int, committed: String, tentative: String, final: Bool, ms: Int)
    case error(String)
    case stopped(code: Int32)
}

struct InputDevice: Hashable {
    let index: Int
    let name: String
}

/// Runs the Python backend as a child process and parses its output.
final class Backend {
    let backendDir: URL
    var onEvent: ((BackendEvent) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var stoppingProcess: Process?

    init(backendDir: URL) {
        self.backendDir = backendDir
    }

    /// The backend folder: Info.plist key STTBackendDir (set by make-app.sh),
    /// the STT_BACKEND_DIR env variable, or a "backend" folder above the
    /// current directory or the executable.
    static func locateBackendDir() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let dir = Bundle.main.object(forInfoDictionaryKey: "STTBackendDir") as? String {
            candidates.append(URL(fileURLWithPath: dir))
        }
        if let dir = ProcessInfo.processInfo.environment["STT_BACKEND_DIR"] {
            candidates.append(URL(fileURLWithPath: dir))
        }
        for start in [URL(fileURLWithPath: fm.currentDirectoryPath), Bundle.main.executableURL ?? URL(fileURLWithPath: "/")] {
            var url = start
            for _ in 0..<8 {
                candidates.append(url.appendingPathComponent("backend"))
                url = url.deletingLastPathComponent()
            }
        }
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("stt_server.py").path) }
    }

    /// The venv python when it exists, otherwise `uv run` (creates the venv).
    private func command(_ args: [String]) -> (URL, [String]) {
        let script = backendDir.appendingPathComponent("stt_server.py").path
        let venvPython = backendDir.appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            return (venvPython, [script] + args)
        }
        let uvPaths = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        let uv = uvPaths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"
        let prefix = uv == "/usr/bin/env" ? ["uv"] : []
        return (URL(fileURLWithPath: uv), prefix + ["run", "--project", backendDir.path, "python", script] + args)
    }

    func start(device: String) {
        stop()
        let (exe, args) = command(["--device", device])
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = backendDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        buffer = Data()

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) {
                FileHandle.standardError.write(Data(("[backend] " + s).utf8))
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                if self.stoppingProcess === proc { self.stoppingProcess = nil; return }
                if self.process === proc { self.process = nil }
                self.onEvent?(.stopped(code: proc.terminationStatus))
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            onEvent?(.error("Could not start backend: \(error.localizedDescription)"))
        }
    }

    func stop() {
        guard let p = process else { return }
        process = nil
        stoppingProcess = p
        p.terminate() // SIGTERM; the backend also exits when its parent dies
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let event = Self.parse(line) { onEvent?(event) }
        }
    }

    private static func parse(_ line: Data) -> BackendEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "ready":
            return .ready(device: obj["device"] as? String ?? "")
        case "level":
            return .level(speech: obj["speech"] as? Bool ?? false)
        case "update":
            return .update(
                seg: obj["seg"] as? Int ?? 0,
                committed: obj["committed"] as? String ?? "",
                tentative: obj["tentative"] as? String ?? "",
                final: obj["final"] as? Bool ?? false,
                ms: obj["ms"] as? Int ?? 0
            )
        case "error":
            return .error(obj["message"] as? String ?? "error")
        default:
            return nil
        }
    }

    /// Lists input devices (runs the backend with --list-devices).
    func listDevices(completion: @escaping ([InputDevice]) -> Void) {
        let (exe, args) = command(["--list-devices"])
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.currentDirectoryURL = self.backendDir
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            var devices: [InputDevice] = []
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let lastLine = data.split(separator: 0x0A).last.map { Data($0) } ?? Data()
                if let obj = try? JSONSerialization.jsonObject(with: lastLine) as? [String: Any],
                   let list = obj["devices"] as? [[String: Any]] {
                    devices = list.compactMap { d in
                        guard let i = d["index"] as? Int, let n = d["name"] as? String else { return nil }
                        return InputDevice(index: i, name: n)
                    }
                }
            }
            DispatchQueue.main.async { completion(devices) }
        }
    }
}
