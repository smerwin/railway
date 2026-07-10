FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl jq socat ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .
RUN chmod +x run.sh bin/*.sh

ENV PORT=3000
EXPOSE 3000

CMD ["./run.sh"]
