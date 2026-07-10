# Discord Live Feed (bash edition)

A Discord bot + web front-end that streams messages from a Discord channel
into a browser in real time — implemented entirely in bash (plus `curl`,
`jq`, and `socat`), no language runtime required.

**Live demo:** _add your Railway URL here after deploying_

## How it works

Everything runs as two shell scripts inside one container:

1. **Poller** ([`bin/poller.sh`](bin/poller.sh)) — a loop that calls the
   Discord REST API (`GET /channels/{id}/messages`) every
   `POLL_INTERVAL_SECONDS` (default 2s), asking for anything newer than the
   last message ID it's seen (`?after=...`). Each new message is reshaped
   with `jq` into a small JSON object (author, avatar URL, content,
   timestamp, attachments) and appended as one line to
   `data/messages.jsonl`. The last-seen ID is checkpointed to
   `data/last_id` so a restart resumes roughly where it left off instead
   of re-streaming the whole channel history.
2. **Web server** ([`bin/handle_request.sh`](bin/handle_request.sh), run
   via [`run.sh`](run.sh)) — [`socat`](http://www.dest-unreach.org/socat/)
   listens on `$PORT` and forks a copy of `handle_request.sh` per
   connection (socat's `fork` option gives free concurrency without bash
   having to manage sockets itself). That script reads the raw HTTP
   request off stdin and, depending on the path, either serves a static
   file from `public/` or opens a
   [Server-Sent Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
   stream at `/events`: it replays the last 50 lines of
   `messages.jsonl` and then `tail`s the file forever, turning each new
   line into an SSE `data: ...` event as the poller appends it.

The front-end (`public/client.js`) just opens `new EventSource('/events')`
and renders every event it receives — no distinction between "history" and
"live" messages, since the tail-replay already delivers both through the
same stream in order. Message text is inserted via `textContent` (never
`innerHTML`), so arbitrary content posted in Discord can't execute as
HTML/script in the browser.

```
Discord REST API <--poll-- poller.sh --append--> messages.jsonl <--tail-- handle_request.sh --SSE--> browser (EventSource)
```

## Running locally

Requires `bash`, `curl`, `jq`, and `socat` on PATH (`apt install socat` /
`brew install socat` — the other three are usually already present).

```bash
cp .env.example .env   # fill in the two required values below
set -a; source .env; set +a
./run.sh
```

You need:

- **`DISCORD_BOT_TOKEN`** — create an application at the
  [Discord Developer Portal](https://discord.com/developers/applications)
  and add a Bot user (Bot tab → Reset Token).
- **`DISCORD_CHANNEL_ID`** — the channel to stream. Turn on Developer Mode
  (User Settings → Advanced) and right-click a channel → Copy Channel ID.
- Invite the bot to a server with the `bot` scope and "Read Message
  History" + "View Channel" permissions, via the OAuth2 URL generator in
  the developer portal.

Then open `http://localhost:3000` and post a message in the channel — it
should show up within `POLL_INTERVAL_SECONDS`.

## Deploying on Railway

This needs a real OS with `bash`/`curl`/`jq`/`socat` installed, which
Railway's Nixpacks auto-detection has no reason to provide for a repo with
no `package.json`/`requirements.txt`/etc. So this repo ships a
[`Dockerfile`](Dockerfile) (Debian slim + those four packages) and
[`railway.json`](railway.json) points Railway at the `DOCKERFILE` builder.

1. Push this repo to GitHub and create a new Railway project from it (or
   `railway up` from the CLI). Railway builds the `Dockerfile`.
2. In the Railway project's **Variables** tab, set `DISCORD_BOT_TOKEN` and
   `DISCORD_CHANNEL_ID`. Railway supplies `PORT` automatically.
3. Once deployed, open the generated `*.up.railway.app` URL — that's the
   live feed.

## Alternatives considered

This app previously existed as a straightforward Node.js/discord.js
implementation using the real Discord Gateway (a push-based WebSocket) and
a `ws` WebSocket server to the browser. That version is the one I'd
actually ship — bash was a deliberate constraint for this exercise, not a
recommendation, and the rewrite required trading a better architecture for
a worse one at nearly every layer:

- **Gateway WebSocket → REST polling.** Discord's Gateway is itself a
  WebSocket protocol with a JSON handshake, heartbeats, and session
  resume logic. Implementing a WebSocket client by hand in bash (framing,
  masking, TLS) is possible but not a reasonable amount of shell script;
  polling `GET /messages?after=...` with `curl` is the pragmatic
  bash-shaped substitute. The cost is real: latency is bounded by the
  poll interval instead of being push/sub-second, and polling burns a
  request every interval regardless of whether anyone posted, which
  doesn't scale to many channels.
- **WebSockets → Server-Sent Events for the browser leg.** SSE is a
  better fit for a shell backend than WebSockets: it's a plain HTTP
  response the server only ever writes to, so `handle_request.sh` never
  has to parse an incoming WebSocket frame, and the browser's built-in
  `EventSource` handles reconnection automatically — bash doesn't need
  to implement retry/backoff on either side. The trade is one-directional
  only, which is fine here since the browser never needs to send
  anything back.
- **`socat ... fork` vs. a hand-rolled bash TCP server.** Bash can open
  a listening socket itself (`exec 3<>/dev/tcp/...` tricks, or
  `coproc`), but handling multiple concurrent long-lived SSE connections
  that way means bash doing its own `select`/accept loop, which is
  fragile and slow. `socat`'s `fork` mode hands each connection to its
  own `handle_request.sh` process, so concurrency is "one shell script
  per client" rather than something bash has to schedule itself.
- **In-memory ring buffer (Node version) → append-only JSONL file.**
  Bash has no persistent in-process data structure between the poller
  and however many `handle_request.sh` processes are currently serving
  clients (they're separate processes), so history has to live somewhere
  both can see — a plain file was the simplest shared state available.

## Known limitations

- **Polling latency, not push.** New messages take up to
  `POLL_INTERVAL_SECONDS` to appear, and each poll is a REST call whether
  or not anything changed. Lowering the interval trades latency for a
  higher chance of hitting Discord's rate limits (the poller backs off on
  `retry_after` if it does).
- **Heavier per-message overhead.** Every poll and every rendered field
  shells out to `curl`/`jq` as separate processes; this is fine for a
  low-traffic test channel and would not hold up under high message
  volume or many concurrent viewers the way an in-process Node/Python
  event loop would.
- **No log rotation.** `data/messages.jsonl` grows forever. An earlier
  version of this script trimmed it (`tail -n N | mv`), but that rename
  made `tail -F` in `handle_request.sh` re-detect the file as "new" and
  replay its entire (trimmed) contents to already-connected clients —
  a real duplicate-message bug caught while testing. Rather than ship
  that, trimming was removed; a production version would need rotation
  that doesn't fight the tailer (e.g. `truncate`-in-place with byte-range
  bookkeeping, or moving history storage out of a flat file entirely).
- **No persistence across restarts/redeploys.** `data/` is plain
  container-local disk. A redeploy or crash loses history (the poller
  does resume live-streaming from Discord's last-seen ID, so it won't
  re-flood messages, but old history is gone) unless a Railway volume is
  attached to `/app/data`.
- **Single instance only.** One poller, one shared file. Running
  multiple Railway replicas would mean multiple competing pollers
  duplicating every message into diverging local files.
- **One hard-coded channel**, and **no auth** on the front-end — anyone
  with the URL can view the feed. Both fine for a demo on a throwaway
  test channel, not for a private/production channel.
- **No message edit/delete handling** — only new messages are picked up;
  edits and deletions in Discord aren't reflected.
- **Attachments are linked, not proxied** — Images/files point directly
  at Discord's CDN URLs, which are time-limited signed URLs; fine for
  live viewing, but a link shared later may expire.
