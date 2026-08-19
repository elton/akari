import Foundation
import Testing
@testable import AkariApp

// Payloads captured from a **running core** (`bun run src/index.ts`, driven by a
// stand-in app over the real socket) and decoded here by the real types.
//
// The rest of the settings tests round-trip Swift against Swift, which proves
// the two halves of one language agree. It cannot catch the failures that
// actually happen across a protocol boundary: a field the core spells
// differently, an integer the core sends as a float, an optional the core omits
// that this side declared required. This file is the other half of that.
//
// **No credential is in here.** The fingerprints below are made-up hex: the
// real ones are SHA-256 prefixes of the machine's own keys, and a test fixture
// is not a place to put them even when they are one-way.

/// Verbatim frames the core emitted, `ts` and key order included. Two states:
/// one where everything is healthy (Cloudflare probed `ok`, with a real neuron
/// count), one where nothing is (voice unbuildable, token cleared, Keychain
/// denied) — the second is the one a working machine can never produce.
///
/// The `fingerprint` values are the only edit: the real ones are SHA-256
/// prefixes of this machine's own keys, and a checked-in fixture is not a place
/// for them even though they are one-way.
private let capturedHealthyState = """
{
  "v": 1,
  "id": "e25db654-05c1-48df-82b1-9ecf346f25af",
  "ts": 1787125227668,
  "type": "settings.state",
  "payload": {
    "routes": [
      {
        "route": "voice",
        "selected": "auto",
        "active": null,
        "candidates": [
          {
            "provider": "dashscope-realtime",
            "model": "qwen3.5-omni-flash-realtime",
            "status": "error",
            "message": "语音会话建不起来，看 core 的日志。",
            "checkedAt": 0
          }
        ]
      },
      {
        "route": "text",
        "selected": "auto",
        "active": "cloudflare-workers-ai",
        "candidates": [
          {
            "provider": "cloudflare-workers-ai",
            "status": "ok",
            "checkedAt": 1787125225560,
            "model": "@cf/qwen/qwen3.8-27b",
            "capabilities": {
              "vision": true,
              "tools": true,
              "streaming": true,
              "contextTokens": 262144,
              "local": false
            },
            "message": "Cloudflare Workers AI 可用。",
            "quota": {
              "unit": "neurons",
              "used": 162,
              "resetsAt": 1787184000000,
              "note": "这是 UTC 当日已用量；Cloudflare 不提供剩余额度，配额上限请看 dashboard。"
            },
            "latencyMs": 2105
          },
          {
            "provider": "local-mlx",
            "status": "unknown",
            "model": "orcarouter/Qwen3.8-27B-Uncensored-MLX",
            "capabilities": {
              "vision": true,
              "tools": true,
              "streaming": true,
              "contextTokens": 262144,
              "local": true
            },
            "checkedAt": 0
          }
        ]
      }
    ],
    "credentials": [
      {
        "slot": "dashscope.apiKey",
        "source": "env",
        "present": true,
        "fingerprint": "aaaa0001",
        "envVar": "DASHSCOPE_API_KEY"
      },
      {
        "slot": "cloudflare.accountId",
        "source": "env",
        "present": true,
        "fingerprint": "aaaa0002",
        "envVar": "CLOUDFLARE_ACCOUNT_ID"
      },
      {
        "slot": "cloudflare.apiToken",
        "source": "env",
        "present": true,
        "fingerprint": "aaaa0003",
        "envVar": "CLOUDFLARE_API_TOKEN"
      },
      {
        "slot": "huggingface.token",
        "source": "env",
        "present": true,
        "fingerprint": "aaaa0004",
        "envVar": "HF_TOKEN"
      }
    ],
    "envFiles": [
      {
        "path": "/Volumes/data/Dev/01-PWR/akari/.env",
        "loaded": true
      },
      {
        "path": "/Users/someone/Library/Application Support/akari/.env",
        "loaded": false
      }
    ]
  }
}
"""

