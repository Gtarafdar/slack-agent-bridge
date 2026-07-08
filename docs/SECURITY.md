# Slack Agent Bridge — Security notes

Local-only bridge between Slack desktop sessions and IDE agents (Cursor / Claude / Cowork).

## Checklist

- [x] Slack `xoxc` + cookie stored in Keychain with `ThisDeviceOnly`
- [x] Agent tokens hashed (SHA-256); plaintext shown once
- [x] MCP bound to `127.0.0.1` only
- [x] Workspace default-deny; capability gates on every write tool
- [x] No telemetry / no third-party endpoints
- [x] Secrets never logged (tokens/cookies omitted from Log)
- [x] Archive wipe + export available
- [x] Default retention 12 months + storage warning
- [x] Rate-limit backoff on Slack API (`ratelimited` / HTTP 429)
- [x] Wake-from-sleep archive sync + periodic session re-import
- [x] Self-DM delivery uses `auth.test` user id only
- [x] Audit log for MCP tool calls and token lifecycle
- [x] Ad-hoc signed distribution (no paid Apple Developer Program required)
- [x] Headless `SAB_SEND_TEXT` CLI disabled by default (opt-in in Privacy settings)
- [x] MCP `list_channels` scoped to agent channel allow-list
- [x] `run_automation` / `create_automation_group_dm` gated on agent token capabilities
- [x] Application Support directory hardened to `0700`; archive DB `0600`
- [x] MCP JSON-RPC batch capped at 25 requests; CORS does not use `*`

## Threat model (local Mac)

| Surface | Risk | Mitigation |
|---------|------|------------|
| MCP on `127.0.0.1` | Other local apps call tools | Bearer agent token required; per-workspace capability flags |
| `SAB_SEND_TEXT` env | Any script posts to Slack | **Disabled by default**; requires Privacy toggle + workspace caps |
| Browser on localhost | CORS / CSRF to MCP | No `Access-Control-Allow-Origin: *`; auth header still required |
| Archive on disk | Other users read messages | `~/Library/Application Support/SlackAgentBridge` mode `0700` |
| Malicious MCP batch | DoS / long tool runs | Max 25 RPCs per HTTP request; 60s tool timeout |

Configure agent tokens with the **minimum** capabilities needed. Use **list_agent_channels** (or `list_channels`, now equivalent) rather than expecting a full workspace channel dump.

## Distribution (no Apple Developer fee)

Ships **ad-hoc signed**, the same practical approach many free Mac utilities use for personal and open-source distribution.

- Users: right-click → Open on first launch (Gatekeeper)
- You: no yearly Apple Developer Program subscription required
- Notarization is optional and intentionally not part of the default release path

```bash
./scripts/build_app.sh
./scripts/make_dmg.sh
```

## Caveats

The `xoxc` + `d` cookie path is unofficial (same as Auto AFK). Tokens can rotate; the app re-imports on a timer and on auth errors, or use **Refresh local session**. Free Slack still only *serves* ~90 days of history for the initial backfill — ongoing sync preserves everything after first ingest, subject to your retention setting.
