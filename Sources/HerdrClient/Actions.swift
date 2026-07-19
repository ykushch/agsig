import Foundation

/// The result of an action.
public enum ActionResult: Sendable, Equatable {
    /// Keys/text were sent successfully.
    case sent
    /// Jump focused the pane and raised (or failed to raise) Ghostty.
    case jumped(ghosttyRaised: Bool)
    /// The pane is on a detached session; focus can't be applied. Not a crash.
    case needsAttach
}

/// Errors specific to the action layer.
public enum ActionError: Error, Sendable {
    /// herdr rejected the keys (invalid key or `prefix+` chord) before writing.
    case keysRejected(message: String)
    /// The classifier produced no keys for this intent (e.g. raw fallback) —
    /// caller must use `sendRawKeys`/`reply` instead of guessing.
    case noKeysForOption
}

extension ActionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .keysRejected(message): message
        case .noKeysForOption: "No validated keys are available for that option."
        }
    }
}

/// Translates user intents into herdr calls + the Ghostty raise.
///
/// **Never auto-answers.** Every method is user-initiated; there are no timers
/// or defaults. Approve/deny/answer send raw keys only (herdr rejects `prefix+`
/// chords and invalid keys before writing — surfaced as `ActionError.keysRejected`).
public struct Actions: Sendable {
    let client: any RequestSending
    let ghostty: any GhosttyActivating

    public init(client: any RequestSending, ghostty: any GhosttyActivating = GhosttyActivator()) {
        self.client = client
        self.ghostty = ghostty
    }

    // MARK: Approve / deny / answer

    /// Approve using the classifier's first option (honoring its answer style).
    @discardableResult
    public func approve(pane: String, prompt: ClassifiedPrompt) async throws -> ActionResult {
        let keys = prompt.keysToAnswer(optionIndex: 0)
        guard !keys.isEmpty else { throw ActionError.noKeysForOption }
        return try await sendRawKeys(pane: pane, keys: keys)
    }

    /// Deny/cancel using the classifier's `denyKeys` (usually `esc`).
    @discardableResult
    public func deny(pane: String, prompt: ClassifiedPrompt) async throws -> ActionResult {
        guard !prompt.denyKeys.isEmpty else { throw ActionError.noKeysForOption }
        return try await sendRawKeys(pane: pane, keys: prompt.denyKeys)
    }

    /// Answer the option at `index`, honoring the widget's answer style:
    /// number-key for permission prompts, arrow-navigate + Enter/Space for
    /// `AskUserQuestion` forms (which ignore number keys). This is the fix for
    /// "clicking any option always picks the first" — number keys did nothing on
    /// the form, so Enter committed whatever the cursor was already on.
    @discardableResult
    public func answer(pane: String, prompt: ClassifiedPrompt, optionIndex: Int) async throws -> ActionResult {
        let keys = prompt.keysToAnswer(optionIndex: optionIndex)
        guard !keys.isEmpty else { throw ActionError.noKeysForOption }
        return try await sendRawKeys(pane: pane, keys: keys)
    }

    /// Free-text reply (F9). Sends text; the caller decides whether a trailing
    /// `enter` is needed for the shape (default: yes, submit it).
    @discardableResult
    public func reply(pane: String, text: String, submit: Bool = true) async throws -> ActionResult {
        let params = try PaneSendTextParams(paneID: pane, text: text).asJSONValue()
        try await send("pane.send_text", params: params)
        if submit {
            return try await sendRawKeys(pane: pane, keys: ["enter"])
        }
        return .sent
    }

    /// Send raw keys directly (the always-available fallback for unknown shapes).
    @discardableResult
    public func sendRawKeys(pane: String, keys: [String]) async throws -> ActionResult {
        let params = try PaneSendKeysParams(paneID: pane, keys: keys).asJSONValue()
        try await send("pane.send_keys", params: params)
        return .sent
    }

    // MARK: Jump

    /// Focus the pane in herdr, then raise Ghostty. Focusing a pane on a detached
    /// session returns `.needsAttach` rather than throwing.
    ///
    /// Focuses the WHOLE path — workspace → tab → pane — not just the pane. herdr is
    /// workspaces→tabs→panes, and the attached client only switches its DISPLAYED
    /// tab when the workspace + tab are focused too; `pane.focus` alone moves the
    /// server's focused id but can leave Ghostty showing the previous tab (the
    /// "opens Ghostty but not the right tab" bug). `workspaceID`/`tabID` come from
    /// the caller's `PaneInfo`; if omitted we look them up via `pane.get`.
    @discardableResult
    public func jump(pane: String, workspaceID: String? = nil, tabID: String? = nil) async throws -> ActionResult {
        // Resolve workspace/tab if not supplied.
        var ws = workspaceID, tab = tabID
        if ws == nil || tab == nil {
            if let info = try? await client.request("pane.get", params: FocusParams(paneID: pane).asJSONValue()),
               let paneObj = info["pane"] {
                ws = ws ?? paneObj["workspace_id"]?.stringValue
                tab = tab ?? paneObj["tab_id"]?.stringValue
            }
        }
        func focusPath() async throws {
            // Focus outermost → innermost so the client switches its rendered view.
            if let ws { try await send("workspace.focus", params: .object(["workspace_id": .string(ws)])) }
            if let tab { try await send("tab.focus", params: .object(["tab_id": .string(tab)])) }
            try await send("pane.focus", params: FocusParams(paneID: pane).asJSONValue())
        }
        do {
            try await focusPath()
        } catch let HerdrError.api(code, message) {
            // A detached/unavailable session surfaces as an API error, not a crash.
            if code.contains("detached") || message.lowercased().contains("detached") {
                return .needsAttach
            }
            throw HerdrError.api(code: code, message: message)
        }
        let raised = ghostty.activate()
        // Re-assert the focus AFTER raising Ghostty. The client can miss/queue the
        // tab switch while it's backgrounded; issuing the focus again once it's
        // frontmost nudges it to render the target tab (the "different tab → jump
        // does nothing" case). Best-effort — ignore errors on the re-assert.
        try? await Task.sleep(nanoseconds: 120_000_000)
        try? await focusPath()
        return .jumped(ghosttyRaised: raised)
    }

    // MARK: Internal

    /// Send a request, translating herdr's key-rejection error into `ActionError`.
    private func send(_ method: String, params: JSONValue) async throws {
        do {
            try await client.request(method, params: params)
        } catch let HerdrError.api(code, message) {
            // herdr rejects invalid keys / prefix bindings before writing.
            if method.hasPrefix("pane.send"),
               code.contains("key") || code.contains("invalid") || code.contains("prefix")
                || message.lowercased().contains("key") {
                throw ActionError.keysRejected(message: message)
            }
            throw HerdrError.api(code: code, message: message)
        }
    }
}