private let capturedDegradedState = """
{
  "v": 1,
  "id": "f15893d0-0fb1-4aaf-b229-fd8bdbf00a1f",
  "ts": 1787125206928,
  "type": "settings.state",
  "payload": {
    "routes": [
      {
        "route": "voice",
        "selected": "auto",
        "active": null,
        "candidates": [
          {
            "provider": "dashscope-realtime",
            "model": "qwen3.5-omni-flash-realtime",
            "status": "error",
            "message": "语音会话建不起来，看 core 的日志。",
            "checkedAt": 0
          }
        ]
      },
      {
        "route": "text",
        "selected": "auto",
        "active": "cloudflare-workers-ai",
        "candidates": [
          {
            "provider": "cloudflare-workers-ai",
            "status": "unconfigured",
            "checkedAt": 1787125206926,
            "model": "@cf/qwen/qwen3.8-27b",
            "capabilities": {
              "vision": true,
              "tools": true,
              "streaming": true,
              "contextTokens": 262144,
              "local": false
            },
            "message": "还没填 Cloudflare 账号 ID 或 API token。",
            "missing": [
              "cloudflare.apiToken"
            ],
            "latencyMs": 3
          },
          {
            "provider": "local-mlx",
            "status": "unknown",
            "model": "orcarouter/Qwen3.8-27B-Uncensored-MLX",
            "capabilities": {
              "vision": true,
              "tools": true,
              "streaming": true,
              "contextTokens": 262144,
              "local": true
            },
            "checkedAt": 0
          }
        ]
      }
    ],
    "credentials": [
      {
        "slot": "dashscope.apiKey",
        "source": "env",
        "present": true,
        "fingerprint": "aaaa0001",
        "envVar": "DASHSCOPE_API_KEY"
      },
      {
        "slot": "cloudflare.accountId",
        "source": "app",
        "present": true,
        "fingerprint": "aaaa0002",
        "envVar": "CLOUDFLARE_ACCOUNT_ID"
      },
      {
        "slot": "cloudflare.apiToken",
        "source": "unset",
        "present": false,
        "cleared": true,
        "envVar": "CLOUDFLARE_API_TOKEN"
      },
      {
        "slot": "huggingface.token",
        "source": "env",
        "present": true,
        "fingerprint": "aaaa0004",
        "denied": true,
        "envVar": "HF_TOKEN"
      }
    ],
    "envFiles": [
      {
        "path": "/Volumes/data/Dev/01-PWR/akari/.env",
        "loaded": true
      },
      {
        "path": "/Users/someone/Library/Application Support/akari/.env",
        "loaded": false
      }
    ]
  }
}
"""

private let capturedProbeResult = """
{
  "v": 1,
  "id": "bb34b674-889a-4eb9-9e42-b8b350bf1891",
  "ts": 1787125227669,
  "replyTo": "306ba3c2-d10b-4282-8273-d97fec0daa75",
  "type": "settings.probeResult",
  "payload": {
    "route": "text",
    "results": [
      {
        "provider": "cloudflare-workers-ai",
        "status": "ok",
        "checkedAt": 1787125225560,
        "model": "@cf/qwen/qwen3.8-27b",
        "capabilities": {
          "vision": true,
          "tools": true,
          "streaming": true,
          "contextTokens": 262144,
          "local": false
        },
        "message": "Cloudflare Workers AI 可用。",
        "quota": {
          "unit": "neurons",
          "used": 162,
          "resetsAt": 1787184000000,
          "note": "这是 UTC 当日已用量；Cloudflare 不提供剩余额度，配额上限请看 dashboard。"
        },
        "latencyMs": 2105
      }
    ]
  }
}
"""

private let capturedCredentialsRequest = """
{
  "v": 1,
  "id": "4a82ba3c-84ce-42af-9731-a679f336bd36",
  "ts": 1787125225236,
  "type": "credentials.request",
  "payload": {
    "requestId": "cr-1",
    "slots": [
      "dashscope.apiKey",
      "cloudflare.accountId",
      "cloudflare.apiToken",
      "huggingface.token"
    ]
  }
}
"""

private func decode(_ json: String) throws -> ControlMessage {
    try JSONDecoder().decode(ControlMessage.self, from: Data(json.utf8))
}

/// There is no `.env` in these tests, and reading one would be answering a
/// different question than "does the core's payload decode".
@MainActor
private final class NoEnvReader: EnvFileReading {
    func value(forKey key: String, atPath path: String) throws -> String? { nil }
}

