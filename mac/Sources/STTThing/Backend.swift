import Foundation

/// Messages from backend/stt_server.py (one JSON object per stdout line).
enum BackendEvent {
    case ready(device: String)
    case level(speech: Bool)
    case paused(Bool)
    case update(seg: Int, committed: String, tentative: String, final: Bool, ms: Int)
    case error(String)
    /// A stderr line (uv installing packages, model download, ...).
    case log(String)
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
    private var stdin: FileHandle?
    private var buffer = Data()
    private var logHandle: FileHandle?
    private var stoppingProcess: Process?

    init(backendDir: URL) {
        self.backendDir = backendDir
    }

    /// The backend folder: Info.plist key STTBackendDir (dev builds from
    /// make-app.sh), the STT_BACKEND_DIR env variable, the copy inside the app
    /// (release builds), or a "backend" folder above the current directory or
    /// the executable.
    static func locateBackendDir() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let dir = Bundle.main.object(forInfoDictionaryKey: "STTBackendDir") as? String {
            candidates.append(URL(fileURLWithPath: dir))
        }
        if let dir = ProcessInfo.processInfo.environment["STT_BACKEND_DIR"] {
            candidates.append(URL(fileURLWithPath: dir))
        }
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("backend"))
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

    /// Release builds carry the backend and a uv binary inside the app.
    private var bundledUV: URL? {
        guard let res = Bundle.main.resourceURL,
              backendDir.standardizedFileURL.path.hasPrefix(res.standardizedFileURL.path) else { return nil }
        let uv = res.appendingPathComponent("bin/uv")
        return FileManager.default.isExecutableFile(atPath: uv.path) ? uv : nil
    }

    /// Release builds also carry the speech model, so nothing is downloaded
    /// from Hugging Face (some networks cannot reach it).
    private var bundledModel: URL? {
        guard bundledUV != nil, let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("model")
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) ? dir : nil
    }

    /// Release: `uv run` with the bundled uv; the venv (and Python, if the Mac
    /// has no 3.12) go to Application Support on first launch.
    /// Dev: the repo's venv python, or `uv run` to create it.
    private func command(_ args: [String]) -> (URL, [String]) {
        let script = backendDir.appendingPathComponent("stt_server.py").path
        if let uv = bundledUV {
            var extra: [String] = []
            if let model = bundledModel { extra = ["--model", model.path] }
            return (uv, ["run", "--project", backendDir.path, "--frozen", "python", script] + extra + args)
        }
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
        if bundledUV != nil,
           !FileManager.default.fileExists(atPath: AppPaths.dataDir.appendingPathComponent("venv/bin/python").path) {
            onEvent?(.log(bundledModel != nil
                ? "first launch: installing Python packages (~0.5 GB), a minute or two…"
                : "first launch: installing Python packages (~0.5 GB), then the speech model (~0.8 GB)…"))
        }
        openLog(command: [exe.path] + args)
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = backendDir
        p.environment = environment()

        let out = Pipe()
        let err = Pipe()
        let inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        buffer = Data()

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            FileHandle.standardError.write(Data(("[backend] " + s).utf8))
            DispatchQueue.main.async { try? self?.logHandle?.write(contentsOf: data) }
            // Progress bars rewrite the line with \r: keep the last piece.
            let last = s.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            if let last {
                DispatchQueue.main.async { self?.onEvent?(.log(last)) }
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
            stdin = inp.fileHandleForWriting
        } catch {
            onEvent?(.error("Could not start backend: \(error.localizedDescription)"))
        }
    }

    /// Backend stderr also goes to Application Support/stt-thing/backend.log
    /// (rewritten on every start) so problems on other Macs can be read later.
    private func openLog(command: [String]) {
        try? logHandle?.close()
        let url = AppPaths.dataDir.appendingPathComponent("backend.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let header = "\(Date()) stt-thing \(version)\n$ \(command.joined(separator: " "))\n"
        try? logHandle?.write(contentsOf: Data(header.utf8))
    }

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["PYTHONUNBUFFERED"] = "1"
        if bundledUV != nil {
            // Nothing may be written into the signed app bundle.
            env["UV_PROJECT_ENVIRONMENT"] = AppPaths.dataDir.appendingPathComponent("venv").path
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            env["UV_NO_PROGRESS"] = "1"
        }
        return env
    }

    /// Sends a command line ("pause" / "resume") to the backend.
    func send(_ command: String) {
        guard let stdin, process?.isRunning == true else { return }
        try? stdin.write(contentsOf: Data((command + "\n").utf8))
    }

    func stop() {
        guard let p = process else { return }
        process = nil
        try? stdin?.close()
        stdin = nil
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
        case "paused":
            return .paused(obj["paused"] as? Bool ?? false)
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
            p.environment = self.environment()
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
