# Discord Live Feed (bash edition)

A Discord bot + web front-end that streams messages from a Discord channel
into a browser in real time — implemented entirely in bash (plus `curl`,
`jq`, `socat`, and [`websocat`](https://github.com/vi/websocat)), no
language runtime required.

**Live demo:** _add your Railway URL here after deploying_

## How it works

Everything runs as two shell scripts inside one container:

1. **Bot** ([`bin/bot.sh`](bin/bot.sh)) — connects to Discord's real
   Gateway, the same push-based WebSocket API Discord's own client uses,
   via `websocat` run as a bash `coproc` (a background process bash can
   both write to and read from over file descriptors). On connect it:
   - reads Discord's `Hello` payload to learn the heartbeat interval,
   - sends an `Identify` payload with the bot token and intents,
   - runs a background loop that sends a heartbeat on that interval,
   - and reads dispatch events in the foreground, picking out
     `MESSAGE_CREATE` events, reshaping each with `jq` into a small JSON
     object (author, avatar URL, content, timestamp, attachments), and
     appending it as one line to `data/messages.jsonl`.

   Before connecting (and again after every reconnect), it does one REST
   catch-up call — `GET /channels/{id}/messages?after=<last-seen-id>` —
   so messages posted while disconnected aren't lost, and so the very
   first run backfills some history. `data/last_id` tracks the last
   message ID seen, updated by both the REST catch-up and the live
   Gateway stream.
2. **Web server** ([`bin/handle_request.sh`](bin/handle_request.sh), run
   via [`run.sh`](run.sh)) — `socat` listens on `$PORT` and forks a copy
   of `handle_request.sh` per connection (socat's `fork` option gives
   free concurrency without bash having to manage sockets itself). That
   script reads the raw HTTP request off stdin and, depending on the
   path, either serves a static file from `public/` or opens a
   [Server-Sent Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
   stream at `/events`: it replays the last 50 lines of
   `messages.jsonl` and then `tail`s the file forever, turning each new
   line into an SSE `data: ...` event as the bot appends it.

The front-end (`public/client.js`) just opens `new EventSource('/events')`
and renders every event it receives — no distinction between "history" and
"live" messages, since the tail-replay already delivers both through the
same stream in order. Message text is inserted via `textContent` (never
`innerHTML`), so arbitrary content posted in Discord can't execute as
HTML/script in the browser.

```
Discord Gateway (wss) <==coproc==> websocat <--stdin/stdout--> bot.sh --append--> messages.jsonl <--tail-- handle_request.sh --SSE--> browser (EventSource)
                                                                  ^
                                                    REST catch-up (on start/reconnect)
```

If the bot process dies for any reason (socket drop, Discord requesting a
reconnect, an invalid session), `run.sh`'s supervisor loop restarts it a
few seconds later, and it simply reconnects fresh — no session Resume is
implemented (see Limitations).

## Running locally

Requires `bash`, `curl`, `jq`, `socat`, and `websocat` on PATH:

```bash
# Debian/Ubuntu
apt install socat
# websocat has no apt package; grab a static binary:
curl -fsSL -o /usr/local/bin/websocat \
  https://github.com/vi/websocat/releases/download/v1.14.1/websocat.x86_64-unknown-linux-musl
chmod +x /usr/local/bin/websocat
```

```bash
cp .env.example .env   # fill in the two required values below
set -a; source .env; set +a
./run.sh
```

You need:

- **`DISCORD_BOT_TOKEN`** — create an application at the
  [Discord Developer Portal](https://discord.com/developers/applications),
  add a Bot user (Bot tab → Reset Token), and enable **Message Content
  Intent** (Bot → Privileged Gateway Intents). This is required, not
  optional: `bot.sh` requests the `MESSAGE_CONTENT` intent in its
  Identify payload, and Discord rejects the connection (Invalid Session)
  if the bot doesn't have it enabled.
- **`DISCORD_CHANNEL_ID`** — the channel to stream. Turn on Developer Mode
  (User Settings → Advanced) and right-click a channel → Copy Channel ID.
- Invite the bot to a server with the `bot` scope and "Read Message
  History" + "View Channel" permissions, via the OAuth2 URL generator in
  the developer portal.

Then open `http://localhost:3000` and post a message in the channel — it
should appear in well under a second.

## Deploying on Railway

This needs a real OS with `bash`/`curl`/`jq`/`socat`/`websocat` installed,
which Railway's Nixpacks auto-detection has no reason to provide for a
repo with no `package.json`/`requirements.txt`/etc. So this repo ships a
[`Dockerfile`](Dockerfile) (Debian slim + those packages, `websocat`
fetched as a static binary from its GitHub releases since it isn't
packaged for Debian) and [`railway.json`](railway.json) points Railway at
the `DOCKERFILE` builder.

1. Push this repo to GitHub and create a new Railway project from it (or
   `railway up` from the CLI). Railway builds the `Dockerfile`.
2. In the Railway project's **Variables** tab, set `DISCORD_BOT_TOKEN` and
   `DISCORD_CHANNEL_ID`. Railway supplies `PORT` automatically.
3. Once deployed, open the generated `*.up.railway.app` URL — that's the
   live feed.

## Alternatives considered

This app previously existed as a straightforward Node.js/discord.js
implementation, and then as a pure-bash version that REST-polled Discord
instead of using the Gateway (hand-rolling a WebSocket client's framing,
masking, and TLS in bash isn't reasonable). `websocat` changed that
calculus: it's a small, purpose-built CLI that handles the WebSocket
protocol itself and exposes it as line-based stdin/stdout, so bash only
has to speak Discord's *Gateway* protocol (JSON opcodes, a heartbeat
timer, an Identify payload) rather than WebSocket itself. That's what
`bot.sh` does now, over a `coproc`.

- **REST polling → Gateway push (this change).** Trades a polling loop
  (fixed latency, one wasted request per interval) for genuine
  push-based delivery — the main limitation from the previous version is
  gone. The cost is real added complexity: a `coproc`, a background
  heartbeat timer needing to share state with the main read loop via a
  file (separate processes can't share bash variables), explicit opcode
  handling, and no session Resume (see Limitations).
- **WebSockets → Server-Sent Events for the browser leg**, still. SSE
  remains the better fit for the *browser* leg specifically: it's a
  plain HTTP response the server only ever writes to, and the browser's
  built-in `EventSource` handles reconnection automatically. Using
  `websocat` there too (it can also serve, in an `EXEC:`-per-connection
  style much like socat) was considered, but it would mean going back to
  a `WebSocket` client with hand-rolled reconnect/backoff in
  `client.js` for no real benefit, since the browser never needs to send
  anything back.
- **`socat ... fork` vs. a hand-rolled bash TCP server.** Bash can open
  a listening socket itself (`exec 3<>/dev/tcp/...` tricks), but handling
  multiple concurrent long-lived SSE connections that way means bash
  doing its own `select`/accept loop, which is fragile and slow. `socat`'s
  `fork` mode hands each connection to its own `handle_request.sh`
  process, so concurrency is "one shell script per client" rather than
  something bash has to schedule itself.
- **In-memory ring buffer (Node version) → append-only JSONL file.**
  Bash has no persistent in-process data structure shared between
  `bot.sh` and however many `handle_request.sh` processes are currently
  serving clients (they're all separate processes), so history has to
  live somewhere all of them can see — a plain file was the simplest
  shared state available.

## Known limitations

- **No session Resume.** Real Discord clients reconnect with a `Resume`
  (op 6) using the last session ID + sequence number, replaying only
  what was missed. This bot doesn't implement that: every reconnect is a
  fresh `Identify`, bridged by one REST catch-up call for the gap. Fine
  for a demo bot that reconnects occasionally; Discord rate-limits
  `Identify` calls (roughly 1000/day per token), so a connection that
  flaps constantly would eventually get throttled.
- **No zombie-connection detection.** The heartbeat loop sends on a
  timer regardless of whether the previous heartbeat was ACKed; it
  doesn't proactively notice a socket that's silently stopped responding
  the way a real client (tracking missed ACKs) would. In practice a dead
  TCP connection is usually caught by `websocat`/the OS closing the
  socket, which ends the read loop and triggers a restart anyway.
- **Heavier per-message overhead.** Every dispatch event and every
  rendered field shells out to `jq` as a separate process; fine for a
  low-traffic test channel, not a substitute for an in-process event
  loop under high message volume.
- **Every SSE (re)connection replays the last 50 messages**, by design
  (it's how a freshly-opened tab sees recent history). `EventSource`
  reconnects automatically on any dropped connection — proxy idle
  timeouts, deploys, network blips — which means that same replay can
  happen mid-session, not just on first load. `client.js` dedupes by
  Discord's message ID to avoid rendering the replayed backlog twice; if
  a client is ever shown messages without stable IDs, this breaks.
- **No log rotation.** `data/messages.jsonl` grows forever. An earlier
  version of this script trimmed it (`tail -n N | mv`), but that rename
  made `tail -F` in `handle_request.sh` re-detect the file as "new" and
  replay its entire (trimmed) contents to already-connected clients —
  a real duplicate-message bug caught while testing. Rather than ship
  that, trimming was removed; a production version would need rotation
  that doesn't fight the tailer, or history storage outside a flat file.
- **No persistence across restarts/redeploys.** `data/` is plain
  container-local disk. A redeploy or crash loses history (the bot does
  resume live-streaming from Discord's last-seen ID via the REST
  catch-up, so it won't re-flood messages, but old history is gone)
  unless a Railway volume is attached to `/app/data`.
- **Single instance only.** One bot process, one shared file. Running
  multiple Railway replicas would mean multiple competing Gateway
  connections (Discord permits this, but) each duplicating every message
  into its own instance's local file.
- **One hard-coded channel**, and **no auth** on the front-end — anyone
  with the URL can view the feed. Both fine for a demo on a throwaway
  test channel, not for a private/production channel.
- **No message edit/delete handling** — only `MESSAGE_CREATE` is
  handled; edits and deletions in Discord aren't reflected.
- **Attachments are linked, not proxied** — images/files point directly
  at Discord's CDN URLs, which are time-limited signed URLs; fine for
  live viewing, but a link shared later may expire.
