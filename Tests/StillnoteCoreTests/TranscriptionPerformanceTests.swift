import Foundation
import Testing
import MLX
@testable import StillnoteCore
@testable import MossTranscribeDiarize

@Suite(.serialized)
struct TranscriptionPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STILLNOTE_BENCHMARK_RESULTS"] != nil))
    func recordedBenchmarksPassTheAppParser() throws {
        let path = try #require(ProcessInfo.processInfo.environment["STILLNOTE_BENCHMARK_RESULTS"])
        let entries = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: Any]])
        for entry in entries {
            #expect(entry["exit_code"] as? Int == 0)
            let events = try #require(entry["events"] as? [[String: Any]])
            let text = try #require(events.first { $0["type"] as? String == "result" }?["text"] as? String)
            let result = try MossParser.parse(text, duration: 5400, language: "auto")
            #expect(!result.segments.isEmpty)
            #expect(result.segments.allSatisfy { $0.end >= $0.start })
        }
    }

    @Test func modeCompatibility() throws {
        for raw in ["quality", "balanced", "low-memory", "unknown"] {
            let data = Data("{\"model\":\"moss-0.9b\",\"language\":\"auto\",\"mode\":\"\(raw)\"}".utf8)
            let settings = try JSONDecoder().decode(TranscriptionSettings.self, from: data)
            #expect(settings.mode == (TranscriptionMode(rawValue: raw) ?? .quality))
            #expect(try JSONDecoder().decode(TranscriptionSettings.self, from: JSONEncoder().encode(settings)) == settings)
        }
        let service = TranscriptionService(modelDirectory: URL(fileURLWithPath: "/models"))
        for mode in TranscriptionMode.allCases {
            let args = try service.workerArguments(pcmURL: URL(fileURLWithPath: "/audio"), model: SpeechCatalog.defaultModel,
                language: "auto", speakerCount: nil, hotWords: [], mode: mode)
            #expect(try SpeechWorkerRequest(arguments: args).mode == mode)
            #expect(args.count == (mode == .quality ? 4 : 6))
        }
        #expect(throws: Error.self) { try SpeechWorkerRequest(arguments: ["/a", "/m", "auto", "0", "[]", "bad"]) }
    }

    @Test func modePersistsAcrossSettingsChanges() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        var settings = AppSettings()
        settings.transcription.mode = .balanced
        try await store.saveSettings(settings)
        #expect(try await store.settings().transcription.mode == .balanced)
        settings.transcription.mode = .lowMemory
        try await store.saveSettings(settings)
        #expect(try await store.settings().transcription.mode == .lowMemory)
        #expect(AppSettings.migrating(from: ["transcription": ["mode": "future"]]).settings.transcription.mode == .quality)
    }

    @Test func pcmReadsBoundariesAndRejectsInvalidSamples() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var samples = [Float](repeating: 0.25, count: 480001)
        samples[480000] = -0.5
        try samples.withUnsafeBytes { try Data($0).write(to: file) }
        let source = try PCMSource(url: file)
        #expect(source.count == 480001)
        #expect(try source.read(480000..<480001).item(Float.self) == -0.5)
        #expect(try source.read(0..<480000).dim(0) == 480000)
        #expect(throws: Error.self) { try source.read(0..<480001) }
        try Data([0]).write(to: file)
        #expect(throws: Error.self) { try source.read(0..<1) }
        #expect(throws: Error.self) { try PCMSource(url: file) }
        var bad = Float.nan
        try withUnsafeBytes(of: &bad) { try Data($0).write(to: file) }
        #expect(throws: Error.self) { try PCMSource(url: file).read(0..<1) }
    }

    @Test func prefillMatchesFullForwardLastLogits() throws {
        MLXRandom.seed(123)
        let config = TextConfig(vocabSize: 64, hiddenSize: 64, intermediateSize: 128,
            numHiddenLayers: 6, numAttentionHeads: 2, numKeyValueHeads: 1, headDim: 64)
        let model = MossModel(ModelConfig(textConfig: config))
        let ids = MLXArray([Int32(1), 2, 3, 4, 5]).reshaped(1, 5)
        let embeddings = model.model.languageModel.embedTokens(ids)
        for context in [ContextCache.original, .eightBit, .fourBit] {
            let full = try model(inputIds: ids, cache: model.makeCache(context: context))
            eval(full)
            for step in [1, 2, 4] {
                let cache = model.makeCache(context: context)
                let last = try model.prefill(promptIds: ids, inputEmbeddings: embeddings, cache: cache,
                    parameters: .init(contextCache: context, prefillStepSize: step), progress: { _ in })
                #expect(MLX.abs(full[0..., -1, 0...] - last).max().item(Float.self) < (context == .original ? 0.01 : 0.1))
                #expect(cache.allSatisfy { $0.offset == 5 })
            }
        }
    }

    @Test func compressedAttentionPreservesCheckpointPrecision() throws {
        let config = TextConfig(vocabSize: 64, hiddenSize: 64, intermediateSize: 128,
            numHiddenLayers: 2, numAttentionHeads: 2, numKeyValueHeads: 1, headDim: 64)
        let model = Qwen3TextModel(config)
        model.update(parameters: model.parameters().mapValues { $0.asType(.bfloat16) })
        let cache = MossModel(ModelConfig(textConfig: config)).makeCache(context: .eightBit)
        let result = model(inputIds: MLXArray([Int32(1), 2, 3]).reshaped(1, 3), cache: cache)
        eval(result)
        #expect(result.dtype == .bfloat16)
        #expect(cache.flatMap { $0.innerState() }.filter { $0.dtype != .uint32 }.allSatisfy { $0.dtype == .bfloat16 })
    }

    @Test func attentionIsCausalAndCachesAreCompressed() throws {
        MLXRandom.seed(42)
        let config = TextConfig(vocabSize: 64, hiddenSize: 64, intermediateSize: 128,
            numHiddenLayers: 28, numAttentionHeads: 2, numKeyValueHeads: 1, headDim: 64)
        let model = Qwen3TextModel(config)
        let original = model(inputIds: MLXArray([Int32(1), 2, 3]).reshaped(1, 3))
        let changed = model(inputIds: MLXArray([Int32(1), 2, 4]).reshaped(1, 3))
        #expect(MLX.abs(original[0, 0..<2] - changed[0, 0..<2]).max().item(Float.self) < 1e-5)
        let moss = MossModel(ModelConfig(textConfig: config))
        var bytes: [Int] = []
        for context in [ContextCache.original, .eightBit, .fourBit] {
            let cache = moss.makeCache(context: context)
            let full = model(inputIds: MLXArray([Int32(1), 2, 3]).reshaped(1, 3), cache: cache)
            eval(full)
            let alternateCache = moss.makeCache(context: context)
            let alternate = model(inputIds: MLXArray([Int32(1), 2, 4]).reshaped(1, 3), cache: alternateCache)
            #expect(MLX.abs(full[0, 0..<2] - alternate[0, 0..<2]).max().item(Float.self) < 1e-5)
            let splitCache = moss.makeCache(context: context)
            _ = model(inputIds: MLXArray([Int32(1), 2]).reshaped(1, 2), cache: splitCache)
            eval(splitCache.flatMap { $0.innerState() })
            let last = model(inputIds: MLXArray([Int32(3)]).reshaped(1, 1), cache: splitCache)
            // Different attention kernels accumulate rounding through 28 layers.
            #expect(MLX.abs(full[0, 2] - last[0, 0]).max().item(Float.self) < (context == .original ? 0.005 : 0.1))
            #expect(cache.allSatisfy { $0.offset == 3 })
            bytes.append(cache.flatMap { $0.innerState() }.reduce(0) { $0 + $1.nbytes })
        }
        #expect(Double(bytes[1]) / Double(bytes[0]) < 0.65)
        #expect(Double(bytes[2]) / Double(bytes[0]) < 0.4)
        let constrained = GenerateParameters(memoryBudget: 1536 * 1024 * 1024)
        try moss.checkMemory(tokens: 16, parameters: constrained)
        #expect(throws: Error.self) { try moss.checkMemory(tokens: 100000, parameters: constrained) }
        #expect(throws: Error.self) { try moss.checkMemory(tokens: 16, parameters: .init(memoryBudget: 1024)) }
    }
}
