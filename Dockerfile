FROM debian:bookworm-slim

# nodejs/npm are TEMPORARY, for diagnostic/check_gateway.js only -- see
# that file and the README's "Open issue" section. Remove both this line
# and the diagnostic/ directory together once the investigation there is
# resolved; the application itself is bash + curl/jq/socat/websocat.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl jq socat mawk ca-certificates nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# websocat speaks the actual WebSocket protocol (handshake/framing/TLS)
# so bin/bot.sh can connect to Discord's real-time Gateway; there's no
# apt package for it, so grab the static musl build from GitHub releases.
# Bump the version here after checking https://github.com/vi/websocat/releases.
ARG WEBSOCAT_VERSION=v1.14.1
RUN curl -fsSL -o /usr/local/bin/websocat \
      "https://github.com/vi/websocat/releases/download/${WEBSOCAT_VERSION}/websocat.x86_64-unknown-linux-musl" \
    && chmod +x /usr/local/bin/websocat \
    && websocat --version

WORKDIR /app
COPY . .
RUN chmod +x run.sh bin/*.sh

# TEMPORARY, for diagnostic/check_gateway.js only -- see above.
RUN cd diagnostic && npm install --omit=dev

ENV PORT=3000
EXPOSE 3000

CMD ["./run.sh"]
