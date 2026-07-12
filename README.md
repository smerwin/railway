# Discord Live Feed (bash edition)

A Discord bot + web front-end that streams messages from a Discord channel
into a browser in real time — implemented entirely in bash (plus `curl`,
`jq`, `socat`, and [`websocat`](https://github.com/vi/websocat)). No
language runtime required.

**Live demo:** https://railway-production-240f.up.railway.app

## Why bash?

Because we can. There's no engineering reason to pick bash over
Node/Python/Go here — see "Alternatives considered" for where the honest
answer is "bash makes this harder, not better." The point was to see
what's left of "stream a Discord channel to a live web page" once the
language runtime is stripped away: a shell, a few CLI tools, and bash's
own process/file plumbing.

That constraint surfaces things a runtime normally hides. Discord's
Gateway is raw JSON opcodes over a WebSocket (Hello → Identify →
heartbeat → Dispatch); here that's a `while read` loop and a background
heartbeat job instead of an event listener. Concurrency is `socat`
forking a process per connection, not an event loop. And since the bot
and web-server scripts share no memory, the shared state is a JSON-lines
file on disk, tailed like a log — which is where most of "Known
limitations" below comes from.

## How it works

Three shell scripts, one container:

1. **Bot** ([`bin/bot.sh`](bin/bot.sh)) connects to Discord's Gateway via
   `websocat` run as a bash `coproc`. It reads `Hello` for the heartbeat
   interval, sends `Identify`, starts a background heartbeat loop, and
   reads dispatch events in the foreground. `MESSAGE_CREATE`/`MESSAGE_UPDATE`
   get reshaped with `jq` into one JSON object per line in
   `data/messages.jsonl`, tagged `kind: create/update`; `MESSAGE_DELETE`
   becomes `{"kind":"delete","id":...}`.

   Before connecting, and after every reconnect, it also runs a REST
   catch-up call so messages posted while disconnected aren't lost.
2. **Web server** ([`bin/handle_request.sh`](bin/handle_request.sh), via
   [`run.sh`](run.sh)) — `socat` listens on `$PORT` and forks a copy of
   `handle_request.sh` per connection. It serves static files from
   `public/`, or opens an [SSE](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
   stream at `/events`: replay the last 50 lines of `messages.jsonl`,
   then `tail` the file forever.
3. **Log rotation** ([`bin/rotate_logs.sh`](bin/rotate_logs.sh), also via
   `run.sh`) — keeps `messages.jsonl` from growing forever without
   disrupting the `tail -F` clients from step 2. See
   [Log rotation](#log-rotation).

The front-end (`public/client.js`) opens `new EventSource('/events')` and
renders every event it receives — history and live messages arrive
through the same stream, in order. Message text is inserted via
`textContent`, never `innerHTML`, so Discord content can't execute as
script.

```
Discord Gateway (wss) <==coproc==> websocat <--stdin/stdout--> bot.sh --append--> messages.jsonl <--tail-- handle_request.sh --SSE--> browser (EventSource)
                                                                  ^                        ^
                                                    REST catch-up (on start/reconnect)      rotate_logs.sh (copytruncate, by size)
```

If the bot process dies, `run.sh`'s supervisor restarts it a few seconds
later. No session Resume is implemented — every reconnect starts fresh.

### The tricky parts

- **The heartbeat can't write to `${GW[1]}` directly.** It runs as a
  background job so it can fire on its own timer, but bash closes a
  coprocess's file descriptors in forked children — writes from a
  background job fail with "Bad file descriptor." Fix: duplicate the fd
  to a fixed number (`exec 70>&"${GW[1]}"`) before backgrounding
  anything, and have the heartbeat write to fd 70.
- **Gateway intents subscribe to every channel, not just ours.** There's
  no per-channel subscription — `GUILD_MESSAGES` gets `MESSAGE_CREATE`
  for every channel in every guild the bot can see. `bot.sh` filters by
  `DISCORD_CHANNEL_ID` itself; skip that check and other channels leak
  into the feed silently.
- **`tail -F` and file rotation don't mix with SSE, unless rotation
  never replaces the file.** An earlier version trimmed `messages.jsonl`
  with `tail -n N | mv`; the rename made `tail -F` treat it as a new
  file and replay the trimmed contents as if they were new messages.
  Rotation (below) works around this by truncating in place instead.
- **`EventSource` reconnecting looks identical, server-side, to a new
  tab opening.** Both get the same "replay last 50, then follow"
  response, so `client.js` dedupes by message ID instead of the server
  tracking per-client state.

## Log rotation

[`bin/rotate_logs.sh`](bin/rotate_logs.sh) checks `messages.jsonl`'s
size every `LOG_ROTATE_INTERVAL_SEC` (default 60s), and once it crosses
`LOG_ROTATE_MAX_BYTES` (default 5MiB), copies it to
`messages.jsonl.<UTC timestamp>` and truncates the original *in place*
— same path, same inode — keeping the newest `LOG_ROTATE_KEEP` (default
5) archives.

This is copytruncate, not rename-and-recreate, because both
alternatives break `tail -F`: trimming with `mv` replays old content to
connected clients (see "The tricky parts"); renaming the file away and
letting it get recreated avoids that, but `tail -F` then resumes from
the new file's *current* size on reopen, silently dropping anything
written before it noticed the swap — verified to lose whole batches of
messages under realistic timing, not just an edge case.

Truncating in place sidesteps both: `tail -F` never reopens anything,
so its normal truncation handling just keeps reading forward. The one
remaining cost — standard for copytruncate, same as nginx/rsyslog — is
a narrow race where a line written between the copy and the truncate
can be skipped by clients attached at that instant. Testing put the
worst case at a single message, never a batch, and it's preserved in
the archive either way.

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

- **`DISCORD_BOT_TOKEN`** — from the
  [Discord Developer Portal](https://discord.com/developers/applications)
  (Bot tab → Reset Token), with **Message Content Intent** enabled (Bot →
  Privileged Gateway Intents) — Discord rejects the Gateway connection
  without it.
- **`DISCORD_CHANNEL_ID`** — turn on Developer Mode (User Settings →
  Advanced), then right-click the channel → Copy Channel ID.
- Invite the bot to a server with the `bot` scope and "Read Message
  History" + "View Channel" permissions.

Then open `http://localhost:3000` and post a message — it should appear
in well under a second.

## Testing

```bash
test/run_bot_test.sh
```

Runs `bin/bot.sh` against `test/fake_websocat`, a stand-in for the real
`websocat` binary that scripts a full Gateway handshake without a real
token or network access. Asserts on the resulting
`messages.jsonl`/`last_id` — channel filtering, edits/deletes, the
partial-update skip, heartbeat delivery — in an isolated temp
`DATA_DIR`. Exits non-zero on failure, so it's CI-safe.

## Deploying on Railway

Needs a real OS with `bash`/`curl`/`jq`/`socat`/`websocat`, which
Nixpacks has no reason to provide for a repo with no `package.json`.
This repo ships a [`Dockerfile`](Dockerfile) (Debian slim + those
packages) and [`railway.json`](railway.json) points Railway at the
`DOCKERFILE` builder.

1. Push to GitHub and create a Railway project from it (or `railway up`).
2. Set `DISCORD_BOT_TOKEN` and `DISCORD_CHANNEL_ID` in the **Variables**
   tab. Railway supplies `PORT` automatically.
3. Open the generated `*.up.railway.app` URL — this app's own instance
   is at https://railway-production-240f.up.railway.app.

## Alternatives considered

This app previously existed as a Node.js/discord.js implementation,
then a pure-bash version that REST-polled Discord instead of using the
Gateway. `websocat` changed that: it handles the WebSocket protocol
itself and exposes it as line-based stdin/stdout, so bash only has to
speak Discord's *Gateway* protocol on top.

- **REST polling → Gateway push.** Real push delivery, at the cost of a
  `coproc`, a heartbeat sharing state via a file, explicit opcode
  handling, and no session Resume.
- **WebSockets → SSE for the browser leg.** SSE is a plain HTTP response
  the server only writes to, and `EventSource` handles reconnection for
  free — no benefit to a hand-rolled `websocat` reconnect on a leg where
  the browser never sends anything back.
- **`socat ... fork` vs. a hand-rolled bash TCP server.** `fork` hands
  each connection its own process instead of writing an accept loop by
  hand.
- **In-memory ring buffer (Node version) → append-only JSONL file.**
  `bot.sh` and however many `handle_request.sh` processes are running
  share no memory, so history has to live in something all of them can
  see.

## Postmortem: the Gateway connection incident

For a while after deploying, the bot could reach Discord's Gateway but
never held a stable session — it kept reconnecting, and messages took
minutes to show up.

**Root cause:** a stray whitespace character in `DISCORD_BOT_TOKEN` on
Railway. HTTP headers get trimmed by servers, so REST calls tolerated
it; the Gateway's `Identify` compares the token byte-for-byte as a raw
JSON string, so every Gateway session got rejected while REST calls
kept working.

Cloudflare bot-management, Railway's shared-egress IP reputation,
Discord's Identify rate limit, and a heartbeat-timing bug were all ruled
out with real tests before the token turned out to be the answer.
Sorry, Railway network team — it was never you.

**Fixes kept:** `bot.sh` now trims the token defensively. `run.sh` backs
off exponentially (3s → 60s cap) instead of hammering the Gateway on a
fixed loop, and `bot.sh` bounds the wait for `Hello` to 10 seconds with
a forceful cleanup instead of trusting `websocat`'s own shutdown timing.

## Known limitations

- **No session Resume.** Every reconnect is a fresh `Identify` plus one
  REST catch-up call, instead of a proper `Resume` (op 6). Fine for
  occasional reconnects; Discord rate-limits `Identify` (~1000/day), so
  constant flapping would eventually get throttled.
- **No zombie-connection detection.** The heartbeat sends on a timer
  regardless of ACKs — in practice a dead TCP connection gets caught by
  the OS closing the socket, which triggers a restart anyway.
- **Heavier per-message overhead.** Every dispatch event shells out to
  `jq` as a separate process — fine for a low-traffic channel, not a
  substitute for an in-process event loop at scale.
- **Every SSE (re)connection replays the last 50 messages**, by design.
  `client.js` dedupes by message ID so a reconnect mid-session doesn't
  render the backlog twice.
- **No persistence across restarts/redeploys.** `data/` is plain
  container-local disk, including rotated archives — a redeploy or
  crash loses history (the bot won't re-flood messages, thanks to REST
  catch-up, but old history is gone) unless a Railway volume is
  attached. No `gzip` in the image either, by choice, so archives stay
  uncompressed.
- **Single instance only.** One bot process, one shared file. Multiple
  Railway replicas would mean multiple competing Gateway connections
  each duplicating messages into their own local file.
- **One hard-coded channel**, and **no auth** on the front-end — anyone
  with the URL can view the feed.
- **Live edits/deletes are handled; ones missed while disconnected
  aren't.** REST catch-up only fetches messages *after* the last-seen
  ID, so it can't learn that an older message was edited or deleted
  while disconnected.
- **Attachments are linked, not proxied** — Discord's CDN URLs are
  time-limited, so a link shared later may expire.
