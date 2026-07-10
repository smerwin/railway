const { Client, GatewayIntentBits, Partials } = require('discord.js');

const HISTORY_LIMIT = 50;

/**
 * Wraps a raw discord.js Message into the plain object shape the
 * front-end understands. Keeping this separate from the Discord.js
 * Message class means we never leak internal/circular structures
 * over the WebSocket, and can JSON.stringify it directly.
 */
function serializeMessage(message) {
  return {
    id: message.id,
    authorId: message.author?.id ?? null,
    authorName: message.member?.displayName || message.author?.username || 'Unknown',
    authorAvatarURL: message.author?.displayAvatarURL({ size: 64 }) ?? null,
    content: message.content ?? '',
    createdAt: message.createdAt ? message.createdAt.toISOString() : new Date().toISOString(),
    attachments: [...message.attachments.values()].map((a) => ({
      url: a.url,
      name: a.name,
      contentType: a.contentType,
    })),
  };
}

/**
 * Starts the Discord client and wires it up to broadcast new messages
 * posted in the configured channel. Returns an object exposing the
 * in-memory history buffer (for newly-connected web clients) and the
 * underlying client (for lifecycle/shutdown handling).
 */
function startBot({ token, channelId, onMessage }) {
  const history = [];

  const client = new Client({
    intents: [
      GatewayIntentBits.Guilds,
      GatewayIntentBits.GuildMessages,
      GatewayIntentBits.MessageContent,
    ],
    partials: [Partials.Message, Partials.Channel],
  });

  client.once('clientReady', () => {
    console.log(`Discord bot logged in as ${client.user.tag}`);
  });

  client.on('messageCreate', (message) => {
    if (message.channelId !== channelId) return;
    if (message.author?.bot) return;

    const serialized = serializeMessage(message);
    history.push(serialized);
    if (history.length > HISTORY_LIMIT) history.shift();

    onMessage(serialized);
  });

  client.on('error', (err) => {
    console.error('Discord client error:', err);
  });

  client.login(token).catch((err) => {
    console.error('Failed to log in to Discord:', err.message);
  });

  return { client, history };
}

module.exports = { startBot, serializeMessage };
