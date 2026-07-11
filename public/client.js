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

  function setEditedMarker(articleEl, msg) {
    let marker = articleEl.querySelector('.edited-marker');
    if (msg.editedAt) {
      if (!marker) {
        marker = document.createElement('span');
        marker.className = 'edited-marker';
        articleEl.querySelector('.message-meta').appendChild(marker);
      }
      marker.textContent = '(edited)';
      marker.title = new Date(msg.editedAt).toLocaleString();
    } else if (marker) {
      marker.remove();
    }
  }

  function renderMessage(msg) {
    const wasNearBottom = isNearBottom();
    const node = template.content.cloneNode(true);

    const article = node.querySelector('.message');
    article.dataset.messageId = msg.id;

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
    setEditedMarker(messagesEl.lastElementChild, msg);

    if (wasNearBottom) {
      window.scrollTo({ top: document.body.offsetHeight });
    }
  }

  // Returns true if an existing message was found and updated in place.
  function updateMessage(msg) {
    const article = messagesEl.querySelector(`[data-message-id="${msg.id}"]`);
    if (!article) return false;
    article.querySelector('.content').textContent = msg.content;
    setEditedMarker(article, msg);
    return true;
  }

  showEmptyState();

  // Every (re)connection to /events replays the last 50 messages from
  // scratch -- that's what lets a freshly-opened tab see recent history,
  // but it also means EventSource's automatic reconnection (after any
  // dropped connection: proxy idle timeouts, network blips, deploys)
  // replays that same backlog again. Track every message ID we've
  // rendered so a reconnect's replay never renders a "create" twice.
  const renderedIds = new Set();

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

      if (msg.kind === 'update') {
        // Re-applying an edit that was already applied (e.g. replayed
        // after an SSE reconnect) is harmless and idempotent. If the
        // original message isn't currently rendered at all (edit of
        // something outside the last-50 replay window), fall back to
        // showing it as a new entry -- better than dropping it silently.
        if (updateMessage(msg)) return;
      } else if (renderedIds.has(msg.id)) {
        return;
      }

      renderedIds.add(msg.id);
      clearEmptyState();
      renderMessage(msg);
    });
  }

  connect();
})();
