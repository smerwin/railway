# Discord Live Feed (bash edition)

A Discord bot + web front-end that streams messages from a Discord channel
into a browser in real time — implemented entirely in bash (plus `curl`,
`jq`, `socat`, and [`websocat`](https://github.com/vi/websocat)). No
language runtime required.

**Live demo:** https://railway-production-240f.up.railway.app

## Why bash?

Because we can. There's no engineering reason to pick bash over
Node/Python/Go here — see "Alternatives considered" for the places where
the honest answer is "bash makes this harder, not better." The point was
to see what's left of "a bot that streams a Discord channel to a live web
page" once the language runtime and framework are stripped away, leaving
a shell, a few purpose-built CLI tools, and bash's own process/file
plumbing.

That constraint surfaces things a runtime normally hides. Discord's
Gateway is a raw sequence of JSON opcodes over a WebSocket (Hello →
Identify → heartbeat → Dispatch); in discord.js that's a
`client.on('messageCreate', ...)` callback, here it's a `while read` loop
and a background heartbeat job, since bash has no event listeners, only
processes and pipes. Concurrency is `socat` forking a process per
connection, not an event loop. And since the Discord-facing script and
the browser-facing script are separate processes with no shared memory,
the shared state is a JSON-lines file on disk, tailed like a log. The
"Known limitations" below follow directly from these constraints.

## How it works

Two shell scripts, one container:

1. **Bot** ([`bin/bot.sh`](bin/bot.sh)) connects to Discord's Gateway via
   `websocat` run as a bash `coproc` (a background process bash can both
   write to and read from). It reads `Hello` for the heartbeat interval,
   sends `Identify`, starts a background heartbeat loop, and reads
   dispatch events in the foreground. `MESSAGE_CREATE`/`MESSAGE_UPDATE`
   get reshaped with `jq` into a small JSON object tagged
   `kind: create/update`; `MESSAGE_DELETE` (payload is just
   `{id, channel_id}`) becomes `{"kind":"delete","id":...}`. Each becomes
   one line in `data/messages.jsonl`.

   Before connecting, and after every reconnect, it also runs a REST
   catch-up call (`GET /channels/{id}/messages?after=<last-seen-id>`) so
   messages posted while disconnected aren't lost.
2. **Web server** ([`bin/handle_request.sh`](bin/handle_request.sh), via
   [`run.sh`](run.sh)) — `socat` listens on `$PORT` and forks a copy of
   `handle_request.sh` per connection. That script serves static files
   from `public/`, or opens an [SSE](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
   stream at `/events`: replay the last 50 lines of `messages.jsonl`,
   then `tail` the file forever, turning each new line into an SSE event.

The front-end (`public/client.js`) opens `new EventSource('/events')` and
renders every event it receives — history and live messages arrive
through the same stream, in order, so there's no distinction to make.
Message text is inserted via `textContent`, never `innerHTML`, so
arbitrary content posted in Discord can't execute as script in the
browser.

```
Discord Gateway (wss) <==coproc==> websocat <--stdin/stdout--> bot.sh --append--> messages.jsonl <--tail-- handle_request.sh --SSE--> browser (EventSource)
                                                                  ^
                                                    REST catch-up (on start/reconnect)
```

If the bot process dies (socket drop, Discord requesting a reconnect, an
invalid session), `run.sh`'s supervisor restarts it a few seconds later.
No session Resume is implemented — every reconnect starts fresh.

### The tricky parts

A few things in `bin/bot.sh` and `bin/handle_request.sh` cost real
debugging time:

- **The heartbeat can't write to `${GW[1]}` directly.** It runs as a
  background job so it can fire on its own timer without blocking the
  main dispatch loop. But bash closes a coprocess's file descriptors in
  forked children (a documented bash limitation) — a background job
  can't use `${GW[1]}` at all, and writes fail with "Bad file
  descriptor" every time, not just at shutdown. Fix: duplicate the fd to
  a fixed number (`exec 70>&"${GW[1]}"`) in the foreground, before
  backgrounding anything, and have the heartbeat write to fd 70 instead.
- **Gateway intents subscribe to every channel, not just ours.** There's
  no per-channel Gateway subscription — enabling `GUILD_MESSAGES` gets
  `MESSAGE_CREATE` for every channel in every guild the bot can see.
  `DISCORD_CHANNEL_ID` matters only because `bot.sh` explicitly checks
  `.d.channel_id` before appending anything. Easy to miss, since it
  fails quietly by leaking other channels into the feed instead of
  erroring.
- **`tail -F` and file rotation don't mix with SSE.** An earlier version
  trimmed `messages.jsonl` with `tail -n N | mv`, and the rename made
  `tail -F` in `handle_request.sh` treat it as a new file, replaying the
  trimmed contents to already-connected clients as if they were new
  messages. `messages.jsonl` has to stay append-only.
- **`EventSource` reconnecting looks identical, server-side, to a new
  tab opening.** Both hit `/events` fresh and get the same "replay last
  50, then follow" response. The server has no notion of what a given
  client has already seen, so `client.js` dedupes by message ID instead.

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
  Intent** (Bot → Privileged Gateway Intents). Required: `bot.sh`
  requests this intent in its Identify payload, and Discord rejects the
  connection if it isn't enabled.
- **`DISCORD_CHANNEL_ID`** — the channel to stream. Turn on Developer
  Mode (User Settings → Advanced), then right-click a channel → Copy
  Channel ID.
- Invite the bot to a server with the `bot` scope and "Read Message
  History" + "View Channel" permissions, via the OAuth2 URL generator in
  the developer portal.

Then open `http://localhost:3000` and post a message — it should appear
in well under a second.

## Deploying on Railway

This needs a real OS with `bash`/`curl`/`jq`/`socat`/`websocat`
installed, which Railway's Nixpacks has no reason to provide for a repo
with no `package.json`. So this repo ships a [`Dockerfile`](Dockerfile)
(Debian slim + those packages) and [`railway.json`](railway.json) points
Railway at the `DOCKERFILE` builder.

1. Push to GitHub and create a Railway project from it (or `railway up`).
2. In the project's **Variables** tab, set `DISCORD_BOT_TOKEN` and
   `DISCORD_CHANNEL_ID`. Railway supplies `PORT` automatically.
3. Open the generated `*.up.railway.app` URL. This app's own instance is
   at https://railway-production-240f.up.railway.app.

## Alternatives considered

This app previously existed as a Node.js/discord.js implementation, then
as a pure-bash version that REST-polled Discord instead of using the
Gateway (hand-rolling a WebSocket client's framing and TLS in bash isn't
reasonable). `websocat` changed that: it handles the WebSocket protocol
itself and exposes it as line-based stdin/stdout, so bash only has to
speak Discord's *Gateway* protocol on top.

- **REST polling → Gateway push.** Trades a polling loop (fixed latency,
  wasted requests) for real push delivery. Cost: a `coproc`, a
  background heartbeat needing to share state with the main loop via a
  file, explicit opcode handling, and no session Resume.
- **WebSockets → SSE for the browser leg**, still. SSE fits the browser
  side better: it's a plain HTTP response the server only ever writes
  to, and `EventSource` handles reconnection for free. Using `websocat`
  there too was considered, but it would mean a hand-rolled reconnect in
  `client.js` for no benefit, since the browser never sends anything
  back.
- **`socat ... fork` vs. a hand-rolled bash TCP server.** Bash can open a
  listening socket itself, but handling multiple concurrent SSE
  connections that way means writing its own accept loop. `socat`'s
  `fork` mode hands each connection to its own process instead.
- **In-memory ring buffer (Node version) → append-only JSONL file.**
  `bot.sh` and however many `handle_request.sh` processes are serving
  clients are separate processes with no shared memory, so history has
  to live in something all of them can see — a plain file was simplest.

## Postmortem: the Gateway connection incident

For a while after deploying, the bot could reach Discord's Gateway but
never held a stable session — it kept reconnecting, and messages took
minutes to show up.

### Root cause

A single stray whitespace character in the `DISCORD_BOT_TOKEN` value
configured on Railway. HTTP headers get trimmed by servers, so REST
calls tolerated it; the Gateway's `Identify` didn't, since it's a raw
JSON string compared byte-for-byte. REST calls succeeded while every
Gateway session got rejected right after `Identify`.

### Wrong turns along the way

Cloudflare bot-management, IP reputation on Railway's shared egress,
Discord's Identify rate limit, a heartbeat-timing bug — each ruled out
with a real test before the token turned out to be the answer.

### Apology to Railway's network team

We spent a large part of this investigation accusing your shared egress
IP range of being reputation-flagged, rate-limited, or otherwise
unwelcome at Discord's door. It was never your network. It was
whitespace. Sorry.

### Fixes kept from the investigation

`bot.sh` now trims the token defensively. Two other fixes are worth
keeping regardless of root cause: `run.sh` backs off exponentially (3s →
60s cap) instead of hammering the Gateway on a fixed loop, and `bot.sh`
bounds the wait for `Hello` to 10 seconds with a forceful cleanup rather
than trusting `websocat`'s own shutdown timing. A speculative
`User-Agent` header and outbound IPv6 were both explored and ruled out —
neither `discord.com` nor `gateway.discord.gg` publish an IPv6 address
at all.

## Known limitations

- **No session Resume.** Every reconnect is a fresh `Identify`, bridged
  by one REST catch-up call for the gap, instead of a proper `Resume`
  (op 6) replaying only what was missed. Fine for occasional reconnects;
  Discord rate-limits `Identify` (roughly 1000/day per token), so a
  connection that flaps constantly would eventually get throttled.
- **No zombie-connection detection.** The heartbeat loop sends on a
  timer regardless of whether the previous one was ACKed. In practice a
  dead TCP connection is usually caught by `websocat`/the OS closing the
  socket, which triggers a restart anyway.
- **Heavier per-message overhead.** Every dispatch event and rendered
  field shells out to `jq` as a separate process — fine for a low-
  traffic channel, not a substitute for an in-process event loop at
  scale.
- **Every SSE (re)connection replays the last 50 messages**, by design —
  it's how a freshly-opened tab sees recent history. `EventSource`
  reconnects automatically on any dropped connection, so that replay can
  happen mid-session too. `client.js` dedupes by message ID to avoid
  rendering the backlog twice.
- **Log rotation, by size, using copytruncate.** [`bin/rotate_logs.sh`](bin/rotate_logs.sh)
  runs alongside the bot and web server. Every `LOG_ROTATE_INTERVAL_SEC`
  (default 60s) it checks `messages.jsonl`'s size, and once it crosses
  `LOG_ROTATE_MAX_BYTES` (default 5MiB) it copies the file to
  `messages.jsonl.<UTC timestamp>`, then truncates `messages.jsonl` to
  empty *in place* — same path, same inode — keeping the newest
  `LOG_ROTATE_KEEP` (default 5) archives and deleting older ones. Two
  designs were tried and rejected before this one, both instructive:
    - Trimming with `tail -n N | mv` (an actual earlier version) replaces
      the file with a new, non-empty one at the same path. `tail -F` in
      `handle_request.sh` reads that as a brand-new file and replays its
      contents to already-connected SSE clients as if they were new
      messages — the duplicate-message bug described above.
    - Renaming the file away with nothing replacing it (tried while
      building this script) avoids that replay, but has the same failure
      class from the other direction: `tail -F`, on noticing its watched
      path got replaced, reopens and resumes from the new file's
      *current* size rather than from its start. Any lines written to the
      recreated file before tail got around to reopening it were silently
      dropped from the live stream — verified by testing to lose whole
      batches of messages under realistic write timing, not a rare edge
      case.

  Truncating in place sidesteps both: `tail -F` never reopens anything, so
  its ordinary truncation handling ("the file got smaller, keep reading
  forward from the new size") is what fires, with no reconnect-like reset.
  The one remaining trade-off — standard for copytruncate, e.g. what
  nginx/rsyslog default to — is a narrow race: a line written in the gap
  between the copy finishing and the truncate landing can be skipped by
  whichever SSE clients are attached at that instant. Verified by testing
  (realistic, spaced write timing across a rotation) to cost at most the
  single message straddling that instant, never a batch, and it's
  preserved in the archive on disk either way.
- **No persistence across restarts/redeploys.** `data/` is plain
  container-local disk. A redeploy or crash loses history (the bot
  resumes live-streaming via REST catch-up, so it won't re-flood
  messages, but old history is gone) unless a Railway volume is attached.
- **Single instance only.** One bot process, one shared file. Multiple
  Railway replicas would mean multiple competing Gateway connections
  each duplicating messages into their own local file.
- **One hard-coded channel**, and **no auth** on the front-end — anyone
  with the URL can view the feed. Fine for a demo channel, not for
  anything private.
- **Live edits and deletes are handled; ones missed while disconnected
  aren't.** `MESSAGE_UPDATE`/`MESSAGE_DELETE` update the DOM in place by
  message ID. But the REST catch-up only fetches messages *after* the
  last-seen ID — it can't learn that an older message was edited or
  deleted while disconnected, since Discord's message-list endpoint
  returns current content, not a diff, and no "deleted" state at all.
- **Attachments are linked, not proxied** — they point at Discord's CDN
  URLs, which are time-limited; fine for live viewing, but a link shared
  later may expire.
