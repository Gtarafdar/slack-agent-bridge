# Free-tier history, archives, and retention

## Will messages older than 90 days show up again in Slack?

**No — not inside the free Slack app UI.**

Slack Free stops serving older history from Slack’s servers. This app cannot (and does not try to) rewrite Slack’s UI to restore that history for teammates. That would require Slack’s official product tier or other unsupported client hacks.

What this app **does**:

1. While a message is still within Slack’s reachable window (~90 days on Free), the archiver copies it into a **local SQLite store** on your Mac.
2. After Slack Free stops returning that message, the **local copy remains searchable** via Cursor / Claude / Cowork MCP tools (`search_messages`, `get_channel_history`).
3. Digests and task lists use the local archive, not Slack’s server-side search.

So: agents and your digests still see old important messages; Slack’s channel scrollback on Free does not.

## Retention and disk space

Default per workspace: **keep 12 months** of archived messages (not forever).

You can change this under **Workspaces → Keep archived messages**:

| Option | Effect |
|--------|--------|
| 3 / 6 / 12 / 24 months | Automatically prune older local rows |
| Keep forever | Never prune (monitor disk usage) |

Also available:

- Storage warning when the archive grows large (default 2 GB)
- **Apply retention now**, **Export**, and **Wipe archive**

Only the local cache is pruned. Slack.com is never deleted by this app.

## How AI tools notify you in Slack

1. Enable a workspace and turn on **Post to my DM**.
2. Optionally enable **Post digests and watches to my Slack DM**.
3. Create an agent token and allow Cursor/Claude to call `send_dm_to_self` / `run_automation`.

### How the app knows “you”

On connect, each workspace runs Slack `auth.test` with your desktop session token. That returns **your user id**. Digests and MCP DM tools open a conversation with that same user id (`conversations.open` → self IM) and post there. They do not post to other people or random channels unless you later expand capabilities intentionally.

## Surviving Slack desktop updates

- Session tokens live in Slack’s local files and can rotate after updates or re-login.
- The app **re-reads the local session on a timer** (default every 6 hours) and on `invalid_auth` / `token_expired` from the API.
- Use **Refresh local session** anytime Slack updates break connectivity.

## Signing without an Apple Developer fee

Builds are **ad-hoc signed** (same pattern as many free Mac utilities, including Auto AFK). No notarization, no yearly Apple Developer Program cost.

First launch: **right-click → Open**. That is Gatekeeper’s standard path for non-notarized software, not an Apple review of the app’s content.
