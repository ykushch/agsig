import Foundation

public struct OpenCodePaneDescriptor: Sendable, Equatable {
    public static let endpointToken = "opencode_url"
    public static let sessionToken = "opencode_session"
    public static let modelToken = "opencode_model"

    public let endpoint: URL
    public let sessionID: String
    public let modelID: String?

    public init?(pane: PaneInfo) {
        guard let rawEndpoint = pane.tokens?[Self.endpointToken],
              let endpoint = URL(string: rawEndpoint),
              Self.isLoopback(endpoint),
              let sessionID = pane.tokens?[Self.sessionToken]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else { return nil }
        self.endpoint = endpoint
        self.sessionID = sessionID
        self.modelID = pane.tokens?[Self.modelToken]
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme == "http", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

public actor OpenCodePaneRegistry {
    private var descriptors: [String: OpenCodePaneDescriptor] = [:]

    public init() {}

    public func replace(panes: [PaneInfo]) {
        descriptors = Dictionary(uniqueKeysWithValues: panes.compactMap { pane in
            OpenCodePaneDescriptor(pane: pane).map { (pane.paneID, $0) }
        })
    }

    public func descriptor(for paneID: String) -> OpenCodePaneDescriptor? {
        descriptors[paneID]
    }
}

public struct OpenCodePermissionRequest: Decodable, Sendable, Equatable {
    public let id: String
    public let sessionID: String
    public let permission: String
    public let title: String?
    public let patterns: [String]
    public let metadata: [String: JSONValue]
    public let always: [String]

    public init(id: String, sessionID: String, permission: String,
                title: String? = nil,
                patterns: [String], metadata: [String: JSONValue] = [:],
                always: [String] = []) {
        self.id = id
        self.sessionID = sessionID
        self.permission = permission
        self.title = title
        self.patterns = patterns
        self.metadata = metadata
        self.always = always
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, permission, type, title, patterns, pattern
        case metadata, always
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        permission = try values.decodeIfPresent(String.self, forKey: .permission)
            ?? values.decodeIfPresent(String.self, forKey: .type)
            ?? title ?? "permission"
        if let modern = try values.decodeIfPresent([String].self, forKey: .patterns) {
            patterns = modern
        } else if let legacy = try? values.decode([String].self, forKey: .pattern) {
            patterns = legacy
        } else if let legacy = try values.decodeIfPresent(String.self, forKey: .pattern) {
            patterns = [legacy]
        } else {
            patterns = []
        }
        metadata = try values.decodeIfPresent(
            [String: JSONValue].self, forKey: .metadata) ?? [:]
        always = try values.decodeIfPresent([String].self, forKey: .always)
            ?? patterns
    }
}

public enum OpenCodePermissionReply: String, Sendable, Equatable {
    case once
    case always
    case reject
}

public protocol OpenCodeNativeRequesting: Sendable {
    func pendingPermissions(
        descriptor: OpenCodePaneDescriptor
    ) async throws -> [OpenCodePermissionRequest]
    func reply(
        descriptor: OpenCodePaneDescriptor, requestID: String,
        reply: OpenCodePermissionReply
    ) async throws
}

public enum OpenCodeNativeProviderError: Error, Sendable, Equatable {
    case descriptorMissing(paneID: String)
    case noPendingPermission(paneID: String)
    case invalidResponse
    case rejectedStatus(Int)
}

public struct OpenCodeHTTPClient: OpenCodeNativeRequesting, Sendable {
    public init() {}

    public func pendingPermissions(
        descriptor: OpenCodePaneDescriptor
    ) async throws -> [OpenCodePermissionRequest] {
        let value = try await request(
            descriptor: descriptor, components: ["permission"], method: "GET")
        return try value.decode([OpenCodePermissionRequest].self)
    }

    public func reply(
        descriptor: OpenCodePaneDescriptor, requestID: String,
        reply: OpenCodePermissionReply
    ) async throws {
        do {
            _ = try await request(
                descriptor: descriptor,
                components: ["permission", requestID, "reply"], method: "POST",
                body: .object(["reply": .string(reply.rawValue)]))
        } catch OpenCodeNativeProviderError.rejectedStatus(404) {
            _ = try await request(
                descriptor: descriptor,
                components: ["session", descriptor.sessionID, "permissions", requestID],
                method: "POST",
                body: .object(["response": .string(reply.rawValue)]))
        }
    }

    private func request(
        descriptor: OpenCodePaneDescriptor, components: [String],
        method: String, body: JSONValue? = nil
    ) async throws -> JSONValue {
        var url = descriptor.endpoint
        for component in components { url.appendPathComponent(component) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try body.serialized()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeNativeProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenCodeNativeProviderError.rejectedStatus(http.statusCode)
        }
        return try JSONValue.parse(data)
    }
}

public struct OpenCodeNativeInteractionProvider: InteractionProviding, Sendable {
    public let providerID = "opencode-native"
    private let registry: OpenCodePaneRegistry
    private let client: any OpenCodeNativeRequesting

    public init(registry: OpenCodePaneRegistry,
                client: any OpenCodeNativeRequesting = OpenCodeHTTPClient()) {
        self.registry = registry
        self.client = client
    }

    public func interaction(paneID: String, agentID: String?,
                            paneRevision: UInt64?) async throws
        -> PendingInteraction {
        guard let descriptor = await registry.descriptor(for: paneID) else {
            throw OpenCodeNativeProviderError.descriptorMissing(paneID: paneID)
        }
        guard let request = try await client.pendingPermissions(
            descriptor: descriptor).last(where: { $0.sessionID == descriptor.sessionID }) else {
            throw OpenCodeNativeProviderError.noPendingPermission(paneID: paneID)
        }
        var choices = [
            InteractionChoice(label: "Allow Once", description: "Approve this request once."),
        ]
        if !request.always.isEmpty {
            choices.append(InteractionChoice(
                label: "Always Allow", description: request.always.joined(separator: "\n")))
        }
        choices.append(InteractionChoice(label: "Deny", description: "Reject this request."))
        return PendingInteraction(
            paneID: paneID, interactionID: request.id, kind: .approval,
            title: request.title ?? "OpenCode requests \(request.permission) permission",
            body: request.patterns.joined(separator: "\n"), choices: choices,
            presentation: InteractionPresentation(mechanism: .manual),
            capabilities: [.approve, .deny, .selectOne],
            evidence: InteractionEvidence(
                source: .native, providerID: providerID,
                agentID: agentID, paneRevision: paneRevision.flatMap(Int.init(exactly:)),
                confidence: .exact))
    }
}

public struct OpenCodeNativeInteractionResponder: InteractionResponding, Sendable {
    private let provider: OpenCodeNativeInteractionProvider
    private let registry: OpenCodePaneRegistry
    private let client: any OpenCodeNativeRequesting

    public init(registry: OpenCodePaneRegistry,
                client: any OpenCodeNativeRequesting = OpenCodeHTTPClient()) {
        self.registry = registry
        self.client = client
        self.provider = OpenCodeNativeInteractionProvider(
            registry: registry, client: client)
    }

    public func respond(
        _ request: InteractionResponseRequest,
        onPhase: @escaping @Sendable (InteractionResponsePhase) async -> Void
    ) async throws -> InteractionResponseResult {
        await onPhase(.revalidating)
        let fresh = try await provider.interaction(
            paneID: request.paneID, agentID: request.agentID,
            paneRevision: request.paneRevision)
        guard fresh.fingerprint == request.expectedFingerprint else {
            throw InteractionResponderError.staleInteraction(
                expected: request.expectedFingerprint, actual: fresh)
        }
        guard let descriptor = await registry.descriptor(for: request.paneID),
              let requestID = fresh.interactionID else {
            throw OpenCodeNativeProviderError.descriptorMissing(paneID: request.paneID)
        }
        let reply = try Self.reply(for: request.intent, interaction: fresh)
        await onPhase(.sending)
        try await client.reply(
            descriptor: descriptor, requestID: requestID, reply: reply)
        await onPhase(.settling)
        let settled = try? await provider.interaction(
            paneID: request.paneID, agentID: request.agentID,
            paneRevision: request.paneRevision)
        return InteractionResponseResult(
            validatedInteraction: fresh, settledInteraction: settled)
    }

    private static func reply(
        for intent: InteractionResponseIntent, interaction: PendingInteraction
    ) throws -> OpenCodePermissionReply {
        switch intent {
        case .approve: return .once
        case .deny: return .reject
        case .selectChoice(let index):
            guard interaction.choices.indices.contains(index) else {
                throw InteractionResponderError.unsupportedIntent(
                    kind: interaction.kind, intent: intent)
            }
            if index == 0 { return .once }
            if index == interaction.choices.index(before: interaction.choices.endIndex) {
                return .reject
            }
            return .always
        default:
            throw InteractionResponderError.unsupportedIntent(
                kind: interaction.kind, intent: intent)
        }
    }
}

public struct RoutedInteractionProvider: InteractionProviding, Sendable {
    private let registry: OpenCodePaneRegistry
    private let native: OpenCodeNativeInteractionProvider
    private let fallback: any InteractionProviding

    public init(registry: OpenCodePaneRegistry,
                native: OpenCodeNativeInteractionProvider,
                fallback: any InteractionProviding) {
        self.registry = registry
        self.native = native
        self.fallback = fallback
    }

    public func interaction(paneID: String, agentID: String?,
                            paneRevision: UInt64?) async throws
        -> PendingInteraction {
        if await registry.descriptor(for: paneID) != nil {
            return try await native.interaction(
                paneID: paneID, agentID: agentID, paneRevision: paneRevision)
        }
        return try await fallback.interaction(
            paneID: paneID, agentID: agentID, paneRevision: paneRevision)
    }
}

public struct RoutedInteractionResponder: InteractionResponding, Sendable {
    private let registry: OpenCodePaneRegistry
    private let native: OpenCodeNativeInteractionResponder
    private let fallback: any InteractionResponding

    public init(registry: OpenCodePaneRegistry,
                native: OpenCodeNativeInteractionResponder,
                fallback: any InteractionResponding) {
        self.registry = registry
        self.native = native
        self.fallback = fallback
    }

    public func respond(
        _ request: InteractionResponseRequest,
        onPhase: @escaping @Sendable (InteractionResponsePhase) async -> Void
    ) async throws -> InteractionResponseResult {
        if await registry.descriptor(for: request.paneID) != nil {
            return try await native.respond(request, onPhase: onPhase)
        }
        return try await fallback.respond(request, onPhase: onPhase)
    }
}
