import Foundation
import Testing

@testable import StillnoteCore

@Suite struct CommandParsingTests {
    @Test func matchesTheLongestCommandPath() throws {
        #expect(try CommandCatalog.parse(["summary", "show", "abc"]).spec.path == ["summary", "show"])
        #expect(try CommandCatalog.parse(["record", "stop"]).spec.path == ["record", "stop"])
        #expect(try CommandCatalog.parse(["list"]).spec.path == ["list"])
    }

    @Test func readsValuesInlineAndSeparately() throws {
        let inline = try CommandCatalog.parse(["list", "--limit=5", "--since", "2026-05"])
        #expect(inline.request.value("limit") == "5")
        #expect(inline.request.value("since") == "2026-05")
        #expect(try inline.request.integer("limit") == 5)
    }

    @Test func keepsBooleanFlagsSeparateFromPositionals() throws {
        let invocation = try CommandCatalog.parse(
            ["transcript", "replace", "ANE", "AEM", "--all", "--dry-run", "--ignore-case"]
        )
        #expect(invocation.request.positionals == ["ANE", "AEM"])
        #expect(invocation.request.has("all"))
        #expect(invocation.request.has("dry-run"))
        #expect(invocation.request.has("ignore-case"))
        #expect(!invocation.request.has("regex"))
    }

    /// `--json` and `--timeout` are the client's business and must not reach the app.
    @Test func stripsClientOnlyOptions() throws {
        let invocation = try CommandCatalog.parse(["list", "--json", "--timeout", "12.5"])
        #expect(invocation.wantsJSON)
        #expect(invocation.timeout == 12.5)
        #expect(invocation.request.flags.isEmpty)
        #expect(invocation.request.values.isEmpty)
    }

    @Test func treatsEverythingAfterADoubleDashAsText() throws {
        let invocation = try CommandCatalog.parse(["search", "--", "--all"])
        #expect(invocation.request.positionals == ["--all"])
    }

    @Test func rejectsUnknownOptionsAndBadValues() {
        #expect(throws: CLIError.self) { try CommandCatalog.parse(["list", "--nope"]) }
        #expect(throws: CLIError.self) { try CommandCatalog.parse(["list", "--limit"]) }
        #expect(throws: CLIError.self) { try CommandCatalog.parse(["list", "--all=yes"]) }
        #expect(throws: CLIError.self) { try CommandCatalog.parse(["nonsense"]) }
        #expect(throws: CLIError.self) { try CommandCatalog.parse(["list", "--timeout", "0"]) }
        let parsed = try? CommandCatalog.parse(["list", "--limit", "many"])
        #expect(throws: CLIError.self) { try parsed?.request.integer("limit") }
    }

    @Test func enforcesPositionalCounts() {
        #expect(throws: CLIError.self) { try CommandCatalog.parse(["show"]) }
        #expect(throws: CLIError.self) { try CommandCatalog.parse(["transcript", "replace", "only-one", "--all"]) }
        #expect(throws: CLIError.self) { try CommandCatalog.parse(["show", "a", "b"]) }
    }

    /// `--help` on any command routes to help rather than running it.
    @Test func divertsHelpWithoutRunningTheCommand() throws {
        let invocation = try CommandCatalog.parse(["record", "start", "--help"])
        #expect(invocation.spec.path == ["help"])
        #expect(invocation.request.positionals == ["record start"])
    }

    /// stdin is drained only by the commands that declare they read a body, so an interactive
    /// `stillnote list` never blocks on a pipe that will not close.
    @Test func readsStandardInputOnlyWhenTheCommandAsksForIt() throws {
        var reads = 0
        func body() -> String? {
            reads += 1
            return "piped"
        }
        _ = try CommandCatalog.parse(["notes", "show", "abc"], standardInput: body())
        #expect(reads == 0)
        let notes = try CommandCatalog.parse(["notes", "set", "abc", "--stdin"], standardInput: body())
        #expect(reads == 1)
        #expect(notes.request.standardInput == "piped")
    }

    @Test func everyCommandHasADistinctPathAndDocumentedPositionals() {
        let paths = CommandCatalog.commands.map(\.path)
        #expect(Set(paths.map { $0.joined(separator: " ") }).count == paths.count)
        for spec in CommandCatalog.commands {
            #expect(!spec.summary.isEmpty, "\(spec.name) needs a summary for --help")
            // An optional positional may never precede a required one.
            let optionalFirst = spec.positionals.firstIndex { $0.hasSuffix("?") }
            if let optionalFirst {
                #expect(spec.positionals[optionalFirst...].allSatisfy { $0.hasSuffix("?") })
            }
        }
    }

    @Test func requestSurvivesEncoding() throws {
        let original = CLIRequest(
            command: ["transcript", "replace"], positionals: ["a", "b"], values: ["meeting": "x"],
            flags: ["dry-run"], standardInput: nil
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CLIRequest.self, from: data) == original)
    }

    @Test func responseCarriesItsPayloadThroughEncoding() throws {
        let response = try CLIResponse.success("done", ListPayload([]))
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CLIResponse.self, from: data)
        #expect(decoded == response)
        #expect(try decoded.payload?.decoded(ListPayload.self).count == 0)
    }

    @Test func errorsCarryTheirMachineReadableCode() {
        #expect(CLIResponse.failure(CLIError.notFound("gone")).code == .notFound)
        #expect(CLIResponse.failure(CLIError.busy("wait")).code == .busy)
        #expect(CLIResponse.failure(ValidationError("nope")).code == .failed)
        #expect(CLIResponse.failure(ValidationError("nope")).message == "nope")
    }
}
