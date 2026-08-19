import Foundation
import Testing
@testable import AkariApp

// The settings and credential messages of ADR-009 (docs/protocol.md §3.9/§3.10).
// No real credential appears here and none is needed: every value is a literal.

private func roundTrip(_ body: ControlBody) throws -> ControlMessage {
    let data = try JSONEncoder().encode(ControlMessage(body: body, id: "m-1", replyTo: "r-0"))
    return try JSONDecoder().decode(ControlMessage.self, from: data)
}

private func wire(_ body: ControlBody) throws -> [String: Any] {
    let data = try JSONEncoder().encode(ControlMessage(body: body, id: "m-1"))
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

@Suite("settings protocol")
struct SettingsProtocolTests {
    @Test("settings.state survives a round trip with every optional filled")
    func settingsStateRoundTrip() throws {
        let health = ProviderHealthPayload(
            provider: ProviderID.cloudflareWorkersAI,
            status: "ok",
            message: "可用",
            missing: nil,
            model: "@cf/qwen/qwen3.8-27b",
            capabilities: ProviderCapabilitiesPayload(
                vision: true, tools: true, streaming: true,
                contextTokens: 131_072, maxOutputTokens: 8192, local: false),
            quota: QuotaSnapshotPayload(unit: "neurons", used: 1234.5, limit: 10_000,
                                        remaining: 8765.5, resetsAt: 1_755_648_000_000,
                                        note: "按天重置"),
            latencyMs: 312,
            checkedAt: 1_755_607_200_123)
        let body = ControlBody.settingsState(SettingsStatePayload(
            routes: [
                RouteStatePayload(route: SettingsRoute.voice,
                                  selected: ProviderID.dashscopeRealtime,
                                  active: ProviderID.dashscopeRealtime,
                                  candidates: []),
                RouteStatePayload(route: SettingsRoute.text,
                                  selected: ProviderID.auto,
                                  active: ProviderID.cloudflareWorkersAI,
                                  candidates: [health]),
            ],
            credentials: [
                CredentialSlotStatePayload(slot: CredentialSlotID.dashscopeAPIKey,
                                           source: "env", present: true,
                                           fingerprint: "3f9a1c02",
                                           envVar: "DASHSCOPE_API_KEY"),
                CredentialSlotStatePayload(slot: CredentialSlotID.huggingFaceToken,
                                           source: "unset", present: false,
                                           cleared: true, envVar: "HF_TOKEN"),
            ],
            envFiles: [EnvFileStatePayload(path: "/x/.env", loaded: true)]))

        guard case .settingsState(let decoded) = try roundTrip(body).body else {
            Issue.record("wrong case"); return
        }
        #expect(decoded.routes.count == 2)
        #expect(decoded.routes[1].active == ProviderID.cloudflareWorkersAI)
        #expect(decoded.routes[1].candidates.first?.quota?.remaining == 8765.5)
        #expect(decoded.routes[1].candidates.first?.capabilities?.vision == true)
        #expect(decoded.credentials[1].cleared == true)
        #expect(decoded.envFiles.first?.loaded == true)
    }

    @Test("an unknown provider id decodes instead of failing the whole message")
    func unknownProviderIsData() throws {
        // A core that learned about a new provider must not blank the settings
        // window. This is the payload-level form of protocol.md §三's rule that
        // an unknown message type is ignored rather than fatal.
        let json = """
        {"v":1,"id":"m-2","ts":1,"type":"settings.state","payload":{
          "routes":[{"route":"text","selected":"auto","active":"brand-new-thing",
                     "candidates":[{"provider":"brand-new-thing","status":"teleporting","checkedAt":0}]}],
          "credentials":[],"envFiles":[]}}
        """
        let decoded = try JSONDecoder().decode(ControlMessage.self,
                                               from: Data(json.utf8))
        guard case .settingsState(let payload) = decoded.body else {
            Issue.record("wrong case"); return
        }
        #expect(payload.routes[0].candidates[0].status == "teleporting")
        #expect(payload.routes[0].candidates[0].isOK == false)
    }

    @Test("settings.get carries no payload key at all")
    func settingsGetHasNoPayload() throws {
        let json = try wire(.settingsGet)
        #expect(json["payload"] == nil)
        #expect(json["type"] as? String == "settings.get")
    }

    @Test("settings.set and settings.probe round trip")
    func setAndProbe() throws {
        guard case .settingsSet(let set) = try roundTrip(
            .settingsSet(SettingsSetPayload(route: SettingsRoute.text,
                                            provider: ProviderID.localMLX))).body
        else { Issue.record("wrong case"); return }
        #expect(set.provider == ProviderID.localMLX)

        guard case .settingsProbe(let probe) = try roundTrip(
            .settingsProbe(SettingsProbePayload(route: SettingsRoute.text,
                                                provider: nil,
                                                timeoutMs: 10_000))).body
        else { Issue.record("wrong case"); return }
        #expect(probe.provider == nil)
        #expect(probe.timeoutMs == 10_000)
    }

    @Test("settings.probeResult keeps the replyTo that pairs it with the probe")
    func probeResultKeepsReplyTo() throws {
        let message = try roundTrip(.settingsProbeResult(SettingsProbeResultPayload(
            route: SettingsRoute.text,
            results: [ProviderHealthPayload(provider: ProviderID.localMLX,
                                            status: "model_missing",
                                            message: "权重还没下完。",
                                            checkedAt: 7)])))
        #expect(message.replyTo == "r-0")
        guard case .settingsProbeResult(let payload) = message.body else {
            Issue.record("wrong case"); return
        }
        #expect(payload.results[0].status == "model_missing")
    }
}

@Suite("credential messages")
struct CredentialProtocolTests {
    @Test("credentials.updated names slots and nothing else")
    func updatedCarriesNoValues() throws {
        let json = try wire(.credentialsUpdated(CredentialsUpdatedPayload(
            slots: [CredentialSlotID.cloudflareAPIToken])))
        let payload = json["payload"] as! [String: Any]
        #expect(payload.keys.sorted() == ["slots"])
    }

    @Test("credentials.provide round trips the four states")
    func provideRoundTrip() throws {
        let body = ControlBody.credentialsProvide(CredentialsProvidePayload(
            requestId: "cr-3",
            values: [
                CredentialValuePayload(slot: CredentialSlotID.dashscopeAPIKey,
                                       state: "set", value: "sk-placeholder"),
                CredentialValuePayload(slot: CredentialSlotID.cloudflareAPIToken,
                                       state: "cleared"),
                CredentialValuePayload(slot: CredentialSlotID.cloudflareAccountID,
                                       state: "unset"),
                CredentialValuePayload(slot: CredentialSlotID.huggingFaceToken,
                                       state: "denied"),
            ]))
        guard case .credentialsProvide(let decoded) = try roundTrip(body).body else {
            Issue.record("wrong case"); return
        }
        #expect(decoded.requestId == "cr-3")
        #expect(decoded.values.map(\.state) == ["set", "cleared", "unset", "denied"])
        #expect(decoded.values[0].value == "sk-placeholder")
    }

    @Test("a value only rides along on state == set")
    func nonSetStatesDropTheValue() {
        // Guards the sender: a UI that fills the field and then flips the state
        // to `cleared` must not ship the secret anyway.
        let cleared = CredentialValuePayload(slot: CredentialSlotID.dashscopeAPIKey,
                                             state: "cleared", value: "sk-placeholder")
        #expect(cleared.value == nil)
    }

    @Test("printing a credential payload cannot leak it")
    func descriptionIsRedacted() {
        // `\(payload)` inside an os_log call is one keystroke away at all times.
        let payload = CredentialsProvidePayload(
            requestId: "cr-4",
            values: [CredentialValuePayload(slot: CredentialSlotID.dashscopeAPIKey,
                                            state: "set", value: "sk-placeholder")])
        #expect(!"\(payload)".contains("sk-placeholder"))
        #expect(!String(reflecting: payload).contains("sk-placeholder"))
        #expect("\(payload)".contains("dashscope.apiKey"))
    }

    @Test("credentials.request pairs by requestId")
    func requestRoundTrip() throws {
        guard case .credentialsRequest(let decoded) = try roundTrip(
            .credentialsRequest(CredentialsRequestPayload(
                requestId: "cr-9", slots: CredentialSlotID.all))).body
        else { Issue.record("wrong case"); return }
        #expect(decoded.requestId == "cr-9")
        #expect(decoded.slots.count == 4)
    }
}
