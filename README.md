# Discord Live Feed (bash edition)

A Discord bot + web front-end that streams messages from a Discord channel
into a browser in real time — implemented entirely in bash (plus `curl`,
`jq`, `socat`, and [`websocat`](https://github.com/vi/websocat)), no
language runtime required.

**Live demo:** https://railway-production-240f.up.railway.app

## Why bash?

Because we can. There's no engineering reason to build this in bash over
Node/Python/Go — the "Alternatives considered" section below is a running
list of places where the honest answer to "why not do it the normal way"
is "bash makes this harder, not better." The point of building it this way
was to see how much of "a bot that streams a Discord channel to a live
web page" survives when you strip away the language runtime and the
framework and are left with only: a shell, a handful of small
purpose-built CLI tools (`curl`, `jq`, `socat`, `websocat`), and whatever
process/file-descriptor plumbing bash itself provides.

That constraint forces you to deal directly with things a runtime
normally hides: Discord's Gateway protocol is a raw sequence of JSON
opcodes over a WebSocket (Hello → Identify → heartbeat-on-a-timer →
Dispatch), and in discord.js that's a `client.on('messageCreate', ...)`
callback — here it's a `while read` loop pattern-matching on `.op` and a
background job sending a timestamped heartbeat, because bash doesn't have
event listeners, only processes, pipes, and files. Concurrency isn't
`async`/await or an event loop; it's `socat` forking a new OS process per
HTTP connection. There's no in-memory data structure shared between "the
part that talks to Discord" and "the part that talks to the browser"
because those are two separate bash scripts running as two separate
processes — so the shared state is a JSON-lines file on disk, tailed like
a log. Every one of the "Known limitations" below is a direct consequence
of that constraint, not a corner cut out of laziness — see
"Alternatives considered" for what each of those trade-offs actually
bought or cost.

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
     `MESSAGE_CREATE`, `MESSAGE_UPDATE` (edits), and `MESSAGE_DELETE`
     events for our channel. Creates and updates get reshaped with `jq`
     into a small JSON object (author, avatar URL, content, timestamp,
     attachments) tagged with a `kind`; deletes — whose Gateway payload
     is just `{id, channel_id}`, nothing else — become a bare
     `{"kind":"delete","id":...}`. Each becomes one line appended to
     `data/messages.jsonl`.

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

### The tricky parts

A few things in `bin/bot.sh` and `bin/handle_request.sh` aren't obvious
from reading them casually, and each cost real debugging time — worth
calling out explicitly rather than leaving as unexplained-looking code:

- **The heartbeat can't write to `${GW[1]}` directly.** The heartbeat is
  a background job (`( while true; do sleep ...; done ) &`) so it can
  fire on its own timer without blocking the main dispatch loop. But bash
  closes a coprocess's file descriptors in forked child processes —
  that's a documented bash limitation, not a bug in this script — so a
  background job can't use `${GW[1]}` (the coproc's write end) at all;
  attempting to write to it fails with "Bad file descriptor" every
  time, not just at shutdown. The fix is to duplicate that fd to a fixed
  number (`exec 70>&"${GW[1]}"`) *in the foreground*, before backgrounding
  anything, and have the background job write to fd 70 instead. Confirmed
  by testing against a stub `websocat` that logs everything it receives
  on stdin: heartbeats never arrived until this fix, silently, with no
  error visible unless stderr suppression was temporarily removed to
  look for it.
- **Gateway intents subscribe to every channel, not just ours.** There's
  no per-channel Gateway subscription in Discord's API — enabling
  `GUILD_MESSAGES` gets you `MESSAGE_CREATE` events for every channel in
  every guild the bot can see. `DISCORD_CHANNEL_ID` only matters because
  `bot.sh` explicitly checks `.d.channel_id` against it before appending
  anything. This is easy to miss because it doesn't fail loudly — it
  just quietly leaks messages from other channels into the feed. (The
  original Node.js version had this same filter in its `messageCreate`
  handler; it got dropped in the first pass of the bash rewrite and was
  only caught by testing with a fake multi-channel event stream.)
- **`tail -F` and file rotation don't mix with SSE.** Covered in
  Limitations below, but worth flagging here as a design constraint: any
  future change to how `messages.jsonl` is written has to preserve
  "append-only, never rename/truncate the file out from under an active
  `tail -F`," because a previous version that trimmed the file this way
  caused already-connected clients to have the trimmed contents replayed
  to them as if they were new messages.
- **`EventSource` reconnecting is indistinguishable, from the server's
  side, from a brand-new tab opening.** Both send a fresh request to
  `/events` and both get the same "replay last 50, then follow" response.
  The server has no notion of "this client already saw some of this" —
  that had to be pushed to the client (`client.js` deduping by message
  ID), because there's no cheap way to give a stateless-per-connection
  shell script server the concept of a client-specific replay cursor
  without adding real session state.

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
   live feed. This app's own instance is at
   https://railway-production-240f.up.railway.app.

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

- **Resolved: the Discord Gateway connection didn't survive long enough
  to become a stable session.** Root cause turned out to be a single
  whitespace character in a config value, not a bug in this codebase —
  but it took a long chain of hypotheses to get there, worth recording
  in full since most of them didn't pan out:

  1. Initial deploy logs showed `websocat: WebSocketError: I/O failure`
     with no detail. Adding `websocat -v` revealed the real picture: TCP
     connects, TLS succeeds, the WS upgrade itself succeeds (matching
     `sec-websocket-accept`) — then a close frame arrives, sometimes
     before `Hello` is ever sent, sometimes (per later logs) after.
  2. The close responses carry a Cloudflare `__cf_bm` bot-management
     cookie, which looked like a smoking gun for IP-reputation-based
     blocking on Railway's shared egress range. That theory took a real
     hit when `websocat` run from a non-Railway network hit the *exact
     same* immediate-close behavior — same tool, different network, same
     result — which argued against "it's Railway's IP" specifically.
     (In hindsight, `__cf_bm` is issued on most connections through
     Cloudflare's edge regardless of whether anything gets blocked, so
     its presence alone was weaker evidence than it looked.)
  3. Per-line deploy log timestamps then showed something orthogonal:
     `run.sh: bot exited after 83s` — identically, three restarts in a
     row. A fixed, exactly-repeated duration across attempts (not
     jittery like real network variance) pointed at an internal timeout
     rather than an external block. 83s is suspiciously close to 2×
     Discord's real heartbeat interval (41.25s) — the standard "zombied
     connection" grace period Gateway implementations use when a client
     doesn't heartbeat in time. That would mean the connection *is*
     surviving past `Hello`/`Identify`, and something in `bot.sh`'s own
     heartbeat delivery isn't reliably reaching Discord over a real
     ~41s interval (as opposed to the 1s interval used in local stub
     testing, which never exercised this).

  4. With that logging added, the next deploy showed something more
     specific than point 3's guess: `Hello` arrives and gets parsed
     correctly (`heartbeat_interval=41250ms`), `Identify` gets sent —
     and then *nothing*. No `Ready`, no `Invalid Session`, not even one
     more dispatch logged, before the close. That rules out the
     heartbeat-timing theory (it never got far enough to need a
     heartbeat) and points at something rejecting the session
     immediately upon processing `Identify` specifically.

     Discord documents exactly this class of limit: a bot token gets a
     capped number of `Identify` calls per rolling window (1000/day),
     plus a `max_concurrency` on session starts. Given how aggressively
     this bot was reconnecting before the backoff fix — a fixed 3-second
     loop, for however long the earlier close-before-`Hello` failures
     had been going on — it's plausible this token burned through that
     budget. Unlike the earlier theories, this one is directly checkable
     rather than inferred: Discord's `GET /gateway/bot` endpoint returns
     the exact remaining count. `bot.sh` now logs it
     (`bot: session_start_limit: {...}`) before every connection
     attempt, so the next deploy's logs will show `remaining` and
     `reset_after` directly instead of more speculation.

  5. The next deploy's `session_start_limit` log came back completely
     clean — `remaining: 1000` of `1000` — ruling out the Identify-budget
     theory outright. Message Content Intent was also confirmed already
     enabled in the Developer Portal (ruling out the same 4014 rejection
     I'd independently hit in an earlier, unrelated test with this
     token). Both plausible, checkable theories, both eliminated.
  6. That left one piece of information neither `bot.sh` nor `websocat
     -v` could surface: the actual numeric WebSocket close code Discord
     sends (`websocat` has no flag for it). A small Node.js script using
     the `ws` library — which does expose `code`/`reason` on close —
     run from a non-Railway network with the identical token and
     intents, completed a full session cleanly: `Hello` → `Identify` →
     `Ready` → `Guild_Create`, closed normally. Token, intents, and
     payload shape were all fine.
  7. That still left two candidates: Railway's network, or `websocat`
     itself as a client (maybe its framing/timing of `Identify`
     specifically). Deciding between them needed the *same tool*
     (`websocat`) tested through a *full* Identify from a non-Railway
     network — something the very first cross-network test (point 2)
     hadn't actually done; it only confirmed `Hello` arrived, then
     stopped there. Doing that properly settled it: `websocat`, from the
     same home network, sent the identical `Identify` payload bot.sh
     sends and got back a complete, successful session (`READY` as the
     bot user, a real `GUILD_CREATE` for the target server).

  8. Point 7 left the network as the only remaining variable, by
     elimination — every application-level thing (token, intents, rate
     limit, payload shape, client library) had been tested and cleared.
     That reasoning was sound, but the elimination itself had a gap: a
     small diagnostic script logging the token's exact length, before
     and after trimming, without ever printing the token itself, found
     it — 73 characters raw, 72 trimmed. One stray whitespace character
     in Railway's `DISCORD_BOT_TOKEN` value. REST calls tolerated it
     silently (an HTTP `Authorization` header, commonly trimmed by
     servers); the Gateway's `Identify` didn't (a raw JSON string,
     compared byte-for-byte) — which is exactly the REST-succeeds/
     Gateway-fails asymmetry that had been the central puzzle since
     point 4, and exactly why `websocat` failed identically to real
     Node/`ws` once tested with the actual production token: both were
     sending the same corrupted string.

  Actual resolution: `bot.sh` now trims `DISCORD_BOT_TOKEN` before using
  it (pure bash parameter expansion, no subshell). Every network-level
  theory in this section — Cloudflare bot-management, IP reputation,
  Railway's egress range — was a red herring. The entire investigation,
  start to finish, was chasing a config data-entry error: one whitespace
  character, pasted into a dashboard text field, invisible there,
  silently tolerated by every REST call this bot made, and fatal to
  every single Gateway connection attempt.

  A brief apology to Railway's network team: a large fraction of this
  document accused your shared egress IP range of being reputation-
  flagged, rate-limited, or otherwise unwelcome at Discord's door. It
  was never your network. It was whitespace. Sorry.

  Several fixes from earlier rounds of this investigation remain
  worthwhile regardless: `run.sh` backs off exponentially (3s → 60s cap,
  resetting after a 30s+ run) instead of hammering the Gateway on a
  fixed 3s loop, `bot.sh` bounds the wait for `Hello` to 10 seconds with
  a forceful (`kill -9`) cleanup rather than trusting `websocat`'s own
  shutdown timing (which is what turned "retry every few seconds" into
  "retry every couple of minutes" and is likely the real explanation for
  why messages were taking minutes to appear, independent of the network
  issue above), and the dispatch/heartbeat logging added along the way
  is useful instrumentation on its own merits.

  Two things tried and abandoned: a speculative `User-Agent` header (in
  case bot-detection heuristics were involved) hit a `websocat -H`
  argument-parsing gotcha with no local binary available to verify a fix
  against, and outbound IPv6 was ruled out by DNS lookup before writing
  any code — neither `discord.com` nor `gateway.discord.gg` publish an
  `AAAA` record at all (confirmed against `www.cloudflare.com`, which
  does, to rule out a resolver-level false negative).
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
- **Live edits and deletes are handled; ones missed while disconnected
  aren't.** `MESSAGE_UPDATE` and `MESSAGE_DELETE` both update the DOM in
  place by looking up the existing message via its Discord message ID
  (`(edited)` marker for updates, removal for deletes). But `catch_up`'s
  REST call only fetches messages *after* the last-seen ID — it has no
  way to learn that an older, already-recorded message was edited or
  deleted while the bot was disconnected, since Discord's message-list
  endpoint doesn't surface a "deleted" state at all, and only returns a
  message's *current* content, not a diff. An edit/delete of a message
  the client never rendered in the first place (outside the last-50
  replay window) is a no-op for a delete, and falls back to appearing as
  a new entry for an edit — better than silently dropping it, but not
  fully correct either.
- **Attachments are linked, not proxied** — images/files point directly
  at Discord's CDN URLs, which are time-limited signed URLs; fine for
  live viewing, but a link shared later may expire.
