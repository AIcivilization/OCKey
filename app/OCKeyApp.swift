import AppKit
import CryptoKit
import Foundation
import Network

let ockeyPort: UInt16 = 8789
let ockeyBaseURL = "http://127.0.0.1:\(ockeyPort)"
let ockeyOpenAIBaseURL = "\(ockeyBaseURL)/v1"
let defaultModel = "opencode/minimax-m2.5-free"

struct APIKeyRecord: Codable {
    var id: String
    var name: String
    var keyHash: String
    var enabled: Bool
    var assignedModel: String?
    var createdAt: String
    var lastUsedAt: String?
}

struct VisibleKeyRecord: Codable {
    var keyId: String
    var name: String
    var key: String
    var createdAt: String
}

struct UsageRecord: Codable {
    var date: String
    var keyId: String
    var count: Int
}

struct KeyHealthRecord: Codable {
    var keyId: String
    var status: String
    var lastTestAt: String
    var durationMs: Int
    var model: String?
    var errorMessage: String?
    var successCount: Int
    var failureCount: Int
}

struct Settings: Codable {
    var defaultModel: String?
    var includeExperimentalModels: Bool?
}

struct ModelDescriptor: Codable {
    var id: String
    var displayName: String
    var free: Bool
    var experimental: Bool
}

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

final class OCKeyStore {
    let supportRoot: URL
    let runtimeBin: URL
    let dataRoot: URL
    let logsRoot: URL

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OCKey", isDirectory: true)
        supportRoot = support
        runtimeBin = support.appendingPathComponent("runtime/bin", isDirectory: true)
        dataRoot = support.appendingPathComponent("data", isDirectory: true)
        logsRoot = support.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: runtimeBin, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)
        ensureFile(keysURL, [APIKeyRecord]())
        ensureFile(visibleKeysURL, [VisibleKeyRecord]())
        ensureFile(usageURL, [UsageRecord]())
        ensureFile(healthURL, [String: KeyHealthRecord]())
        ensureFile(settingsURL, Settings(defaultModel: defaultModel, includeExperimentalModels: false))
    }

    var opencodeURL: URL {
        runtimeBin.appendingPathComponent("opencode")
    }

    var keysURL: URL { dataRoot.appendingPathComponent("keys.json") }
    var visibleKeysURL: URL { dataRoot.appendingPathComponent("visible-keys.json") }
    var usageURL: URL { dataRoot.appendingPathComponent("usage.json") }
    var healthURL: URL { dataRoot.appendingPathComponent("key-health.json") }
    var settingsURL: URL { dataRoot.appendingPathComponent("settings.json") }
    var auditURL: URL { logsRoot.appendingPathComponent("audit.jsonl") }

    func syncBundledRuntime() {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("bin/opencode"),
              FileManager.default.isExecutableFile(atPath: source.path) else {
            return
        }
        let destination = opencodeURL
        let sourceSize = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value
        let destinationSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
        guard sourceSize != destinationSize || !FileManager.default.fileExists(atPath: destination.path) else {
            return
        }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    func readKeys() -> [APIKeyRecord] { read(keysURL, fallback: []) }
    func writeKeys(_ keys: [APIKeyRecord]) { write(keysURL, keys) }
    func readVisibleKeys() -> [VisibleKeyRecord] { read(visibleKeysURL, fallback: []) }
    func writeVisibleKeys(_ keys: [VisibleKeyRecord]) { write(visibleKeysURL, keys) }
    func readUsage() -> [UsageRecord] { read(usageURL, fallback: []) }
    func writeUsage(_ usage: [UsageRecord]) { write(usageURL, usage) }
    func readHealth() -> [String: KeyHealthRecord] { read(healthURL, fallback: [:]) }
    func writeHealth(_ health: [String: KeyHealthRecord]) { write(healthURL, health) }
    func readSettings() -> Settings { read(settingsURL, fallback: Settings(defaultModel: defaultModel, includeExperimentalModels: false)) }
    func writeSettings(_ settings: Settings) { write(settingsURL, settings) }

    func createKey(name: String, assignedModel: String?) -> (String, APIKeyRecord) {
        let key = "ockey_" + Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64URLEncodedString()
        var keys = readKeys()
        let record = APIKeyRecord(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "OCKey Channel" : name,
            keyHash: sha256(key),
            enabled: true,
            assignedModel: assignedModel?.isEmpty == false ? assignedModel : nil,
            createdAt: isoNow(),
            lastUsedAt: nil
        )
        keys.append(record)
        writeKeys(keys)
        var visible = readVisibleKeys()
        visible.append(VisibleKeyRecord(keyId: record.id, name: record.name, key: key, createdAt: record.createdAt))
        writeVisibleKeys(visible)
        return (key, record)
    }

    func deleteKey(id: String) {
        writeKeys(readKeys().filter { $0.id != id })
        writeVisibleKeys(readVisibleKeys().filter { $0.keyId != id })
        var health = readHealth()
        health.removeValue(forKey: id)
        writeHealth(health)
    }

    func setKeyModel(id: String, model: String?) {
        var keys = readKeys()
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return }
        keys[index].assignedModel = model?.isEmpty == false ? model : nil
        writeKeys(keys)
    }

    func authenticate(_ bearer: String?) -> APIKeyRecord? {
        guard let token = bearer?.bearerToken else { return nil }
        var keys = readKeys()
        guard let index = keys.firstIndex(where: { $0.enabled && $0.keyHash == sha256(token) }) else { return nil }
        keys[index].lastUsedAt = isoNow()
        let key = keys[index]
        writeKeys(keys)
        return key
    }

    func consumeUsage(keyId: String) {
        let today = String(isoNow().prefix(10))
        var usage = readUsage()
        if let index = usage.firstIndex(where: { $0.date == today && $0.keyId == keyId }) {
            usage[index].count += 1
        } else {
            usage.append(UsageRecord(date: today, keyId: keyId, count: 1))
        }
        writeUsage(usage)
    }

    func visibleKey(id: String) -> String? {
        readVisibleKeys().first(where: { $0.keyId == id })?.key
    }

    func audit(_ item: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: item),
              let line = String(data: data, encoding: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: auditURL) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? (line + "\n").write(to: auditURL, atomically: true, encoding: .utf8)
        }
    }

    private func ensureFile<T: Encodable>(_ url: URL, _ value: T) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        write(url, value)
    }

    private func read<T: Decodable>(_ url: URL, fallback: T) -> T {
        guard let data = try? Data(contentsOf: url),
              let value = try? decoder.decode(T.self, from: data) else { return fallback }
        return value
    }

    private func write<T: Encodable>(_ url: URL, _ value: T) {
        guard let data = try? encoder.encode(value) else { return }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try? data.write(to: tmp, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: tmp, to: url)
    }
}

