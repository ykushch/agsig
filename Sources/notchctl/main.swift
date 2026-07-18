import Foundation
import HerdrClient

@main @MainActor
enum CLI {
    static var jsonOutput = false
    static var explicitSocket: String?
    static let classifier = PromptClassifier()

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

    static func classify(_ client: HerdrClient, pane: String) async throws -> ClassifiedPrompt {
        let snapshotResult = try await client.request("session.snapshot")
        let snapshot = try (snapshotResult["snapshot"] ?? snapshotResult).decode(Snapshot.self)
        let agent = snapshot.uniquePanes.first { $0.paneID == pane }?.agent
        let params = try PaneReadParams(paneID: pane, source: .detection).asJSONValue()
        let result = try await client.request("pane.read", params: params)
        let text = (try? result["read"]?.decode(PaneReadResult.self))?.text ?? ""
        return classifier.classify(agent: agent, text: text)
    }

    static func resolve(_ client: HerdrClient, pane: String, choice: String) async throws {
        let prompt = try await classify(client, pane: pane)
        let actions = Actions(client: client)
        let result: ActionResult
        switch choice.lowercased() {
        case "approve", "yes", "y": result = try await actions.approve(pane: pane, prompt: prompt)
        case "deny", "no", "n": result = try await actions.deny(pane: pane, prompt: prompt)
        default:
            guard let number = Int(choice), prompt.options.indices.contains(number - 1) else {
                throw CLIError.usage("choice must be approve|deny|<option number 1...\(prompt.options.count)>")
            }
            result = try await actions.answer(pane: pane, prompt: prompt, optionIndex: number - 1)
        }
        report(result)
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

    static func printPrompt(_ prompt: ClassifiedPrompt) {
        if let title = prompt.questionTitle { print(title) } else { print(prompt.promptText) }
        for (index, option) in prompt.options.enumerated() { print("  \(index + 1). \(option.label)") }
    }
    static func printPromptJSON(_ prompt: ClassifiedPrompt, pane: String) {
        printJSON(.object(["pane_id": .string(pane), "kind": .string(prompt.kind.rawValue),
                           "question": prompt.questionTitle.map(JSONValue.string) ?? .null,
                           "options": .array(prompt.options.map { .object(["label": .string($0.label), "keys": .array($0.keysToSend.map(JSONValue.string))]) }),
                           "deny_keys": .array(prompt.denyKeys.map(JSONValue.string)), "text": .string(prompt.promptText)]))
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
    static func usage() { print("usage: notchctl [--sock PATH] [--json] <list|watch|read|resolve|reply|jump> …") }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String { switch self { case .usage(let message): message } }
}