@MainActor
@Suite("payloads captured from a running core")
struct CoreWirePayloadTests {
    @Test("settings.state from the core decodes into the types the window reads")
    func settingsStateDecodes() throws {
        guard case .settingsState(let state) = try decode(capturedHealthyState).body else {
            Issue.record("settings.state did not decode as settings.state")
            return
        }

        #expect(state.routes.count == 2)

        let voice = try #require(state.routes.first { $0.route == SettingsRoute.voice })
        #expect(voice.selected == ProviderID.auto)
        // `active: null` is a route with nothing serving it, and has to survive
        // as nil rather than as the string "null" or a decode failure.
        #expect(voice.active == nil)
        #expect(voice.candidates.first?.provider == ProviderID.dashscopeRealtime)
        // Never probed: §3.9 says 0, and the window must not render that as a
        // date in 1970. (These captures come from a `--no-realtime` core, which
        // is why the voice row is not `ok`.)
        #expect(voice.candidates.first?.checkedAt == 0)
        // The voice row carries no capability block; the core declines to
        // invent a context window it has not verified.
        #expect(voice.candidates.first?.capabilities == nil)

        let text = try #require(state.routes.first { $0.route == SettingsRoute.text })
        #expect(text.active == ProviderID.cloudflareWorkersAI)
        #expect(text.candidates.map(\.provider) == [
            ProviderID.cloudflareWorkersAI, ProviderID.localMLX,
        ])

        let cloudflare = try #require(text.candidates.first)
        #expect(cloudflare.isOK)
        #expect(cloudflare.model == "@cf/qwen/qwen3.8-27b")
        #expect(cloudflare.capabilities?.vision == true)
        #expect(cloudflare.capabilities?.contextTokens == 262_144)
        #expect(cloudflare.capabilities?.maxOutputTokens == nil)
        // A millisecond epoch does not fit in a 32-bit Int; it is Int64 here
        // for that reason and this is the assertion that keeps it that way.
        #expect(cloudflare.checkedAt == 1_787_125_225_560)
        #expect(cloudflare.latencyMs == 2105)

        let quota = try #require(cloudflare.quota)
        #expect(quota.unit == "neurons")
        // A real neuron count from a real account, on the day it was captured.
        #expect(quota.used == 162)
        // Cloudflare publishes no allowance ceiling, so these stay empty and
        // the window shows the note instead of a made-up denominator.
        #expect(quota.limit == nil)
        #expect(quota.remaining == nil)
        #expect(quota.note?.isEmpty == false)

        let local = try #require(text.candidates.last)
        // Never probed in this capture, so `unknown` — and it still carries the
        // capability block, which is what lets the window draw the row before
        // anything has been tested.
        #expect(local.status == "unknown")
        #expect(local.capabilities?.local == true)
        #expect(local.quota == nil)
    }

    @Test("every credential slot state the core can report is understood")
    func credentialStatesDecode() throws {
        // The degraded capture, because it is the only one carrying all four
        // outcomes at once — a working machine never produces `cleared` and
        // `denied` side by side.
        guard case .settingsState(let state) = try decode(capturedDegradedState).body else {
            Issue.record("not a settings.state")
            return
        }
        let bySlot = Dictionary(uniqueKeysWithValues: state.credentials.map { ($0.slot, $0) })
        #expect(bySlot.count == CredentialSlotID.all.count)

        // `.env` won this slot.
        #expect(bySlot[CredentialSlotID.dashscopeAPIKey]?.source == "env")
        // The Keychain won this one.
        #expect(bySlot[CredentialSlotID.cloudflareAccountID]?.source == "app")
        // Cleared in settings: unset AND flagged, which is what suppresses the
        // `.env` fallback (§八). Collapsing the two would resurrect a token the
        // user deleted.
        let token = try #require(bySlot[CredentialSlotID.cloudflareAPIToken])
        #expect(token.source == "unset")
        #expect(token.present == false)
        #expect(token.cleared == true)
        #expect(token.fingerprint == nil)
        // Denied is reported alongside a working `.env` fallback, so the window
        // can explain the empty field without claiming voice is broken.
        let hf = try #require(bySlot[CredentialSlotID.huggingFaceToken])
        #expect(hf.denied == true)
        #expect(hf.source == "env")
        // Absent flags decode as nil, not as false-that-was-sent.
        #expect(bySlot[CredentialSlotID.dashscopeAPIKey]?.cleared == nil)
    }

    @Test("the env file list is the core's, so the import link opens what the core read")
    func envFilesDecode() throws {
        guard case .settingsState(let state) = try decode(capturedHealthyState).body else {
            Issue.record("not a settings.state")
            return
        }
        #expect(state.envFiles.count == 2)
        #expect(state.envFiles.first?.loaded == true)
        #expect(state.envFiles.last?.loaded == false)

        let store = SettingsStore(store: InMemoryCredentialStore(), envReader: NoEnvReader())
        store.handle(ControlMessage(body: .settingsState(state)))
        // Only a file the core says it loaded is a candidate for the import
        // link; the one it merely looked for is not.
        #expect(store.envPath == "/Volumes/data/Dev/01-PWR/akari/.env")
    }

    @Test("settings.probeResult from a real Cloudflare call decodes, pairing included")
    func probeResultDecodes() throws {
        let message = try decode(capturedProbeResult)
        // §3.9 pairs the result with the probe by id; without it a window with
        // two probes in flight cannot tell which button to give back.
        #expect(message.replyTo?.isEmpty == false)
        guard case .settingsProbeResult(let result) = message.body else {
            Issue.record("not a settings.probeResult")
            return
        }
        #expect(result.route == SettingsRoute.text)
        #expect(result.results.count == 1)
        let row = try #require(result.results.first)
        #expect(row.provider == ProviderID.cloudflareWorkersAI)
        #expect(row.isOK)
        // Probing one provider answers about that provider only.
        #expect(row.missing == nil)
        #expect(row.quota?.used == 162)
        #expect(row.latencyMs == 2105)
    }

    @Test("a degraded state is a state, not a decode failure")
    func degradedStateDecodes() throws {
        guard case .settingsState(let state) = try decode(capturedDegradedState).body else {
            Issue.record("not a settings.state")
            return
        }
        let text = try #require(state.routes.first { $0.route == SettingsRoute.text })
        let cloudflare = try #require(text.candidates.first)
        #expect(cloudflare.status == "unconfigured")
        #expect(cloudflare.missing == [CredentialSlotID.cloudflareAPIToken])
        // Nothing has been proven to work, yet `active` still names who would
        // be tried first — the window shows a candidate, not a blank.
        #expect(text.active == ProviderID.cloudflareWorkersAI)

        let voice = try #require(state.routes.first { $0.route == SettingsRoute.voice })
        let session = try #require(voice.candidates.first)
        #expect(session.status == "error")
        // §3.9: the message is a pointer, never the upstream text — which here
        // would have been an English constructor error naming an endpoint.
        #expect(session.message?.contains("core") == true)
    }

    @Test("a credentials.request from the core is answered slot for slot")
    func credentialsRequestIsAnswerable() throws {
        guard case .credentialsRequest(let request) = try decode(capturedCredentialsRequest).body
        else {
            Issue.record("not a credentials.request")
            return
        }
        #expect(request.requestId == "cr-1")
        #expect(request.slots == CredentialSlotID.all)

        let store = InMemoryCredentialStore()
        try store.save(CredentialSlotID.dashscopeAPIKey, value: "sk-local-test-value")
        try store.clear(CredentialSlotID.cloudflareAccountID)
        let settings = SettingsStore(store: store, envReader: NoEnvReader())

        let answer = settings.answer(request)
        #expect(answer.requestId == "cr-1")
        #expect(answer.values.map(\.slot) == CredentialSlotID.all)
        #expect(answer.values[0].state == "set")
        #expect(answer.values[1].state == "cleared")
        #expect(answer.values[1].value == nil)
        #expect(answer.values[2].state == "unset")

        // And the core parses it back: the encoded frame has to survive
        // `JSONSerialization` with the value on exactly one entry.
        let encoded = try JSONEncoder().encode(ControlMessage(body: .credentialsProvide(answer)))
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])
        let values = try #require(payload["values"] as? [[String: Any]])
        #expect(values.filter { $0["value"] != nil }.count == 1)
    }
}
