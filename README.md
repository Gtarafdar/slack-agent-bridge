# Slack Agent Bridge

<p align="center">
  <strong>Local macOS menu-bar app that connects Cursor, Claude, and Cowork to your Slack session.</strong><br>
  Archive messages beyond Slack Free limits · MCP tools for AI agents · Automations · No workspace admin approval.
</p>

<p align="center">
  <a href="https://gtarafdar.github.io/slack-agent-bridge/">Landing page</a> ·
  <a href="https://github.com/Gtarafdar/slack-agent-bridge/releases">Download .dmg</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="docs/SECURITY.md">Security</a>
</p>

<p align="center">
  <a href="https://github.com/Gtarafdar/slack-agent-bridge/stargazers"><img src="https://img.shields.io/github/stars/Gtarafdar/slack-agent-bridge?style=flat&logo=github" alt="GitHub stars"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Slack-desktop%20required-4A154B?logo=slack&logoColor=white" alt="Slack desktop required">
</p>

---

## Why this exists

Connecting Slack to AI agents is harder than it should be.

- **Workspace admin approval** is often required to install Slack apps or bots.
- **OAuth and Marketplace apps** mean security reviews, scope debates, and ongoing trust.
- **Slack bots** can summarize channels, but they live in the cloud with workspace-wide permissions.
- **Slack Free** stops serving messages older than about 90 days, so agents lose history even when you still care about it.

You still want to:

- Search and summarize what happened in your channels
- Let an agent set reminders, post notes to your DM, schedule messages, and run local automations
- Keep a private copy of messages for digests and keyword watches
- Do all of this from **Cursor or Claude** without begging IT for another Slack integration

