import Foundation
import Network

/// Lightweight local HTTP studio (MLX-only) covering the Python web app's core APIs:
/// runtime probe, create job from uploaded/local file, list jobs, export files, burn-in.
///
/// Start:
/// ```swift
/// let server = try await LocalStudioServer(modelPath: "...", runsDirectory: ...)
/// try await server.start(host: "127.0.0.1", port: 7860)
/// ```
public final class LocalStudioServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var modelPath: String
        public var runsDirectory: URL
        public var parameters: GenerateParameters
        public var postprocessSubtitles: Bool

        public init(
            modelPath: String = MossDefaults.recommendedModel,
            runsDirectory: URL = URL(fileURLWithPath: "runs/swift_web", isDirectory: true),
            parameters: GenerateParameters = GenerateParameters(),
            postprocessSubtitles: Bool = false
        ) {
            self.modelPath = modelPath
            self.runsDirectory = runsDirectory
            self.parameters = parameters
            self.postprocessSubtitles = postprocessSubtitles
        }
    }

    private struct JobRecord: Sendable {
        var id: String
        var status: String
        var inputPath: String
        var outDir: String
        var error: String?
        var summary: [String: String]
        var createdAt: Date
    }

    public let configuration: Configuration
    private var model: MossModel?
    private var listener: NWListener?
    private var jobs: [String: JobRecord] = [:]
    private let queue = DispatchQueue(label: "moss.local.studio")

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func start(host: String = "127.0.0.1", port: UInt16 = 7860) async throws {
        if model == nil {
            model = try await ModelLoader.load(configuration.modelPath)
        }
        try FileManager.default.createDirectory(
            at: configuration.runsDirectory,
            withIntermediateDirectories: true
        )

        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: queue)
        print("Moss studio listening on http://\(host):\(port)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest.parse(buffer) {
                let response = self.route(request)
                connection.send(
                    content: response.serialize(),
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    // MARK: - Routes

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(StudioHTML.index)
        case ("GET", "/api/runtime"):
            return .json([
                "ffmpeg": FFmpegTools.detect().asDictionary(),
                "model": configuration.modelPath,
                "backend": "mlx-swift",
                "inference": [
                    "max_tokens": configuration.parameters.maxTokens,
                    "temperature": configuration.parameters.temperature,
                    "prompt": configuration.parameters.resolvedPrompt,
                ],
            ])
        case ("GET", "/api/jobs"):
            let list = jobs.values
                .sorted { $0.createdAt > $1.createdAt }
                .map { jobJSON($0) }
            return .json(["jobs": list])
        case ("POST", "/api/jobs"):
            return createJob(request)
        case ("POST", "/api/jobs/from-path"):
            return createJobFromPath(request)
        default:
            if request.method == "GET", request.path.hasPrefix("/api/jobs/") {
                let rest = String(request.path.dropFirst("/api/jobs/".count))
                if rest.hasSuffix("/files"), let id = rest.split(separator: "/").first.map(String.init) {
                    return listJobFiles(id: id)
                }
                if let id = rest.split(separator: "/").first.map(String.init), rest == id {
                    return jobDetail(id: id)
                }
                if rest.hasSuffix("/render"), let id = rest.split(separator: "/").first.map(String.init) {
                    return renderJob(id: id)
                }
            }
            if request.method == "GET", request.path.hasPrefix("/files/") {
                return serveFile(path: String(request.path.dropFirst("/files/".count)))
            }
            return .notFound("Not found: \(request.path)")
        }
    }

    private func createJob(_ request: HTTPRequest) -> HTTPResponse {
        // Multipart or raw body saved as upload.
        guard let model else {
            return .error(503, "Model not loaded")
        }
        let jobID = UUID().uuidString.prefix(8).lowercased()
        let jobDir = configuration.runsDirectory.appendingPathComponent(String(jobID), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
            let inputURL = jobDir.appendingPathComponent("input.bin")
            if let multipart = request.multipartFileData() {
                try multipart.write(to: inputURL)
            } else if !request.body.isEmpty {
                try request.body.write(to: inputURL)
            } else {
                return .error(400, "Missing upload body")
            }
            return runJob(id: String(jobID), inputURL: inputURL, model: model, request: request)
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    private func createJobFromPath(_ request: HTTPRequest) -> HTTPResponse {
        guard let model else { return .error(503, "Model not loaded") }
        guard let object = request.jsonObject(),
              let path = object["path"] as? String
        else {
            return .error(400, "JSON body requires {\"path\": \"/local/file\"}")
        }
        let inputURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            return .error(404, "File not found: \(path)")
        }
        let jobID = UUID().uuidString.prefix(8).lowercased()
        return runJob(id: String(jobID), inputURL: inputURL, model: model, request: request)
    }

    private func runJob(id: String, inputURL: URL, model: MossModel, request: HTTPRequest) -> HTTPResponse {
        let jobDir = configuration.runsDirectory.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
            var parameters = configuration.parameters
            if let object = request.jsonObject() {
                if let prompt = object["prompt"] as? String { parameters.prompt = prompt }
                if let maxTokens = object["max_new_tokens"] as? Int { parameters.maxTokens = maxTokens }
                if let temperature = object["temperature"] as? Double {
                    parameters.temperature = Float(temperature)
                }
                if let hotwords = object["hotwords"] as? [String] { parameters.hotwords = hotwords }
            }
            let burn = (request.jsonObject()?["render"] as? Bool) ?? false
            let options = PipelineOptions(
                parameters: parameters,
                postprocessSubtitles: configuration.postprocessSubtitles,
                burnSubtitles: burn
            )
            let artifacts = try TranscribePipeline(model: model).run(
                inputURL: inputURL,
                outDirectory: jobDir,
                options: options
            )
            let record = JobRecord(
                id: id,
                status: "completed",
                inputPath: inputURL.path,
                outDir: jobDir.path,
                error: nil,
                summary: artifacts.summary,
                createdAt: Date()
            )
            jobs[id] = record
            return .json(jobJSON(record))
        } catch {
            let record = JobRecord(
                id: id,
                status: "failed",
                inputPath: inputURL.path,
                outDir: jobDir.path,
                error: error.localizedDescription,
                summary: [:],
                createdAt: Date()
            )
            jobs[id] = record
            return .error(500, error.localizedDescription)
        }
    }

    private func jobDetail(id: String) -> HTTPResponse {
        guard let job = jobs[id] else { return .notFound("Unknown job") }
        return .json(jobJSON(job))
    }

    private func listJobFiles(id: String) -> HTTPResponse {
        guard let job = jobs[id] else { return .notFound("Unknown job") }
        let dir = URL(fileURLWithPath: job.outDir, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return .json(["files": files])
    }

    private func renderJob(id: String) -> HTTPResponse {
        guard let job = jobs[id] else { return .notFound("Unknown job") }
        let dir = URL(fileURLWithPath: job.outDir, isDirectory: true)
        let ass = dir.appendingPathComponent("subtitle.ass")
        let input = URL(fileURLWithPath: job.inputPath)
        let output = dir.appendingPathComponent("output.mp4")
        do {
            _ = try FFmpegTools.burnASSSubtitles(inputMedia: input, assURL: ass, outputURL: output)
            return .json(["mp4": output.path])
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    private func serveFile(path: String) -> HTTPResponse {
        // path format: {jobId}/{filename}
        let url = configuration.runsDirectory.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else {
            return .notFound("File not found")
        }
        return HTTPResponse(status: 200, contentType: mime(for: url), body: data)
    }

    private func jobJSON(_ job: JobRecord) -> [String: Any] {
        [
            "id": job.id,
            "status": job.status,
            "input": job.inputPath,
            "out_dir": job.outDir,
            "error": job.error as Any,
            "summary": job.summary,
            "created_at": ISO8601DateFormatter().string(from: job.createdAt),
        ]
    }

    private func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "json": return "application/json"
        case "srt", "ass", "txt": return "text/plain; charset=utf-8"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Minimal HTTP

private struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.contains(":") {
            let pair = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pair.count == 2 {
                headers[pair[0].lowercased()] = pair[1]
            }
        }
        let body = data.subdata(in: headerRange.upperBound..<data.endIndex)
        if let lengthString = headers["content-length"], let length = Int(lengthString), body.count < length {
            return nil
        }
        let path = String(parts[1].split(separator: "?").first ?? parts[1])
        return HTTPRequest(method: String(parts[0]), path: path, headers: headers, body: body)
    }

    func jsonObject() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    func multipartFileData() -> Data? {
        guard let contentType = headers["content-type"],
              contentType.contains("multipart/form-data"),
              let boundaryKey = contentType.split(separator: "boundary=").last
        else { return nil }
        let boundary = "--\(boundaryKey)"
        guard let bodyText = String(data: body, encoding: .isoLatin1) else { return body }
        let parts = bodyText.components(separatedBy: boundary)
        for part in parts {
            if part.contains("filename=") {
                if let range = part.range(of: "\r\n\r\n") {
                    var file = String(part[range.upperBound...])
                    if file.hasSuffix("\r\n") { file.removeLast(2) }
                    if file.hasSuffix("--") { file.removeLast(2) }
                    return Data(file.utf8)
                }
            }
        }
        return nil
    }
}

private struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    static func json(_ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]))
            ?? Data("{}".utf8)
        return HTTPResponse(status: 200, contentType: "application/json", body: data)
    }

    static func html(_ text: String) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(text.utf8))
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(["error": message, "status": status]).withStatus(status)
    }

    static func notFound(_ message: String) -> HTTPResponse {
        error(404, message)
    }

    func withStatus(_ status: Int) -> HTTPResponse {
        var copy = self
        copy.status = status
        return copy
    }

    func serialize() -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        default: reason = "OK"
        }
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Connection: close\r
        Cache-Control: no-store\r
        \r

        """
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}

private enum StudioHTML {
    static let index = """
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>MOSS Transcribe Studio (Swift)</title>
      <style>
        :root { color-scheme: light dark; font-family: ui-sans-serif, system-ui, sans-serif; }
        body { margin: 0; padding: 24px; max-width: 960px; }
        h1 { margin-top: 0; }
        card, section { display:block; border:1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 12px; padding: 16px; margin: 16px 0; }
        label { display:block; margin: 8px 0 4px; font-size: 13px; opacity: .8; }
        input, textarea, button, select { font: inherit; }
        input[type=text], textarea { width: 100%; box-sizing: border-box; padding: 8px; }
        button { margin-top: 12px; padding: 8px 14px; border-radius: 8px; border: 0; background: #2563eb; color: white; cursor: pointer; }
        button.secondary { background: #475569; }
        pre { white-space: pre-wrap; background: color-mix(in srgb, CanvasText 6%, transparent); padding: 12px; border-radius: 8px; }
        .row { display:flex; gap: 12px; flex-wrap: wrap; }
        .row > * { flex: 1; min-width: 180px; }
      </style>
    </head>
    <body>
      <h1>MOSS Transcribe Studio</h1>
      <p>Swift / MLX local studio — parity with Python web core APIs.</p>
      <section>
        <h2>Runtime</h2>
        <pre id="runtime">loading…</pre>
      </section>
      <section>
        <h2>New job (local path)</h2>
        <label>Audio / video path</label>
        <input id="path" type="text" placeholder="/path/to/file.wav" />
        <label>Prompt (optional)</label>
        <textarea id="prompt" rows="3"></textarea>
        <div class="row">
          <div>
            <label>Max tokens</label>
            <input id="maxTokens" type="text" value="2048" />
          </div>
          <div>
            <label>Hotwords (comma separated)</label>
            <input id="hotwords" type="text" placeholder="OpenMOSS, MLX" />
          </div>
        </div>
        <label><input id="render" type="checkbox" /> Burn ASS into MP4 (needs ffmpeg)</label>
        <button id="run">Transcribe</button>
        <button class="secondary" id="refresh">Refresh jobs</button>
      </section>
      <section>
        <h2>Result</h2>
        <pre id="result">—</pre>
      </section>
      <section>
        <h2>Jobs</h2>
        <pre id="jobs">—</pre>
      </section>
      <script>
        async function loadRuntime() {
          const r = await fetch('/api/runtime');
          document.getElementById('runtime').textContent = JSON.stringify(await r.json(), null, 2);
        }
        async function refreshJobs() {
          const r = await fetch('/api/jobs');
          document.getElementById('jobs').textContent = JSON.stringify(await r.json(), null, 2);
        }
        document.getElementById('run').onclick = async () => {
          const body = {
            path: document.getElementById('path').value,
            prompt: document.getElementById('prompt').value || undefined,
            max_new_tokens: parseInt(document.getElementById('maxTokens').value || '2048', 10),
            hotwords: (document.getElementById('hotwords').value || '').split(',').map(s => s.trim()).filter(Boolean),
            render: document.getElementById('render').checked
          };
          document.getElementById('result').textContent = 'running…';
          const r = await fetch('/api/jobs/from-path', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
          });
          const json = await r.json();
          document.getElementById('result').textContent = JSON.stringify(json, null, 2);
          refreshJobs();
        };
        document.getElementById('refresh').onclick = refreshJobs;
        loadRuntime();
        refreshJobs();
      </script>
    </body>
    </html>
    """
}
