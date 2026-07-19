import Foundation
import HerdrClient

@main @MainActor
enum CLI {
    static var jsonOutput = false
    static var explicitSocket: String?

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        if let i = args.firstIndex(of: "--json") { jsonOutput = true; args.remove(at: i) }
        if let i = args.firstIndex(where: { $0 == "--sock" || $0 == "--socket" }), args.indices.contains(i + 1) {
            explicitSocket = args[i + 1]; args.removeSubrange(i...i + 1)
        }
        guard let command = args.first else { usage(); return }
        let client = HerdrClient(socketPath: explicitSocket)
        do {
            switch command {
            case "resolve": guard args.count > 2 else { throw CLIError.usage("resolve requires a pane id and approve|deny|option number") }; try await resolve(client, pane: args[1], choice: args[2])
            case "list": try await list(client)
            case "read": guard args.count > 1 else { throw CLIError.usage("read requires a pane id") }; try await read(client, pane: args[1])
            case "capture": guard args.count > 1 else { throw CLIError.usage("capture requires a pane id and --output DIR") }; try await capture(client, pane: args[1], args: args)
            case "extract": guard args.count > 1 else { throw CLIError.usage("extract requires a capture directory, --annotations FILE, and --output DIR") }; try extract(capturePath: args[1], args: args)
            case "reply": guard args.count > 2 else { throw CLIError.usage("reply requires a pane id and text") }; report(try await Actions(client: client).reply(pane: args[1], text: args.dropFirst(2).joined(separator: " ")))
            case "jump": guard args.count > 1 else { throw CLIError.usage("jump requires a pane id") }; report(try await Actions(client: client).jump(pane: args[1]))
            case "watch": try await watch(client)
            default: throw CLIError.usage("unknown command: \(command)")
            }
        } catch { fputs("notchctl: \(error)\n", stderr); exit(1) }
    }

    static func list(_ client: HerdrClient) async throws {
        let result = try await client.request("session.snapshot")
        let snapshot = try (result["snapshot"] ?? result).decode(Snapshot.self)
        if jsonOutput { printJSON(result); return }
        for pane in snapshot.uniquePanes {
            print("\(pad(pane.paneID, 18)) \(pad(pane.agent ?? "—", 10)) \(pane.agentStatus.rawValue) \(pane.title ?? "")")
        }
    }

    static func read(_ client: HerdrClient, pane: String) async throws {
        let prompt = try await classify(client, pane: pane)
        if jsonOutput { printPromptJSON(prompt, pane: pane) } else { printPrompt(prompt) }
    }

    static func capture(_ client: HerdrClient, pane paneID: String,
                        args: [String]) async throws {
        guard let outputIndex = args.firstIndex(of: "--output"),
              args.indices.contains(outputIndex + 1) else {
            throw CLIError.usage("capture requires --output DIR")
        }
        let outputURL = URL(fileURLWithPath: NSString(
            string: args[outputIndex + 1]).expandingTildeInPath, isDirectory: true)
        let overwrite = args.contains("--force")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let bundle = try await PaneCapturer(client: client).capture(
            paneID: paneID, capturedAt: timestamp)
        let destination = try PaneCaptureWriter().write(bundle, to: outputURL,
                                                        overwrite: overwrite)
        print(destination.path)
        if !bundle.metadata.hasConsistentRevision {
            fputs("notchctl: warning: pane revision changed during capture\n", stderr)
        }
    }

    static func extract(capturePath: String, args: [String]) throws {
        let outputPath = try option("--output", in: args)
        let annotationsPath = try option("--annotations", in: args)
        let captureURL = fileURL(capturePath, isDirectory: true)
        let outputURL = fileURL(outputPath, isDirectory: true)
        let annotationsURL = fileURL(annotationsPath)
        let annotations = try JSONDecoder().decode(
            PaneFixtureAnnotations.self, from: Data(contentsOf: annotationsURL))
        let replacementDetection = try optionalFileData("--detection-file", in: args)
        let replacementVisible = try optionalFileData("--visible-file", in: args)
        let region = optionalOption("--from-marker", in: args).map {
            PaneFixtureRegion(startMarker: $0,
                              endMarker: optionalOption("--through-marker", in: args))
        }
        let destination = try PaneFixtureExtractor().extract(
            captureDirectory: captureURL, annotations: annotations,
            outputDirectory: outputURL, replacementDetection: replacementDetection,
            replacementVisibleANSI: replacementVisible, region: region)
        print(destination.path)
    }

    static func option(_ name: String, in args: [String]) throws -> String {
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
            throw CLIError.usage("missing required option \(name)")
        }
        return args[index + 1]
    }

    static func optionalFileData(_ name: String, in args: [String]) throws -> Data? {
        guard args.contains(name) else { return nil }
        return try Data(contentsOf: fileURL(try option(name, in: args)))
    }

    static func optionalOption(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    static func fileURL(_ path: String, isDirectory: Bool = false) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath,
            isDirectory: isDirectory)
    }

    struct InteractionContext {
        let interaction: PendingInteraction
        let agentID: String?
        let revision: UInt64?
    }

    static func classify(_ client: HerdrClient, pane: String) async throws
        -> InteractionContext {
        let snapshotResult = try await client.request("session.snapshot")
        let snapshot = try (snapshotResult["snapshot"] ?? snapshotResult).decode(Snapshot.self)
        let paneInfo = snapshot.uniquePanes.first { $0.paneID == pane }
        let interaction = try await ScreenInteractionProvider(client: client).interaction(
            paneID: pane, agentID: paneInfo?.agent, paneRevision: paneInfo?.revision)
        return InteractionContext(
            interaction: interaction, agentID: paneInfo?.agent,
            revision: paneInfo?.revision)
    }

    static func resolve(_ client: HerdrClient, pane: String, choice: String) async throws {
        let context = try await classify(client, pane: pane)
        let interaction = context.interaction
        let actions = Actions(client: client)
        let intent: InteractionResponseIntent
        switch choice.lowercased() {
        case "approve", "yes", "y": intent = .approve
        case "deny", "no", "n":
            intent = interaction.kind == .approval ? .deny : .cancel
        default:
            guard let number = Int(choice), interaction.choices.indices.contains(number - 1) else {
                throw CLIError.usage("choice must be approve|deny|<option number 1...\(interaction.choices.count)>")
            }
            intent = .selectChoice(number - 1)
        }
        let provider = ScreenInteractionProvider(client: client)
        let responder = InteractionResponder(provider: provider, actions: actions)
        _ = try await responder.respond(InteractionResponseRequest(
            paneID: pane, agentID: context.agentID,
            paneRevision: context.revision,
            expectedFingerprint: interaction.fingerprint, intent: intent))
        report(.sent)
    }

    static func watch(_ client: HerdrClient) async throws {
        let store = StateStore()
        let result = try await client.request("session.snapshot")
        let snapshot = try (result["snapshot"] ?? result).decode(Snapshot.self)
        store.hydrate(snapshot)
        let subscriptions = store.currentSubscriptions()
        for await raw in client.events(subscriptions: { subscriptions }) {
            if jsonOutput { printJSON(raw); continue }
            guard let event = EventEnvelope(raw) else { continue }
            _ = store.apply(event)
            print("\(timestamp()) \(event.event) \(event.paneID ?? "") \(event.agentStatus?.rawValue ?? "")")
        }
    }

    static func printPrompt(_ context: InteractionContext) {
        let interaction = context.interaction
        if let title = interaction.title { print(title) }
        else if let body = interaction.body { print(body) }
        for (index, option) in interaction.choices.enumerated() {
            print("  \(index + 1). \(option.label)")
        }
    }
    static func printPromptJSON(_ context: InteractionContext, pane: String) {
        let interaction = context.interaction
        printJSON(.object([
            "pane_id": .string(pane),
            "kind": .string(interaction.kind.rawValue),
            "title": interaction.title.map(JSONValue.string) ?? .null,
            "body": interaction.body.map(JSONValue.string) ?? .null,
            "provider": .string(interaction.evidence.providerID),
            "options": .array(interaction.choices.map {
                .object(["label": .string($0.label), "kind": .string($0.kind.rawValue)])
            }),
        ]))
    }
    static func report(_ result: ActionResult) {
        switch result {
        case .sent: print(jsonOutput ? "{\"result\":\"sent\"}" : "sent")
        case .jumped(let raised): print(jsonOutput ? "{\"result\":\"jumped\",\"ghostty_raised\":\(raised)}" : "jumped (Ghostty raised: \(raised))")
        case .needsAttach: print(jsonOutput ? "{\"result\":\"needs_attach\"}" : "pane is on a detached session — attach first")
        }
    }
    static func printJSON(_ value: JSONValue) {
        if let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) { print(text) }
    }
    static func pad(_ text: String, _ width: Int) -> String { text.padding(toLength: width, withPad: " ", startingAt: 0) }
    static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
    static func usage() { print("usage: notchctl [--sock PATH] [--json] <list|watch|read|capture|extract|resolve|reply|jump> …") }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { switch self { case .usage(let message): message } }
}