**Slack Agent Bridge** runs on your Mac, reuses your existing Slack desktop login (same practical approach as [Auto AFK Slack](https://github.com/Gtarafdar/auto-afk-slack)), and exposes a **local MCP server** on `127.0.0.1` so agents can call Slack tools with explicit capability gates.

No admin ticket. No bot user in your workspace directory. Just you, your Mac, and the agent you trust.

---

## Download (recommended)

**[Get the latest `.dmg` from GitHub Releases](https://github.com/Gtarafdar/slack-agent-bridge/releases/latest)**

The landing page at [gtarafdar.github.io/slack-agent-bridge](https://gtarafdar.github.io/slack-agent-bridge/) also fetches the latest release automatically.

| Item | Value |
|------|--------|
| macOS | 13.0 Ventura or later |
| Chip | Apple Silicon or Intel (universal) |
| Slack | Desktop app installed and signed in |
| Size | ≈ 3.4 MB `.dmg` |
| Price | **Free and open source** |

### First launch (ad-hoc signed)

1. Download and open the `.dmg`, drag **Slack Agent Bridge** into Applications.
2. **Right-click → Open → Open** the first time (Gatekeeper for ad-hoc builds).
3. Click **Always Allow** when macOS asks for Keychain access to Slack Safe Storage.
4. Open settings, connect Slack, enable a workspace, create an agent token.

### Notes on distribution

This app is **ad-hoc signed** and **not notarized** (no paid Apple Developer account), which is why the one-time Gatekeeper step is needed. To ship without that prompt, sign with a Developer ID certificate and notarize.

---

## Features

### Connection and workspaces

- **No admin approval** - reuses the local Slack desktop session (`xoxc` + cookie)
- **Multi-workspace** - enable workspaces explicitly; default deny
- **Quick Setup wizard** - guided checklist with MCP connection test
- **Session refresh** - re-import on timer, wake-from-sleep, and auth errors

### Archive and search

- **Local SQLite archive** with full-text search (FTS5)
- **90-day honesty** - Slack Free will not show old messages in Slack; this app keeps a searchable local copy
- **Per-channel Archive toggle** - choose what to store
- **Retention** - 3 / 6 / 12 / 24 months or forever per workspace
- **Export and wipe** - full control over local data
- **Sync controls** - pause, interval, manual sync, storage warnings

### Agent access (MCP)

- **MCP server** on `http://127.0.0.1:47821/mcp` (loopback only)
- **Revocable bearer tokens** - SHA-256 hashed at rest; copy `mcp.json` snippet for Cursor or Claude
- **Token rotation** - rotate and copy updated config; passcode-protected recovery for older tokens
- **Per-workspace capability flags** - see full list below (default deny)
- **Agent channel allow-list** - separate from archive list; agents only see what you mark **Agent**
- **Rich agent ergonomics** - `since` / `until` / `days` / `hours` filters, `from_user` and `user_id` search, `summarize_channel`, enriched payloads (`posted_at`, `channel_name`, `user_display_name`, `text_plain`)
- **Clear agent errors** - structured MCP error codes (`agent_token_unauthorized`, `channel_not_allowed_for_agents`, etc.)
- **Single-instance guard** - one menu-bar app per Mac

### Workspace capabilities (all 15 toggles)

Each workspace has explicit capability gates. Agents need both the **token** and **workspace** to allow a flag.

| Capability | What it allows |
|------------|----------------|
| Read channels | List agent-allowed channels, read history, search, summarize |
| Archive channels | Sync messages into the local SQLite archive |
| Post to my DM | `send_dm_to_self` and automation delivery to your notes-to-self DM |
| Post to DMs (agent-allowed) | `send_dm` to IM channels on the agent allow-list |
| Post to channels (agent-allowed) | `send_channel` to channels on the agent allow-list |
| Post to group DMs (automation inbox) | Group DM inbox, `create_automation_group_dm` |
| Schedule messages (DM / channel) | `schedule_message`, list and delete scheduled messages |
| Set reminders | `create_reminder` (Slack reminders to yourself) |
| Set status | `set_status` (emoji + text + expiration) |
| Add reactions | `add_reaction` on agent-allowed messages |
| Remove reactions | `remove_reaction` on your reactions |
| Pin messages | `pin_message` in agent-allowed channels |
| Unpin messages | `unpin_message` in agent-allowed channels |
| Edit messages | `update_message` on messages you posted |
| Delete messages | `delete_message` on messages you posted |

### Write tools (capability-gated)

- Post to **your own DM** (`send_dm_to_self`)
- Post to **allowed DMs and channels**
- **Schedule messages** (list, create, delete)
- **Edit and delete** your messages
- **Reactions, pins, status, reminders**
- **Automation inbox** - create Slackbot group DM for delivery

### Automations (local)

- **Daily digest** from archived messages (optional post to Slack)
- **Keyword watch** on archive traffic with alerts
- **Task drafting** from recent messages (`draft_task_list`)
- **Delivery modes** - self-DM, Slackbot inbox (group DM), private channel, or Mac only
- **Mac notifications** and optional Slackbot reminders on delivery
- **Star inbox in Slack** and custom inbox thread label
- **Launch at login** optional
- Agents can call `run_automation` over MCP (capability-gated)

### Settings panes

| Pane | Purpose |
|------|---------|
| Quick Setup | Guided wizard with progress checks and MCP link test |
| Connection | Session status, MCP port, archive stats, refresh/disconnect |
| Workspaces | Enable workspaces, capabilities, channel access, automation delivery |
| Archive | Sync interval, pause, retention, export, wipe |
| Automations | Digest rules, keyword watches, test delivery |
| Agent Access | MCP toggle, token create/rotate/revoke, `mcp.json` template |
| Privacy | Data locations, CLI opt-in, revoke tokens, clear Keychain |

### Privacy and security

- Credentials in **macOS Keychain** (this device only)
- **No telemetry** - talks only to `slack.com` over HTTPS
- **Audit log** for MCP tool calls
- **Headless CLI** (`SAB_SEND_TEXT`) **disabled by default**
- Application Support hardened to `0700`; archive DB `0600`

See [docs/SECURITY.md](docs/SECURITY.md) for the full threat model.

---

## Quick start

1. **Connect Slack session** in the app (Connection pane).
2. **Enable a workspace** under Workspaces. Leave write capabilities off until you need them.
3. **Refresh channel list** → mark **Archive** and **Agent** per channel.
4. **Agent Access** → enable MCP server → **Create token** → copy the `mcp.json` template.
5. Paste into Cursor or Claude MCP settings and test.

```json
{
  "mcpServers": {
    "slack-agent-bridge": {
      "url": "http://127.0.0.1:47821/mcp",
      "headers": {
        "Authorization": "Bearer <your-token>"
      }
    }
  }
}
```

---

## MCP tools

| Tool | Purpose |
|------|---------|
| `list_workspaces` | Enabled workspaces for this token |
| `list_agent_channels` | Agent-allowed channels (preferred for reads) |
| `list_channels` | Same as `list_agent_channels` (agent allow-list only) |
| `search_messages` | Archive FTS + optional live Slack search |
| `get_channel_history` | History for an allowed channel |
| `get_thread` | Thread in an allowed channel |
| `get_user` | User profile |
| `list_mentions` | Recent @mentions in allowed channels |
| `summarize_day` | Local digest across allowed channels |
| `summarize_channel` | Channel summary with optional filters |
| `create_reminder` | Slack reminder to yourself |
| `send_dm_to_self` | Post to your own DM |
| `send_dm` | Post to an allowed DM |
| `send_channel` | Post to an allowed channel |
| `schedule_message` | Schedule a message |
| `list_scheduled_messages` | List scheduled messages |
| `delete_scheduled_message` | Cancel scheduled message |
| `update_message` / `delete_message` | Edit or delete your messages |
| `add_reaction` / `remove_reaction` | Emoji reactions |
| `pin_message` / `unpin_message` | Pin management |
| `set_status` | Set Slack status |
| `draft_task_list` | Extract tasks from archive |
| `create_automation_group_dm` | Create Slackbot automation inbox |
| `list_automations` / `run_automation` | Local automation rules |

Channel access: under **Workspaces → Configure**, mark **Archive** (local store) and **Agent** (MCP read) separately.

---

## Build from source

```bash
git clone https://github.com/Gtarafdar/slack-agent-bridge.git
cd slack-agent-bridge
./scripts/build_app.sh
./scripts/make_dmg.sh
open "dist/SlackAgentBridge-1.0.dmg"
```

### Test

```bash
./scripts/dry_run.sh
```

Builds the app, verifies ad-hoc signing and universal binary, launches briefly, probes MCP, packages a DMG.

---

## Important answers

| Question | Answer |
|----------|--------|
| Will old (>90 day) Free messages reappear in Slack? | **No.** This app keeps a **local** searchable archive. Slack itself will not show them. |
| Will it fill my disk? | Default retention is **12 months** per workspace. Export or wipe anytime. |
| Apple Developer fee? | **Not required.** Ad-hoc signed like many free Mac utilities. |
| How do agents DM me? | Enable **Post to my DM**. Uses your user id from `auth.test` only. |
| Slack desktop update broke auth? | Use **Refresh local session**. App also re-imports on a timer. |

Details: [docs/FREE_TIER_AND_RETENTION.md](docs/FREE_TIER_AND_RETENTION.md)

---

## GitHub Pages (landing site)

The marketing site lives in [`docs/`](docs/). To publish:

1. Push this repository to `github.com/Gtarafdar/slack-agent-bridge`
2. **Settings → Pages → Build from branch → `/docs` → Save**
3. Site URL: `https://gtarafdar.github.io/slack-agent-bridge/`

The download buttons call the GitHub Releases API and pick the latest `.dmg` asset automatically when you publish a new release.

---

## Publishing a release

```bash
./scripts/build_app.sh
./scripts/make_dmg.sh
```

Upload `dist/SlackAgentBridge-1.0.dmg` (or the versioned name from the script) to a new GitHub Release. Tag with the version from `Resources/Info.plist`.

---

## Other Slack tools by Gobinda Tarafdar

If you like local, no-admin Slack utilities on macOS, these ship from the same workshop:

| App | What it does | Link |
|-----|----------------|------|
| **Auto AFK Slack** | Lock your Mac and Slack status goes AFK; unlock clears it. Menu-bar only. | [gtarafdar.github.io/auto-afk-slack](https://gtarafdar.github.io/auto-afk-slack/) · [GitHub](https://github.com/Gtarafdar/auto-afk-slack) |
| **Slack Teammate Time** | See each teammate's local time inline next to their name in Slack desktop. | [gtarafdar.github.io/slack-teammate-local-time](https://gtarafdar.github.io/slack-teammate-local-time/) · [GitHub](https://github.com/Gtarafdar/slack-teammate-local-time) |
| **Slack Agent Bridge** | This app: MCP bridge for Cursor/Claude, local archive, automations. | You are here |

All three reuse your existing Slack desktop session. None require workspace admin approval or a Marketplace install.

---

## About the maker

**Gobinda Tarafdar** - WordPress product marketer by trade, stubborn problem-solver by habit, lifelong Harry Potter devotee by heart.

By day I am the [Product Marketing Specialist at WPBakery](https://wpbakery.com/), the page builder that quietly powers a sizeable corner of the WordPress universe. Before that, I helped a single plugin cross **400,000+ active users**. When the day-job owl flies home, I tinker on my own workshop of spells. Slack Agent Bridge is one of them.

<p align="center">
  <img src="https://raw.githubusercontent.com/Gtarafdar/auto-afk-slack/main/docs/assets/gobinda.png" width="120" alt="Gobinda Tarafdar">
</p>

### Also from the workshop

| Project | Description |
|---------|-------------|
| [WPBakery](https://wpbakery.com/) | Page builder I do product marketing for |
| [Docscriber](https://thedocscriber.com/) | Documentation, conjured |
| [TheRecaller](https://therecaller.com/) | A memory charm for what you forget online |
| [TheEditra](https://theeditra.com/) | AI video editor |
| [The Quill Press](https://thequillpress.com/) | Tech news, Daily Prophet style |
| [Costlas](https://costlas.com/) | Cost of living for 140+ countries |
| [Auto AFK Slack](https://gtarafdar.github.io/auto-afk-slack/) | Lock your Mac, Slack goes AFK |
| [Slack Teammate Time](https://gtarafdar.github.io/slack-teammate-local-time/) | Teammate local times inline in Slack |
| [FinderFlow](https://gtarafdar.github.io/FinderFlow/) | Mac file manager with built-in editor |

---

## Support the project

If Slack Agent Bridge saves you an admin ticket or a manual Slack hunt:

- **[Star on GitHub](https://github.com/Gtarafdar/slack-agent-bridge/stargazers)** - helps others find it
- **[Donate](https://gtarafdar.com/donate)** - keeps the workshop lit
- **[Follow on X](https://x.com/Gtarafdarr)** · **[LinkedIn](https://www.linkedin.com/in/gobinda-tarafdar/)**

---

## Disclaimer

**Slack Agent Bridge** is an independent project by Gobinda Tarafdar. It is **not affiliated with, endorsed by, or sponsored by** Slack Technologies, LLC. **Slack** is a trademark of Slack Technologies, LLC.

This app uses an unofficial local session path (the same family as other personal Slack utilities). Use at your own discretion and follow your workspace policies.

---

## License

MIT © 2026 Gobinda Tarafdar. See [LICENSE](LICENSE).
