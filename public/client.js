(() => {
  const messagesEl = document.getElementById('messages');
  const statusEl = document.getElementById('status');
  const template = document.getElementById('message-template');

  function setStatus(state, label) {
    statusEl.className = `status status--${state}`;
    statusEl.textContent = label;
  }

  function isNearBottom() {
    return window.innerHeight + window.scrollY >= document.body.offsetHeight - 100;
  }

  function clearEmptyState() {
    const empty = messagesEl.querySelector('.empty-state');
    if (empty) empty.remove();
  }

  function showEmptyState() {
    const empty = document.createElement('p');
    empty.className = 'empty-state';
    empty.textContent = 'No messages yet. Post one in the Discord channel!';
    messagesEl.appendChild(empty);
  }

  function renderMessage(msg) {
    const wasNearBottom = isNearBottom();
    const node = template.content.cloneNode(true);

    const avatar = node.querySelector('.avatar');
    avatar.src = msg.authorAvatarURL || '';
    avatar.alt = msg.authorName;

    node.querySelector('.author').textContent = msg.authorName;

    const time = node.querySelector('.timestamp');
    const date = new Date(msg.createdAt);
    time.dateTime = msg.createdAt;
    time.textContent = date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

    // textContent (not innerHTML) so message content can never execute as HTML/script.
    node.querySelector('.content').textContent = msg.content;

    const attachmentsEl = node.querySelector('.attachments');
    for (const attachment of msg.attachments || []) {
      if (attachment.contentType && attachment.contentType.startsWith('image/')) {
        const img = document.createElement('img');
        img.src = attachment.url;
        img.alt = attachment.name || 'attachment';
        attachmentsEl.appendChild(img);
      } else {
        const link = document.createElement('a');
        link.href = attachment.url;
        link.textContent = attachment.name || attachment.url;
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
        attachmentsEl.appendChild(link);
      }
    }

    messagesEl.appendChild(node);

    if (wasNearBottom) {
      window.scrollTo({ top: document.body.offsetHeight });
    }
  }

  showEmptyState();

  // Every (re)connection to /events replays the last 50 messages from
  // scratch -- that's what lets a freshly-opened tab see recent history,
  // but it also means EventSource's automatic reconnection (after any
  // dropped connection: proxy idle timeouts, network blips, deploys)
  // replays that same backlog again. Dedupe by Discord's message ID so a
  // reconnect never renders a message twice.
  const seenIds = new Set();

  // EventSource (Server-Sent Events) handles reconnection natively, so
  // there's no manual backoff/retry logic here -- the browser re-opens
  // the connection on its own after a drop.
  function connect() {
    setStatus('connecting', 'Connecting…');
    const source = new EventSource('/events');

    source.addEventListener('open', () => setStatus('connected', 'Live'));
    source.addEventListener('error', () => setStatus('disconnected', 'Reconnecting…'));
    source.addEventListener('message', (event) => {
      const msg = JSON.parse(event.data);
      if (seenIds.has(msg.id)) return;
      seenIds.add(msg.id);
      clearEmptyState();
      renderMessage(msg);
    });
  }

  connect();
})();