final class OpenCodeRuntime {
    private let store: OCKeyStore
    private var modelCache: (expiresAt: Date, models: [ModelDescriptor], error: String?)?

    init(store: OCKeyStore) {
        self.store = store
    }

    func status() -> [String: Any] {
        let exists = FileManager.default.isExecutableFile(atPath: store.opencodeURL.path)
        let version = (try? run(["--version"], timeout: 5).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        var models: [ModelDescriptor] = []
        var statusError: String?
        do {
            models = try listModels(force: false)
        } catch let caught {
            statusError = caught.localizedDescription
        }
        return [
            "available": exists,
            "path": store.opencodeURL.path,
            "version": version,
            "authenticated": !models.isEmpty && statusError == nil,
            "error": statusError as Any
        ].compactValues()
    }

    func listModels(force: Bool) throws -> [ModelDescriptor] {
        if !force, let cache = modelCache, cache.expiresAt > Date(), cache.error == nil {
            return cache.models
        }
        let settings = store.readSettings()
        do {
            let output = try run(["models", "opencode"], timeout: 20)
            let includeExperimental = settings.includeExperimentalModels == true
            var models = output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("opencode/") }
                .map { id in
                    ModelDescriptor(
                        id: id,
                        displayName: shortModelName(id),
                        free: isFreeModel(id),
                        experimental: isExperimentalModel(id)
                    )
                }
                .filter { $0.free || (includeExperimental && $0.experimental) }
            if models.isEmpty {
                models = [ModelDescriptor(id: defaultModel, displayName: shortModelName(defaultModel), free: true, experimental: false)]
            }
            models.sort { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
            modelCache = (Date().addingTimeInterval(300), models, nil)
            return models
        } catch {
            if let cache = modelCache, !cache.models.isEmpty {
                modelCache = (Date().addingTimeInterval(60), cache.models, error.localizedDescription)
                return cache.models
            }
            throw error
        }
    }

    func refreshModels() throws -> [ModelDescriptor] {
        modelCache = nil
        return try listModels(force: true)
    }

    func generate(model: String, messages: [[String: Any]], timeout: Int = 180) throws -> String {
        let prompt = messages.map { message -> String in
            let role = (message["role"] as? String) ?? "user"
            let content = normalizeContent(message["content"])
            if role == "system" { return "System:\n\(content)" }
            if role == "assistant" { return "Assistant:\n\(content)" }
            return content
        }.joined(separator: "\n\n")
        let output = try run(["run", "--model", model, "--format", "json", prompt], timeout: timeout)
        let text = extractOpenCodeText(output)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OCKeyError("OpenCode returned no assistant content")
        }
        return text
    }

