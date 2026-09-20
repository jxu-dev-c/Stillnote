import Foundation
import MossTranscribeDiarize
import MLXAudioCore

@main
enum MossTranscribeCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(2)
        }

        // Subcommands: run (default), bench, serve, help
        if command == "help" || command == "--help" || command == "-h" {
            printUsage()
            exit(0)
        }

        if command == "bench" {
            await runBenchmark(Array(args.dropFirst()))
            return
        }
        if command == "serve" {
            await runServer(Array(args.dropFirst()))
            return
        }

        // `run` optional keyword, or treat first token as audio path
        let runArgs = (command == "run") ? Array(args.dropFirst()) : args
        await runTranscribe(runArgs)
    }

    // MARK: - Transcribe (mtd-mlx / mtd-subtitle)

    static func runTranscribe(_ args: [String]) async {
        var model = MossDefaults.recommendedModel
        var audioPath: String?
        var outDir = "runs/swift_out"
        var maxTokens = 2048
        var prompt: String?
        var hotwords: [String] = []
        var temperature: Float = 0
        var topP: Float = 1
        var topK = 0
        var prefill = 2048
        var postprocess = false
        var render = false

        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--model":
                model = requireValue(args, index: &index, flag: arg)
            case "--out-dir":
                outDir = requireValue(args, index: &index, flag: arg)
            case "--max-tokens", "--max-new-tokens":
                maxTokens = Int(requireValue(args, index: &index, flag: arg)) ?? maxTokens
            case "--prompt":
                prompt = requireValue(args, index: &index, flag: arg)
            case "--hotwords":
                hotwords = requireValue(args, index: &index, flag: arg)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "--temperature":
                temperature = Float(requireValue(args, index: &index, flag: arg)) ?? temperature
            case "--top-p":
                topP = Float(requireValue(args, index: &index, flag: arg)) ?? topP
            case "--top-k":
                topK = Int(requireValue(args, index: &index, flag: arg)) ?? topK
            case "--prefill-step-size":
                prefill = Int(requireValue(args, index: &index, flag: arg)) ?? prefill
            case "--postprocess":
                postprocess = true
            case "--render":
                render = true
            case let value where !value.hasPrefix("-"):
                audioPath = value
            default:
                fputs("Unknown argument: \(arg)\n", stderr)
                printUsage()
                exit(2)
            }
            index += 1
        }

        guard let audioPath else {
            fputs("Missing audio path.\n", stderr)
            printUsage()
            exit(2)
        }

        do {
            print("Loading model: \(model)")
            let loaded = try await ModelLoader.load(model)
            let inputURL = URL(fileURLWithPath: (audioPath as NSString).expandingTildeInPath)
            let outURL = URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath, isDirectory: true)

            let parameters = GenerateParameters(
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP,
                topK: topK,
                prefillStepSize: prefill,
                prompt: prompt,
                hotwords: hotwords
            )
            let options = PipelineOptions(
                parameters: parameters,
                postprocessSubtitles: postprocess,
                burnSubtitles: render
            )

            print("Transcribing…")
            let artifacts = try TranscribePipeline(model: loaded).run(
                inputURL: inputURL,
                outDirectory: outURL,
                options: options
            )

            print(artifacts.result.text)
            print()
            if let data = try? JSONSerialization.data(
                withJSONObject: artifacts.summary,
                options: [.prettyPrinted, .sortedKeys]
            ), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    // MARK: - Benchmark

    static func runBenchmark(_ args: [String]) async {
        var model = MossDefaults.recommendedModel
        var input: String?
        var outDir = "runs/swift_bench"
        var maxTokens = 2048
        var prompt: String?
        var temperature: Float = 0
        var topP: Float = 1
        var topK = 0
        var limit: Int?
        var keepGoing = true

        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--model":
                model = requireValue(args, index: &index, flag: arg)
            case "--input":
                input = requireValue(args, index: &index, flag: arg)
            case "--out-dir":
                outDir = requireValue(args, index: &index, flag: arg)
            case "--max-new-tokens", "--max-tokens":
                maxTokens = Int(requireValue(args, index: &index, flag: arg)) ?? maxTokens
            case "--prompt":
                prompt = requireValue(args, index: &index, flag: arg)
            case "--temperature":
                temperature = Float(requireValue(args, index: &index, flag: arg)) ?? temperature
            case "--top-p":
                topP = Float(requireValue(args, index: &index, flag: arg)) ?? topP
            case "--top-k":
                topK = Int(requireValue(args, index: &index, flag: arg)) ?? topK
            case "--limit":
                limit = Int(requireValue(args, index: &index, flag: arg))
            case "--no-keep-going":
                keepGoing = false
            default:
                fputs("Unknown bench argument: \(arg)\n", stderr)
                printUsage()
                exit(2)
            }
            index += 1
        }

        guard let input else {
            fputs("bench requires --input\n", stderr)
            exit(2)
        }

        do {
            let loaded = try await ModelLoader.load(model)
            let inputURL = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
            var samples = try BenchmarkRunner.loadSamples(from: inputURL)
            if let limit { samples = Array(samples.prefix(limit)) }
            let outURL = URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath, isDirectory: true)
            let parameters = GenerateParameters(
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP,
                topK: topK,
                prompt: prompt
            )
            let payload = try BenchmarkRunner.run(
                model: loaded,
                samples: samples,
                outDirectory: outURL,
                parameters: parameters,
                keepGoing: keepGoing
            )
            if let speed = payload["speed"],
               let data = try? JSONSerialization.data(withJSONObject: speed, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            print("Wrote benchmark outputs to \(outURL.path)")
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    // MARK: - Serve (mtd-subtitle-web)

    static func runServer(_ args: [String]) async {
        var model = MossDefaults.recommendedModel
        var host = "127.0.0.1"
        var port: UInt16 = 7860
        var runsDir = "runs/swift_web"
        var maxTokens = 2048
        var postprocess = false

        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--model":
                model = requireValue(args, index: &index, flag: arg)
            case "--host":
                host = requireValue(args, index: &index, flag: arg)
            case "--port":
                port = UInt16(requireValue(args, index: &index, flag: arg)) ?? port
            case "--runs-dir":
                runsDir = requireValue(args, index: &index, flag: arg)
            case "--max-new-tokens", "--max-tokens":
                maxTokens = Int(requireValue(args, index: &index, flag: arg)) ?? maxTokens
            case "--postprocess":
                postprocess = true
            default:
                fputs("Unknown serve argument: \(arg)\n", stderr)
                printUsage()
                exit(2)
            }
            index += 1
        }

        do {
            let configuration = LocalStudioServer.Configuration(
                modelPath: model,
                runsDirectory: URL(fileURLWithPath: (runsDir as NSString).expandingTildeInPath, isDirectory: true),
                parameters: GenerateParameters(maxTokens: maxTokens),
                postprocessSubtitles: postprocess
            )
            let server = LocalStudioServer(configuration: configuration)
            try await server.start(host: host, port: port)
            print("Open http://\(host):\(port)")
            // Keep process alive.
            while true {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    // MARK: - Helpers

    private static func requireValue(_ args: [String], index: inout Int, flag: String) -> String {
        let next = index + 1
        guard next < args.count else {
            fputs("Missing value for \(flag)\n", stderr)
            exit(2)
        }
        index = next
        return args[next]
    }

    private static func printUsage() {
        print(
            """
            moss-transcribe — full MLX MOSS-Transcribe-Diarize Swift CLI

            Commands:
              moss-transcribe <audio> [options]     Transcribe + export (mtd-mlx / mtd-subtitle)
              moss-transcribe run <audio> [options]
              moss-transcribe bench --input ...     SGLang-shaped benchmark
              moss-transcribe serve [options]       Local web studio (mtd-subtitle-web)

            Transcribe options:
              --model <path|repo>       Default: \(MossDefaults.recommendedModel)
              --out-dir <dir>           Default: runs/swift_out
              --max-new-tokens <n>      Default: 2048
              --temperature <f>         Default: 0
              --top-p <f>               Default: 1
              --top-k <n>               Default: 0
              --prefill-step-size <n>   Default: 2048
              --prompt <text>           Override default Chinese prompt
              --hotwords a,b,c          Append hotword hints
              --postprocess             Normalize subtitle timings/text
              --render                  Burn ASS into output.mp4 (ffmpeg)

            Bench options:
              --input <dir|json|jsonl|csv>
              --out-dir <dir>
              --limit <n>
              --keep-going / --no-keep-going

            Serve options:
              --host 127.0.0.1 --port 7860 --runs-dir runs/swift_web

            Python project features remain fully available via mtd-mlx / mtd-subtitle / mtd-subtitle-web.
            """
        )
    }
}
