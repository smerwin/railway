const path = require('path');
const http = require('http');
const express = require('express');
const { WebSocketServer } = require('ws');

const { startBot } = require('./bot');

const PORT = process.env.PORT || 3000;
const DISCORD_BOT_TOKEN = process.env.DISCORD_BOT_TOKEN;
const DISCORD_CHANNEL_ID = process.env.DISCORD_CHANNEL_ID;

if (!DISCORD_BOT_TOKEN || !DISCORD_CHANNEL_ID) {
  console.error(
    'Missing required env vars. Please set DISCORD_BOT_TOKEN and DISCORD_CHANNEL_ID.'
  );
  process.exit(1);
}

const app = express();
app.use(express.static(path.join(__dirname, '..', 'public')));
app.get('/health', (_req, res) => res.status(200).send('ok'));

const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/ws' });

function broadcast(message) {
  const payload = JSON.stringify({ type: 'message', data: message });
  for (const client of wss.clients) {
    if (client.readyState === client.OPEN) client.send(payload);
  }
}

const { history } = startBot({
  token: DISCORD_BOT_TOKEN,
  channelId: DISCORD_CHANNEL_ID,
  onMessage: broadcast,
});

wss.on('connection', (socket) => {
  socket.send(JSON.stringify({ type: 'history', data: history }));
});

server.listen(PORT, () => {
  console.log(`Web server listening on port ${PORT}`);
});
