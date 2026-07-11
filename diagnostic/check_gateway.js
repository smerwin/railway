// Temporary diagnostic, not part of the application. Runs once at
// container startup (see run.sh) to check whether a Node/ws client
// behaves differently from websocat when run *from Railway* -- the one
// variable not yet isolated in the Gateway connection investigation
// (see README's "Open issue" section). Delete this directory, its
// Dockerfile/run.sh hooks, and the Node/npm apt packages once answered.
const WebSocket = require('ws');

const TOKEN = process.env.DISCORD_BOT_TOKEN;
if (!TOKEN) {
  console.error('diagnostic: DISCORD_BOT_TOKEN not set, skipping');
  process.exit(0);
}

const INTENTS = 33281; // GUILDS(1) + GUILD_MESSAGES(512) + MESSAGE_CONTENT(32768)
const ws = new WebSocket('wss://gateway.discord.gg/?v=10&encoding=json');
let heartbeatTimer;

ws.on('open', () => console.log('diagnostic: connected'));

ws.on('close', (code, reason) => {
  console.log(`diagnostic: CLOSED code=${code} reason=${reason || '(none)'}`);
  process.exit(0);
});

ws.on('error', (err) => console.error('diagnostic: error:', err.message));

ws.on('message', (data) => {
  const msg = JSON.parse(data.toString());
  console.log(`diagnostic: recv op=${msg.op} t=${msg.t || ''}`);

  if (msg.op === 10) {
    console.log(`diagnostic: Hello, heartbeat_interval=${msg.d.heartbeat_interval}`);
    heartbeatTimer = setInterval(() => {
      ws.send(JSON.stringify({ op: 1, d: null }));
      console.log('diagnostic: sent heartbeat');
    }, msg.d.heartbeat_interval);

    ws.send(JSON.stringify({
      op: 2,
      d: {
        token: TOKEN,
        intents: INTENTS,
        properties: { os: 'linux', browser: 'bash-discord-bot', device: 'bash-discord-bot' },
      },
    }));
    console.log('diagnostic: sent Identify');
  }

  if (msg.op === 0 && msg.t === 'READY') {
    console.log(`diagnostic: READY as ${msg.d.user.username} in ${msg.d.guilds.length} guild(s) -- SUCCESS from Railway`);
    clearInterval(heartbeatTimer);
    ws.close(1000);
  }
});

setTimeout(() => {
  console.log('diagnostic: 20s elapsed without READY or close, giving up');
  clearInterval(heartbeatTimer);
  ws.close(1000);
}, 20000);
