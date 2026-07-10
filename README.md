# Discord Live Feed

A Discord bot + web front-end that streams messages from a Discord channel
into a browser in real time.

**Live demo:** _add your Railway URL here after deploying_

## How it works

The app is a single Node.js process with two responsibilities:

1. **Discord bot** ([`server/bot.js`](server/bot.js)) — a [discord.js](https://discord.js.org/)
   client connects to the Discord Gateway (a persistent WebSocket Discord
   itself exposes to bots) and subscribes to `messageCreate` events. Every
   message posted in the configured channel is normalized into a small JSON
   shape (author name/avatar, content, timestamp, attachments) and handed to
   a callback.
2. **Web server** ([`server/index.js`](server/index.js)) — an Express app
   serves the static front-end (`public/`) and runs a `ws` WebSocket server
   on the same HTTP port at `/ws`. The bot's callback broadcasts every new
   message to all connected WebSocket clients. The server also keeps the
   last 50 messages in memory so a browser that connects mid-conversation
   sees recent history instead of a blank page.

The front-end (`public/client.js`) opens a WebSocket to `/ws`, renders the
initial history batch, and appends each subsequent message as it arrives —
no polling, no page refresh. Message text is inserted via `textContent`
(never `innerHTML`), so arbitrary content posted in Discord can't execute as
HTML/script in the browser.

```
Discord channel --gateway--> bot.js --broadcast--> WebSocket server --push--> browser (client.js)
```

Both the bot and the web server run in the same process so there's a single
deployable unit and no separate message queue to operate — appropriate for
a demo/take-home project. It also means there is exactly one process
holding the WebSocket gateway connection, which matters for the scaling
discussion below.

## Running locally

```bash
npm install
cp .env.example .env   # then fill in the two values below
npm start
```

You need:

- **`DISCORD_BOT_TOKEN`** — create an application at the
  [Discord Developer Portal](https://discord.com/developers/applications),
  add a Bot user, and enable the **Message Content** privileged intent
  (Bot → Privileged Gateway Intents) — without it the bot receives message
  events with empty `content`.
- **`DISCORD_CHANNEL_ID`** — the channel to stream. Turn on Developer Mode
  (User Settings → Advanced) and right-click a channel → Copy Channel ID.
- Invite the bot to a server with the `bot` scope and "Read Message
  History" + "View Channel" permissions, via the OAuth2 URL generator in
  the developer portal.

Then open `http://localhost:3000` and post a message in the channel — it
should appear in the browser within a second.

## Deploying on Railway

1. Push this repo to GitHub and create a new Railway project from it (or
   `railway up` from the CLI). Railway's Nixpacks builder auto-detects the
   Node app from `package.json` and runs `npm install && npm start`.
2. In the Railway project's **Variables** tab, set `DISCORD_BOT_TOKEN` and
   `DISCORD_CHANNEL_ID`. Railway supplies `PORT` automatically.
3. Once deployed, open the generated `*.up.railway.app` URL — that's the
   live feed.

## Alternatives considered

- **Polling the REST API** instead of the Gateway. Simpler to reason about
  (no persistent connection to manage) but adds latency, burns rate limits
  as polling frequency increases, and doesn't scale well with more than a
  couple of clients. The Gateway push model is what Discord's own clients
  use and gives sub-second latency for free.
- **Discord webhooks** instead of a bot. Incoming webhooks only let you
  *post into* a channel; they can't observe messages other users send, so
  they don't fit "stream messages out of a channel" at all.
- **Server-Sent Events (SSE)** instead of WebSockets for the browser leg.
  SSE is simpler (plain HTTP, built-in reconnect) and would have been
  enough since the browser never needs to send data back. I chose
  WebSockets mainly because it's the more common expectation for "live
  chat" style UIs and leaves room to add features like message
  reactions/typing indicators without a re-architecture. SSE would be the
  leaner choice if the front-end really is read-only forever.
- **Persisting history to a database** (Postgres/Redis) instead of an
  in-memory ring buffer. Deliberately skipped for scope — see limitations.

## Known limitations

- **No message persistence.** History is an in-memory array capped at 50
  messages; a restart (deploy, crash, Railway sleep) clears it. A real
  product would persist messages to Postgres/Redis so history survives
  restarts and can be paginated.
- **Single-instance only.** The Gateway connection and the in-memory
  history both live in one process. Railway's autoscaling / multiple
  replicas would each open a competing Gateway connection and each hold a
  different slice of "recent history" for WebSocket clients connected to
  that particular instance. Scaling horizontally would need the bot
  process split out from the web/WebSocket process, with a pub/sub layer
  (Redis, NATS) fanning messages out to all web replicas.
- **One hard-coded channel.** The app streams a single channel set by env
  var; multi-channel/multi-server support would need a small mapping
  layer and per-channel WebSocket topics instead of a single broadcast.
- **No auth on the front-end.** Anyone with the URL can view the feed.
  Fine for a demo on a throwaway test channel; not appropriate for a
  private/production channel without adding access control.
- **No message edit/delete handling.** The feed only reacts to
  `messageCreate`; edits and deletions in Discord aren't reflected.
- **Attachments are linked, not proxied.** Images/files render by pointing
  directly at Discord's CDN URLs, which are time-limited signed URLs —
  fine for live viewing, but a link shared later may expire.