    func openLoginInTerminal() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("ockey-opencode-login-\(UUID().uuidString).command")
        let source = """
        #!/bin/zsh
        clear
        echo "OCKey OpenCode Login"
        echo "This uses OCKey's bundled OpenCode CLI."
        echo
        \(shellQuote(store.opencodeURL.path)) auth login
        echo
        echo "Login finished. You can close this window and return to OCKey."
        read -k 1 "?Press any key to close..."
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", script.path]
        try process.run()
    }

    func checkUpdate() -> [String: Any] {
        let version = (try? run(["--version"], timeout: 5).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown"
        return [
            "currentVersion": version,
            "message": "Manual update is available through a future OCKey release. OCKey does not silently update the bundled OpenCode runtime."
        ]
    }

    private func run(_ args: [String], timeout: Int) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: store.opencodeURL.path) else {
            throw OCKeyError("Bundled OpenCode runtime is missing")
        }
        let process = Process()
        process.executableURL = store.opencodeURL
        process.arguments = args
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = opencodeEnvironment(cliPath: store.opencodeURL.path)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + .seconds(timeout)) == .timedOut {
            process.terminate()
            throw OCKeyError("OpenCode timed out after \(timeout)s")
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw OCKeyError("OpenCode exited with code \(process.terminationStatus): \(preview(error.isEmpty ? output : error))")
        }
        return output
    }
}

final class OCKeyServer {
    private let store: OCKeyStore
    private let runtime: OpenCodeRuntime
    private var listener: NWListener?

    init(store: OCKeyStore, runtime: OpenCodeRuntime) {
        self.store = store
        self.runtime = runtime
    }

    func start() throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: ockeyPort)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func state() -> [String: Any] {
        let models = (try? runtime.listModels(force: false)) ?? []
        let keys = publicKeys()
        let health = store.readHealth()
        let recommended = keys
            .compactMap { key -> [String: Any]? in
                guard let h = health[key["id"] as? String ?? ""], healthLevel(h) == "ok" else { return nil }
                return ["name": key["name"] ?? "", "durationMs": h.durationMs, "model": h.model ?? ""]
            }
            .sorted { (($0["durationMs"] as? Int) ?? Int.max) < (($1["durationMs"] as? Int) ?? Int.max) }
            .first
        return [
            "ok": true,
            "service": "OCKey",
            "baseUrl": ockeyBaseURL,
            "openAIBaseUrl": ockeyOpenAIBaseURL,
            "defaultModel": currentDefaultModel(models: models),
            "models": models.map { modelObject($0) },
            "availableModels": models.map(\.id),
            "opencodeStatus": runtime.status(),
            "keys": keys,
            "keyHealth": health.mapValues { healthObject($0) },
            "recommendedKey": recommended as Any,
            "settings": settingsObject(store.readSettings()),
            "dataDir": store.dataRoot.path,
            "runtimePath": store.opencodeURL.path
        ].compactValues()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }
            if let request = parseHTTPRequest(nextBuffer) {
                let response = self.route(request)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: nextBuffer)
        }
    }

    private func route(_ request: HTTPRequest) -> Data {
        do {
            if request.method == "OPTIONS" { return httpResponse(status: 204, body: Data()) }
            if request.method == "GET", request.path == "/" { return redirect("/admin/ui") }
            if request.method == "GET", request.path == "/admin/ui" { return html(adminHTML()) }
            if request.method == "GET", request.path == "/health" { return json(state()) }
            if request.method == "GET", request.path == "/admin/state" { return json(state()) }
            if request.method == "POST", request.path == "/admin/keys" { return try createKey(request) }
            if request.method == "POST", request.path == "/admin/delete-key" { return try deleteKey(request) }
            if request.method == "POST", request.path == "/admin/key-model" { return try setKeyModel(request) }
            if request.method == "POST", request.path == "/admin/health/test" { return try testKey(request, all: false) }
            if request.method == "POST", request.path == "/admin/health/test-all" { return try testKey(request, all: true) }
            if request.method == "POST", request.path == "/admin/opencode/login" {
                try runtime.openLoginInTerminal()
                return json(["ok": true])
            }
            if request.method == "POST", request.path == "/admin/opencode/refresh-models" {
                let models = try runtime.refreshModels()
                return json(["ok": true, "models": models.map { modelObject($0) }, "state": state()])
            }
            if request.method == "POST", request.path == "/admin/opencode/check-update" {
                return json(["ok": true, "update": runtime.checkUpdate()])
            }
            if request.method == "POST", request.path == "/admin/settings" { return try updateSettings(request) }
            if request.method == "GET", request.path == "/v1/models" { return try v1Models(request) }
            if request.method == "POST", request.path == "/v1/chat/completions" { return try chatCompletions(request) }
            if request.method == "POST", request.path == "/v1/responses" { return try responses(request) }
            return jsonError(404, "not_found", "No route for \(request.method) \(request.path)")
        } catch {
            return jsonError(500, "internal_error", error.localizedDescription)
        }
    }

    private func createKey(_ request: HTTPRequest) throws -> Data {
        let body = jsonBody(request)
        let name = (body["name"] as? String) ?? "OCKey Channel"
        let model = body["assignedModel"] as? String
        let (key, _) = store.createKey(name: name, assignedModel: model)
        return json(["ok": true, "key": key, "state": state()])
    }

    private func deleteKey(_ request: HTTPRequest) throws -> Data {
        let id = jsonBody(request)["keyId"] as? String ?? ""
        store.deleteKey(id: id)
        return json(["ok": true, "state": state()])
    }

    private func setKeyModel(_ request: HTTPRequest) throws -> Data {
        let body = jsonBody(request)
        let id = body["keyId"] as? String ?? ""
        let clear = (body["clear"] as? Bool) == true
        store.setKeyModel(id: id, model: clear ? nil : body["model"] as? String)
        return json(["ok": true, "state": state()])
    }

    private func updateSettings(_ request: HTTPRequest) throws -> Data {
        let body = jsonBody(request)
        var settings = store.readSettings()
        if let include = body["includeExperimentalModels"] as? Bool {
            settings.includeExperimentalModels = include
        }
        if let model = body["defaultModel"] as? String, !model.isEmpty {
            settings.defaultModel = model
        }
        store.writeSettings(settings)
        _ = try? runtime.refreshModels()
        return json(["ok": true, "state": state()])
    }

    private func testKey(_ request: HTTPRequest, all: Bool) throws -> Data {
        let body = jsonBody(request)
        let keys = store.readKeys()
        let targets = all ? keys : keys.filter { $0.id == (body["keyId"] as? String ?? "") }
        guard !targets.isEmpty else { return jsonError(404, "key_not_found", "Key not found") }
        var results: [[String: Any]] = []
        for key in targets {
            results.append(testOne(key))
        }
        return json(["ok": true, "results": results, "state": state()])
    }

    private func testOne(_ key: APIKeyRecord) -> [String: Any] {
        var health = store.readHealth()
        let previous = health[key.id]
        let started = Date()
        var record: KeyHealthRecord
        let selectedModel = selectedModel(for: key, requested: nil)
        do {
            let output = try runtime.generate(model: selectedModel, messages: [["role": "user", "content": "Reply OK only."]], timeout: 60)
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw OCKeyError("Empty response")
            }
            record = KeyHealthRecord(
                keyId: key.id,
                status: "ok",
                lastTestAt: isoNow(),
                durationMs: elapsedMs(started),
                model: selectedModel,
                errorMessage: nil,
                successCount: (previous?.successCount ?? 0) + 1,
                failureCount: previous?.failureCount ?? 0
            )
        } catch {
            record = KeyHealthRecord(
                keyId: key.id,
                status: "error",
                lastTestAt: isoNow(),
                durationMs: elapsedMs(started),
                model: selectedModel,
                errorMessage: preview(error.localizedDescription),
                successCount: previous?.successCount ?? 0,
                failureCount: (previous?.failureCount ?? 0) + 1
            )
        }
        health[key.id] = record
        store.writeHealth(health)
        store.audit(["timestamp": record.lastTestAt, "route": "/admin/health/test", "keyId": key.id, "model": selectedModel, "ok": record.status == "ok", "durationMs": record.durationMs, "error": record.errorMessage as Any].compactValues())
        return healthObject(record)
    }

    private func v1Models(_ request: HTTPRequest) throws -> Data {
        guard store.authenticate(request.headers["authorization"]) != nil else {
            return jsonError(401, "unauthorized", "Missing or invalid API key")
        }
        let models = try runtime.listModels(force: false)
        return json([
            "object": "list",
            "data": models.map { ["id": $0.id, "object": "model", "created": 0, "owned_by": "opencode"] }
        ])
    }

    private func chatCompletions(_ request: HTTPRequest) throws -> Data {
        guard let key = store.authenticate(request.headers["authorization"]) else {
            return jsonError(401, "unauthorized", "Missing or invalid API key")
        }
        let body = jsonBody(request)
        if (body["stream"] as? Bool) == true {
            return jsonError(400, "stream_not_supported", "stream=true is not supported in OCKey 1.0")
        }
        let requested = body["model"] as? String
        let model = selectedModel(for: key, requested: requested)
        let messages = body["messages"] as? [[String: Any]] ?? [["role": "user", "content": ""]]
        let started = Date()
        let content = try runtime.generate(model: model, messages: messages)
        store.consumeUsage(keyId: key.id)
        store.audit(["timestamp": isoNow(), "route": "/v1/chat/completions", "keyId": key.id, "model": model, "durationMs": elapsedMs(started), "ok": true])
        return json([
            "id": "chatcmpl-\(UUID().uuidString)",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": content],
                "finish_reason": "stop"
            ]],
            "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0]
        ])
    }

    private func responses(_ request: HTTPRequest) throws -> Data {
        guard let key = store.authenticate(request.headers["authorization"]) else {
            return jsonError(401, "unauthorized", "Missing or invalid API key")
        }
        let body = jsonBody(request)
        let model = selectedModel(for: key, requested: body["model"] as? String)
        let input = normalizeContent(body["input"])
        let messages = [["role": "user", "content": input]]
        let started = Date()
        let content = try runtime.generate(model: model, messages: messages)
        store.consumeUsage(keyId: key.id)
        store.audit(["timestamp": isoNow(), "route": "/v1/responses", "keyId": key.id, "model": model, "durationMs": elapsedMs(started), "ok": true])
        let id = "resp-\(UUID().uuidString)"
        return json([
            "id": id,
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": "completed",
            "model": model,
            "output": [[
                "id": "msg-\(UUID().uuidString)",
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [["type": "output_text", "text": content]]
            ]],
            "output_text": content,
            "usage": ["input_tokens": 0, "output_tokens": 0, "total_tokens": 0]
        ])
    }

    private func selectedModel(for key: APIKeyRecord, requested: String?) -> String {
        key.assignedModel ?? requested ?? currentDefaultModel(models: (try? runtime.listModels(force: false)) ?? [])
    }

    private func currentDefaultModel(models: [ModelDescriptor]) -> String {
        let configured = store.readSettings().defaultModel ?? defaultModel
        if models.contains(where: { $0.id == configured }) { return configured }
        return models.first?.id ?? defaultModel
    }

    private func publicKeys() -> [[String: Any]] {
        let visibleById = Dictionary(uniqueKeysWithValues: store.readVisibleKeys().map { ($0.keyId, $0.key) })
        let usage = store.readUsage()
        let today = String(isoNow().prefix(10))
        return store.readKeys().map { key in
            let count = usage.first(where: { $0.date == today && $0.keyId == key.id })?.count ?? 0
            return [
                "id": key.id,
                "name": key.name,
                "enabled": key.enabled,
                "assignedModel": key.assignedModel as Any,
                "createdAt": key.createdAt,
                "lastUsedAt": key.lastUsedAt as Any,
                "key": visibleById[key.id] as Any,
                "todayUsage": count
            ].compactValues()
        }
    }
}

final class OCKeyApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = OCKeyStore()
    private lazy var runtime = OpenCodeRuntime(store: store)
    private lazy var server = OCKeyServer(store: store, runtime: runtime)
    private var timer: Timer?
    private var lastState: [String: Any] = [:]
    private var showKeysInMenu = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.syncBundledRuntime()
        configureStatusItem()
        do {
            try server.start()
        } catch {
            showAlert("OCKey failed to start", error.localizedDescription)
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func configureStatusItem() {
        if let image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: "OCKey") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = "OK"
        }
        rebuildMenu()
    }

    private func refresh() {
        lastState = server.state()
        statusItem.button?.toolTip = titleText()
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(disabledItem(titleText()))
        menu.addItem(disabledItem(recommendedText()))
        menu.addItem(actionItem("打开控制台", #selector(openConsole)))
        menu.addItem(actionItem("复制 Base URL", #selector(copyBaseURL)))
        menu.addItem(actionItem("生成新 Key", #selector(generateKey)))
        menu.addItem(actionItem("刷新状态", #selector(refreshAction)))
        menu.addItem(NSMenuItem.separator())
        let channelsRoot = NSMenuItem(title: "全部 Key / 通道", action: nil, keyEquivalent: "")
        channelsRoot.submenu = allKeysMenu()
        menu.addItem(channelsRoot)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("开始登录 OpenCode", #selector(startLogin)))
        menu.addItem(actionItem("刷新模型", #selector(refreshModels)))
        menu.addItem(actionItem("检查 OpenCode 更新", #selector(checkUpdate)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("打开日志目录", #selector(openLogs)))
        menu.addItem(actionItem("打开数据目录", #selector(openData)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem("退出", #selector(quit)))
        statusItem.menu = menu
    }

    private func allKeysMenu() -> NSMenu {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: showKeysInMenu ? "隐藏完整 Key" : "显示完整 Key", action: #selector(toggleShowKeysInMenu), keyEquivalent: "")
        toggle.target = self
        toggle.state = showKeysInMenu ? .on : .off
        menu.addItem(toggle)
        menu.addItem(NSMenuItem.separator())

        let keys = lastState["keys"] as? [[String: Any]] ?? []
        guard !keys.isEmpty else {
            menu.addItem(disabledItem("还没有 Key，先生成一个"))
            return menu
        }

        for key in keys {
            guard let id = key["id"] as? String else { continue }
            let item = NSMenuItem(title: keyMenuTitle(key), action: nil, keyEquivalent: "")
            item.submenu = keyDetailMenu(keyId: id, key: key)
            menu.addItem(item)
        }
        return menu
    }

    private func keyDetailMenu(keyId: String, key: [String: Any]) -> NSMenu {
        let menu = NSMenu()
        let rawKey = key["key"] as? String ?? ""
        let assignedModel = key["assignedModel"] as? String ?? (lastState["defaultModel"] as? String ?? defaultModel)
        let usage = key["todayUsage"] as? Int ?? 0
        menu.addItem(disabledItem("模型：\(assignedModel)"))
        menu.addItem(disabledItem("今日：\(usage) 次"))
        menu.addItem(disabledItem("Key：\(showKeysInMenu ? rawKey : mask(rawKey))"))
        if let health = healthForKey(keyId), let error = health["errorMessage"] as? String, !error.isEmpty {
            menu.addItem(disabledItem("错误：\(error)"))
        }
        menu.addItem(NSMenuItem.separator())

        let copyItem = actionItem("复制 Key + URL", #selector(copyKeyAndURL(_:)))
        copyItem.representedObject = keyId
        menu.addItem(copyItem)
        let copyKeyItem = actionItem("只复制 Key", #selector(copyOnlyKey(_:)))
        copyKeyItem.representedObject = keyId
        menu.addItem(copyKeyItem)
        let testItem = actionItem("测试此通道", #selector(testKeyFromMenu(_:)))
        testItem.representedObject = keyId
        menu.addItem(testItem)
        return menu
    }

    private func keyMenuTitle(_ key: [String: Any]) -> String {
        let id = key["id"] as? String ?? ""
        let name = key["name"] as? String ?? "OCKey Channel"
        let model = ((key["assignedModel"] as? String) ?? (lastState["defaultModel"] as? String ?? defaultModel))
            .replacingOccurrences(of: "opencode/", with: "")
        let health = healthForKey(id)
        return "\(name) · \(model) · \(healthText(health)) · \(speedText(health))"
    }

    private func healthForKey(_ id: String) -> [String: Any]? {
        let health = lastState["keyHealth"] as? [String: Any] ?? [:]
        return health[id] as? [String: Any]
    }

    private func healthText(_ health: [String: Any]?) -> String {
        guard let health else { return "未知" }
        switch health["level"] as? String {
        case "ok": return "可用"
        case "warn": return "不稳定"
        case "bad": return "异常"
        default: return "未知"
        }
    }

    private func speedText(_ health: [String: Any]?) -> String {
        guard let value = health?["durationMs"] as? Int else { return "-" }
        let seconds = Double(value) / 1000.0
        return seconds >= 10 ? String(format: "%.1fs", seconds) : String(format: "%.2fs", seconds)
    }

    private func titleText() -> String {
        let keys = lastState["keys"] as? [[String: Any]] ?? []
        let health = lastState["keyHealth"] as? [String: Any] ?? [:]
        let okCount = keys.filter { key in
            guard let id = key["id"] as? String, let item = health[id] as? [String: Any] else { return false }
            return (item["level"] as? String) == "ok"
        }.count
        let opencode = lastState["opencodeStatus"] as? [String: Any] ?? [:]
        if (opencode["authenticated"] as? Bool) != true {
            return "● OCKey 需处理 · OpenCode 未登录"
        }
        return "● OCKey 运行中 · \(okCount) 可用"
    }

    private func recommendedText() -> String {
        guard let rec = lastState["recommendedKey"] as? [String: Any],
              let name = rec["name"] as? String else {
            return "推荐：无"
        }
        let ms = rec["durationMs"] as? Int
        let speed = ms.map { String(format: "%.1fs", Double($0) / 1000.0) } ?? "-"
        return "推荐：\(name) · \(speed)"
    }

    @objc private func openConsole() {
        NSWorkspace.shared.open(URL(string: "\(ockeyBaseURL)/admin/ui")!)
    }

    @objc private func copyBaseURL() {
        copy(ockeyOpenAIBaseURL)
    }

    @objc private func generateKey() {
        let (key, _) = store.createKey(name: "OCKey Channel", assignedModel: nil)
        copy("OPENAI_BASE_URL=\(ockeyOpenAIBaseURL)\nOPENAI_API_KEY=\(key)")
        refresh()
        showAlert("已生成并复制", "Key + URL 已复制，可以直接粘贴到产品里。")
    }

    @objc private func refreshAction() { refresh() }

    @objc private func toggleShowKeysInMenu() {
        showKeysInMenu.toggle()
        rebuildMenu()
    }

    @objc private func copyKeyAndURL(_ sender: NSMenuItem) {
        guard let keyId = sender.representedObject as? String,
              let key = visibleKeyForMenu(keyId) else { return }
        copy("OPENAI_BASE_URL=\(ockeyOpenAIBaseURL)\nOPENAI_API_KEY=\(key)")
    }

    @objc private func copyOnlyKey(_ sender: NSMenuItem) {
        guard let keyId = sender.representedObject as? String,
              let key = visibleKeyForMenu(keyId) else { return }
        copy(key)
    }

    @objc private func testKeyFromMenu(_ sender: NSMenuItem) {
        guard let keyId = sender.representedObject as? String,
              let key = store.readKeys().first(where: { $0.id == keyId }) else { return }
        _ = serverTestOneForMenu(key)
        refresh()
    }

    @objc private func startLogin() {
        do {
            try runtime.openLoginInTerminal()
        } catch {
            showAlert("无法打开登录", error.localizedDescription)
        }
    }

    @objc private func refreshModels() {
        do {
            _ = try runtime.refreshModels()
            refresh()
        } catch {
            showAlert("刷新模型失败", error.localizedDescription)
        }
    }

    @objc private func checkUpdate() {
        let update = runtime.checkUpdate()
        showAlert("OpenCode 更新", update["message"] as? String ?? "当前版本：\(update["currentVersion"] ?? "unknown")")
    }

    @objc private func openLogs() { NSWorkspace.shared.open(store.logsRoot) }
    @objc private func openData() { NSWorkspace.shared.open(store.dataRoot) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func visibleKeyForMenu(_ keyId: String) -> String? {
        store.visibleKey(id: keyId)
    }

    private func serverTestOneForMenu(_ key: APIKeyRecord) -> Bool {
        var health = store.readHealth()
        let previous = health[key.id]
        let started = Date()
        let model = key.assignedModel ?? (lastState["defaultModel"] as? String ?? defaultModel)
        let record: KeyHealthRecord
        do {
            let output = try runtime.generate(model: model, messages: [["role": "user", "content": "Reply OK only."]], timeout: 60)
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw OCKeyError("Empty response")
            }
            record = KeyHealthRecord(
                keyId: key.id,
                status: "ok",
                lastTestAt: isoNow(),
                durationMs: elapsedMs(started),
                model: model,
                errorMessage: nil,
                successCount: (previous?.successCount ?? 0) + 1,
                failureCount: previous?.failureCount ?? 0
            )
        } catch {
            record = KeyHealthRecord(
                keyId: key.id,
                status: "error",
                lastTestAt: isoNow(),
                durationMs: elapsedMs(started),
                model: model,
                errorMessage: preview(error.localizedDescription),
                successCount: previous?.successCount ?? 0,
                failureCount: (previous?.failureCount ?? 0) + 1
            )
        }
        health[key.id] = record
        store.writeHealth(health)
        return record.status == "ok"
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func mask(_ key: String) -> String {
        guard key.count > 18 else { return "......" }
        return "\(key.prefix(10))......\(key.suffix(6))"
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
}

func adminHTML() -> String {
    #"""
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OCKey</title>
  <style>
    :root { color-scheme: light dark; font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; background: Canvas; color: CanvasText; }
    main { max-width: 1100px; margin: 0 auto; padding: 24px 16px 56px; }
    header { display: flex; justify-content: space-between; gap: 12px; align-items: center; border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent); padding-bottom: 14px; }
    h1 { margin: 0; font-size: 27px; }
    h2 { margin: 0; font-size: 17px; }
    .muted, .meta { color: color-mix(in srgb, CanvasText 62%, transparent); }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 10px; margin: 16px 0; }
    .card, .row { border: 1px solid color-mix(in srgb, CanvasText 15%, transparent); border-radius: 8px; background: color-mix(in srgb, Canvas 94%, CanvasText 6%); padding: 10px; }
    .card { display: grid; gap: 3px; }
    .dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; background: #8a8f98; margin-right: 6px; }
    .ok .dot { background: #12805c; } .bad .dot { background: #b42318; } .warn .dot { background: #b7791f; }
    .section { padding: 18px 0; border-bottom: 1px solid color-mix(in srgb, CanvasText 10%, transparent); }
    .head, .connection, .actions { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
    .head { justify-content: space-between; margin-bottom: 12px; }
    .connection { display: grid; grid-template-columns: auto minmax(260px, 1fr) minmax(230px, .8fr) auto; }
    input, select, button { min-height: 34px; border: 1px solid color-mix(in srgb, CanvasText 22%, transparent); border-radius: 6px; background: Canvas; color: CanvasText; padding: 6px 9px; font: inherit; }
    button { cursor: pointer; }
    button:hover { background: color-mix(in srgb, CanvasText 8%, Canvas); }
    ul { list-style: none; padding: 0; margin: 0; display: grid; gap: 8px; }
    .row { display: grid; grid-template-columns: minmax(230px, 1.2fr) minmax(140px, .7fr) minmax(360px, 1.5fr); gap: 10px; align-items: center; }
    .title { font-weight: 700; overflow-wrap: anywhere; }
    .metrics { display: grid; grid-template-columns: repeat(4, auto); gap: 8px; white-space: nowrap; color: color-mix(in srgb, CanvasText 65%, transparent); }
    .key { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; overflow-wrap: anywhere; color: color-mix(in srgb, CanvasText 58%, transparent); }
    details { padding: 18px 0; border-bottom: 1px solid color-mix(in srgb, CanvasText 10%, transparent); }
    summary { cursor: pointer; font-weight: 700; font-size: 17px; }
    details > *:not(summary) { margin-top: 12px; }
    .error { color: #b42318; font-size: 12px; }
    @media (max-width: 780px) { .connection, .row { grid-template-columns: 1fr; } .metrics { grid-template-columns: repeat(2, auto); justify-content: start; } }
  </style>
</head>
<body>
  <main>
    <header>
      <div><h1>OCKey</h1><div class="muted">OpenCode 免费模型 Key 网关</div></div>
      <div class="actions"><button id="refresh">刷新</button><button id="login">开始登录</button></div>
    </header>

    <section class="grid" id="status"></section>

    <section class="section">
      <div class="connection">
        <h2>连接</h2>
        <input id="baseUrl" readonly>
        <input id="defaultModel" readonly>
        <button id="copyBase">复制 Base URL</button>
      </div>
    </section>

    <section class="section">
      <div class="head">
        <h2>通道管理</h2>
        <div class="actions">
          <input id="newName" placeholder="通道名称">
          <select id="newModel"></select>
          <button id="createKey">生成新通道</button>
          <button id="testAll">测试全部通道</button>
        </div>
      </div>
      <ul id="keys"></ul>
    </section>

    <details>
      <summary>OpenCode 运行时</summary>
      <div class="meta" id="runtime"></div>
      <div class="actions">
        <button id="refreshModels">刷新模型</button>
        <button id="checkUpdate">检查更新</button>
        <label><input id="includeExperimental" type="checkbox"> 包含实验模型</label>
      </div>
    </details>

    <details>
      <summary>模型列表</summary>
      <ul id="models"></ul>
    </details>
  </main>
  <script>
    let state = {};
    const $ = id => document.getElementById(id);
    const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    async function api(path, options = {}) {
      const res = await fetch(path, { ...options, headers: { 'content-type': 'application/json', ...(options.headers || {}) } });
      const body = await res.json();
      if (!res.ok) throw new Error(body.error?.message || res.statusText);
      return body;
    }
    async function refresh() {
      state = await api('/admin/state');
      $('baseUrl').value = state.openAIBaseUrl || '';
      $('defaultModel').value = state.defaultModel || '';
      $('includeExperimental').checked = state.settings?.includeExperimentalModels === true;
      renderStatus(); renderModels(); renderKeys(); renderRuntime();
    }
    function level(h) {
      if (!h) return 'unknown';
      if (h.status !== 'ok') return 'bad';
      if ((h.successRate ?? 1) < .8 || (h.durationMs ?? 0) >= 15000) return 'warn';
      return 'ok';
    }
    function levelText(l) { return l === 'ok' ? '可用' : l === 'warn' ? '不稳定' : l === 'bad' ? '异常' : '未知'; }
    function speed(ms) { return ms ? (ms / 1000).toFixed(ms >= 10000 ? 1 : 2) + 's' : '-'; }
    function renderStatus() {
      const keys = state.keys || [];
      const health = state.keyHealth || {};
      const ok = keys.filter(k => level(health[k.id]) === 'ok').length;
      const unstable = keys.filter(k => level(health[k.id]) === 'warn').length;
      const op = state.opencodeStatus || {};
      const cards = [
        ['OCKey', '运行中', true],
        ['OpenCode', op.authenticated ? '已登录' : '需要登录', op.authenticated],
        ['模型', (state.models || []).length + ' 个', (state.models || []).length > 0],
        ['通道', ok + '/' + keys.length + ' 可用' + (unstable ? ' · ' + unstable + ' 不稳定' : ''), keys.length === 0 || ok > 0]
      ];
      $('status').innerHTML = cards.map(c => '<div class="card '+(c[2]?'ok':'bad')+'"><b><span class="dot"></span>'+esc(c[0])+'</b><span class="meta">'+esc(c[1])+'</span></div>').join('');
    }
    function modelOptions(selected) {
      return '<option value="">默认模型</option>' + (state.models || []).map(m => '<option value="'+esc(m.id)+'" '+(m.id===selected?'selected':'')+'>'+esc(m.displayName || m.id)+(m.free?' · 免费':'')+'</option>').join('');
    }
    function renderKeys() {
      const health = state.keyHealth || {};
      $('newModel').innerHTML = modelOptions('');
      $('keys').innerHTML = (state.keys || []).map(k => {
        const h = health[k.id];
        const l = level(h);
        return '<li class="row '+l+'"><div><div class="title"><span class="dot"></span>'+esc(k.name)+'</div><div class="meta">'+esc(k.assignedModel || state.defaultModel || '默认模型')+'</div><div class="key">'+esc(k.key || '')+'</div>'+(h?.errorMessage?'<div class="error">'+esc(h.errorMessage)+'</div>':'')+'</div><div class="metrics"><b>'+levelText(l)+'</b><span>'+speed(h?.durationMs)+'</span><span>'+((h?.successRate==null)?'-':Math.round(h.successRate*100)+'%')+'</span><span>今日 '+esc(k.todayUsage || 0)+'</span></div><div class="actions"><select data-model="'+esc(k.id)+'">'+modelOptions(k.assignedModel)+'</select><button data-test="'+esc(k.id)+'">测试</button><button data-copy="'+esc(k.id)+'">复制 Key + URL</button><button data-del="'+esc(k.id)+'">删除</button></div></li>';
      }).join('') || '<li class="meta">还没有通道，先生成一个。</li>';
      document.querySelectorAll('[data-model]').forEach(el => el.onchange = () => setModel(el.dataset.model, el.value));
      document.querySelectorAll('[data-test]').forEach(el => el.onclick = () => testKey(el.dataset.test, el));
      document.querySelectorAll('[data-copy]').forEach(el => el.onclick = () => copyKey(el.dataset.copy));
      document.querySelectorAll('[data-del]').forEach(el => el.onclick = () => deleteKey(el.dataset.del));
    }
    function renderModels() {
      $('models').innerHTML = (state.models || []).map(m => '<li class="row"><div><div class="title">'+esc(m.displayName || m.id)+'</div><div class="meta">'+esc(m.id)+'</div></div><div class="metrics"><span>'+(m.free?'免费':'实验')+'</span></div></li>').join('') || '<li class="meta">暂无模型。请先登录 OpenCode。</li>';
    }
    function renderRuntime() {
      const op = state.opencodeStatus || {};
      $('runtime').textContent = '路径：' + (op.path || '-') + ' · 版本：' + (op.version || '-') + (op.error ? ' · ' + op.error : '');
    }
    async function setModel(id, model) { const r = await api('/admin/key-model', { method:'POST', body: JSON.stringify({ keyId:id, model, clear: !model }) }); state = r.state; renderKeys(); }
    async function testKey(id, button) { const old=button.textContent; button.disabled=true; button.textContent='测试中'; try { const r = await api('/admin/health/test', { method:'POST', body: JSON.stringify({ keyId:id }) }); state=r.state; renderStatus(); renderKeys(); } finally { button.disabled=false; button.textContent=old; } }
    async function deleteKey(id) { if (!confirm('删除这个通道？')) return; const r = await api('/admin/delete-key', { method:'POST', body: JSON.stringify({ keyId:id }) }); state=r.state; renderStatus(); renderKeys(); }
    function copyKey(id) { const k = (state.keys || []).find(x => x.id === id); navigator.clipboard.writeText('OPENAI_BASE_URL='+(state.openAIBaseUrl||'')+'\nOPENAI_API_KEY='+(k?.key||'')); }
    $('refresh').onclick = () => refresh().catch(e => alert(e.message));
    $('copyBase').onclick = () => navigator.clipboard.writeText(state.openAIBaseUrl || '');
    $('login').onclick = () => api('/admin/opencode/login', { method:'POST' }).then(() => alert('已打开 OpenCode 登录窗口，完成后回到这里刷新。')).catch(e => alert(e.message));
    $('createKey').onclick = () => api('/admin/keys', { method:'POST', body: JSON.stringify({ name:$('newName').value || 'OCKey Channel', assignedModel:$('newModel').value || undefined }) }).then(r => { state=r.state; navigator.clipboard.writeText('OPENAI_BASE_URL='+(state.openAIBaseUrl||'')+'\nOPENAI_API_KEY='+r.key); renderStatus(); renderKeys(); alert('已生成并复制 Key + URL'); }).catch(e => alert(e.message));
    $('testAll').onclick = () => { if (!confirm('测试全部通道会调用模型，可能消耗额度。继续吗？')) return; api('/admin/health/test-all', { method:'POST', body:'{}' }).then(r => { state=r.state; renderStatus(); renderKeys(); }).catch(e => alert(e.message)); };
    $('refreshModels').onclick = () => api('/admin/opencode/refresh-models', { method:'POST' }).then(r => { state=r.state; renderModels(); renderKeys(); renderStatus(); }).catch(e => alert(e.message));
    $('checkUpdate').onclick = () => api('/admin/opencode/check-update', { method:'POST' }).then(r => alert(r.update?.message || '当前版本：' + r.update?.currentVersion)).catch(e => alert(e.message));
    $('includeExperimental').onchange = () => api('/admin/settings', { method:'POST', body: JSON.stringify({ includeExperimentalModels:$('includeExperimental').checked }) }).then(r => { state=r.state; renderModels(); renderKeys(); }).catch(e => alert(e.message));
    refresh().catch(e => alert(e.message));
  </script>
</body>
</html>
"""#
}

func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
    guard let text = String(data: data, encoding: .utf8),
          let headerRange = text.range(of: "\r\n\r\n") else { return nil }
    let headerText = String(text[..<headerRange.lowerBound])
    let lines = headerText.components(separatedBy: "\r\n")
    guard let first = lines.first else { return nil }
    let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let sep = line.firstIndex(of: ":") else { continue }
        let key = line[..<sep].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespacesAndNewlines)
        headers[key] = value
    }
    let headerBytes = Data(text[..<headerRange.upperBound].utf8).count
    let length = Int(headers["content-length"] ?? "0") ?? 0
    guard data.count >= headerBytes + length else { return nil }
    let body = data.subdata(in: headerBytes..<(headerBytes + length))
    let url = URLComponents(string: parts[1])
    var query: [String: String] = [:]
    for item in url?.queryItems ?? [] { query[item.name] = item.value ?? "" }
    return HTTPRequest(method: parts[0], path: url?.path ?? parts[1], query: query, headers: headers, body: body)
}

func httpResponse(status: Int, contentType: String = "application/json; charset=utf-8", body: Data) -> Data {
    let reason = [200: "OK", 204: "No Content", 302: "Found", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 500: "Internal Server Error"][status] ?? "OK"
    var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nContent-Type: \(contentType)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: authorization,content-type\r\nAccess-Control-Allow-Methods: GET,POST,OPTIONS\r\nConnection: close\r\n"
    head += "\r\n"
    return Data(head.utf8) + body
}

func redirect(_ location: String) -> Data {
    let body = Data()
    let head = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    return Data(head.utf8) + body
}

func html(_ text: String) -> Data {
    httpResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(text.utf8))
}

func json(_ value: Any) -> Data {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted])) ?? Data("{}".utf8)
    return httpResponse(status: 200, body: data)
}

func jsonError(_ status: Int, _ code: String, _ message: String) -> Data {
    let data = (try? JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]], options: [.prettyPrinted])) ?? Data()
    return httpResponse(status: status, body: data)
}

func jsonBody(_ request: HTTPRequest) -> [String: Any] {
    guard !request.body.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return [:] }
    return object
}

func modelObject(_ model: ModelDescriptor) -> [String: Any] {
    ["id": model.id, "displayName": model.displayName, "free": model.free, "experimental": model.experimental]
}

func healthObject(_ health: KeyHealthRecord) -> [String: Any] {
    let total = health.successCount + health.failureCount
    let successRate: Any = total > 0 ? Double(health.successCount) / Double(total) : NSNull()
    return [
        "keyId": health.keyId,
        "status": health.status,
        "level": healthLevel(health),
        "lastTestAt": health.lastTestAt,
        "durationMs": health.durationMs,
        "model": health.model as Any,
        "errorMessage": health.errorMessage as Any,
        "successCount": health.successCount,
        "failureCount": health.failureCount,
        "successRate": successRate
    ].compactValues()
}

func settingsObject(_ settings: Settings) -> [String: Any] {
    ["defaultModel": settings.defaultModel ?? defaultModel, "includeExperimentalModels": settings.includeExperimentalModels == true]
}

func healthLevel(_ health: KeyHealthRecord) -> String {
    if health.status != "ok" { return "bad" }
    let total = health.successCount + health.failureCount
    let rate = total > 0 ? Double(health.successCount) / Double(total) : 1
    if rate < 0.8 || health.durationMs >= 15_000 { return "warn" }
    return "ok"
}

func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}

func elapsedMs(_ started: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(started) * 1000))
}

func isFreeModel(_ id: String) -> Bool {
    id.lowercased().contains("free")
}

func isExperimentalModel(_ id: String) -> Bool {
    id == "opencode/gpt-5-nano"
}

func shortModelName(_ id: String) -> String {
    id.replacingOccurrences(of: "opencode/", with: "")
}

func normalizeContent(_ value: Any?) -> String {
    if let value = value as? String { return value }
    if let parts = value as? [[String: Any]] {
        return parts.map { part in
            if let text = part["text"] as? String { return text }
            return String(describing: part)
        }.joined(separator: "\n")
    }
    if let value { return String(describing: value) }
    return ""
}

func extractOpenCodeText(_ output: String) -> String {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = trimmed.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) {
        let text = collectText(json).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
    }
    var chunks: [String] = []
    for line in output.components(separatedBy: .newlines) {
        let clean = stripANSI(line.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !clean.isEmpty else { continue }
        if let data = clean.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            let text = collectText(json)
            if !text.isEmpty { chunks.append(text) }
        } else {
            chunks.append(clean)
        }
    }
    return chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

func collectText(_ value: Any) -> String {
    if let dict = value as? [String: Any] {
        var parts: [String] = []
        for key in ["content", "text", "delta", "output"] {
            if let text = dict[key] as? String { parts.append(text) }
        }
        for key in ["message", "part"] {
            if let child = dict[key] { parts.append(collectText(child)) }
        }
        return parts.joined()
    }
    if let array = value as? [Any] {
        return array.map(collectText).joined()
    }
    return ""
}

func stripANSI(_ value: String) -> String {
    value.replacingOccurrences(of: #"\u001B\[[0-9;]*m"#, with: "", options: .regularExpression)
}

func preview(_ value: String, limit: Int = 500) -> String {
    value.count > limit ? String(value.prefix(limit)) + "..." : value
}

func opencodeEnvironment(cliPath: String) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let cliDir = URL(fileURLWithPath: cliPath).deletingLastPathComponent().path
    let path = [cliDir, env["PATH"], "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].compactMap { $0 }.joined(separator: ":")
    env["PATH"] = path
    env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
    env["TERM"] = env["TERM"] ?? "dumb"
    env["LANG"] = env["LANG"] ?? "C.UTF-8"
    return env
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct OCKeyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func + (left: Data, right: Data) -> Data {
        var data = left
        data.append(right)
        return data
    }
}

extension String {
    var bearerToken: String? {
        let parts = split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, parts[0].lowercased() == "bearer" { return parts[1] }
        return nil
    }
}

extension Dictionary where Key == String, Value == Any {
    func compactValues() -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in self {
            if !(value is NSNull) { result[key] = value }
        }
        return result
    }
}

let app = NSApplication.shared
let delegate = OCKeyApp()
app.delegate = delegate
app.run()
