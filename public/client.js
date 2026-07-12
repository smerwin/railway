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

  function findMessageEl(id) {
    return messagesEl.querySelector(`[data-message-id="${id}"]`);
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
    const article = findMessageEl(msg.id);
    if (!article) return false;
    article.querySelector('.content').textContent = msg.content;
    setEditedMarker(article, msg);
    return true;
  }

  function removeMessage(id) {
    const article = findMessageEl(id);
    if (article) article.remove();
    if (!messagesEl.querySelector('.message')) showEmptyState();
  }

  showEmptyState();

  // /events replays the last 50 messages on every (re)connect, including
  // EventSource's automatic ones -- track rendered IDs so a reconnect
  // never renders the same "create" twice.
  const renderedIds = new Set();

  // EventSource reconnects on its own; no manual retry logic needed.
  function connect() {
    setStatus('connecting', 'Connecting…');
    const source = new EventSource('/events');

    source.addEventListener('open', () => setStatus('connected', 'Live'));
    source.addEventListener('error', () => setStatus('disconnected', 'Reconnecting…'));
    source.addEventListener('message', (event) => {
      const msg = JSON.parse(event.data);

      if (msg.kind === 'delete') {
        // Not removing msg.id from renderedIds: if a replay resends the
        // original create after this, it should be skipped, not flash
        // back in right before being deleted again.
        removeMessage(msg.id);
        return;
      }

      if (msg.kind === 'update') {
        // Re-applying an already-applied edit is harmless. If the
        // original isn't rendered (outside the last-50 window), fall
        // back to showing the edit as a new entry rather than dropping it.
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
