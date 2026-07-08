FROM oven/bun:1-slim

WORKDIR /app

COPY relay/package.json relay/bun.lock relay/
RUN bun install --cwd relay --frozen-lockfile

COPY relay/ relay/
COPY install.sh ./

CMD ["bun", "run", "relay/src/index.ts"]
