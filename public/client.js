(() => {
  const messagesEl = document.getElementById('messages');
  const statusEl = document.getElementById('status');
  const template = document.getElementById('message-template');

  let reconnectDelay = 1000;
  const MAX_RECONNECT_DELAY = 15000;

  function setStatus(state, label) {
    statusEl.className = `status status--${state}`;
    statusEl.textContent = label;
  }

  function isNearBottom() {
    return window.innerHeight + window.scrollY >= document.body.offsetHeight - 100;
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

  function clearEmptyState() {
    const empty = messagesEl.querySelector('.empty-state');
    if (empty) empty.remove();
  }

  function connect() {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${protocol}//${window.location.host}/ws`);

    ws.addEventListener('open', () => {
      setStatus('connected', 'Live');
      reconnectDelay = 1000;
    });

    ws.addEventListener('message', (event) => {
      const { type, data } = JSON.parse(event.data);

      if (type === 'history') {
        messagesEl.innerHTML = '';
        if (data.length === 0) {
          const empty = document.createElement('p');
          empty.className = 'empty-state';
          empty.textContent = 'No messages yet. Post one in the Discord channel!';
          messagesEl.appendChild(empty);
        } else {
          data.forEach(renderMessage);
          window.scrollTo({ top: document.body.offsetHeight });
        }
      } else if (type === 'message') {
        clearEmptyState();
        renderMessage(data);
      }
    });

    ws.addEventListener('close', () => {
      setStatus('disconnected', 'Reconnecting…');
      setTimeout(connect, reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY);
    });

    ws.addEventListener('error', () => ws.close());
  }

  connect();
})();
