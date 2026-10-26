FROM node:24-bookworm-slim AS node
FROM haskell:9.12.2-slim-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git make gcc xz-utils pkg-config zlib1g-dev libffi-dev && rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm
WORKDIR /app
COPY libs4/ ./libs4/
COPY haskell/ ./haskell/
COPY sapiens/corpora/host/routine/ ./sapiens/corpora/host/routine/
COPY spec/support/haskell/ ./spec/support/haskell/
COPY web/ ./web/
RUN runghc -ihaskell haskell/Build.hs

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libgmp10 zlib1g libffi8 libnuma1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/.build/bin/sapiens4 ./.build/bin/sapiens4
COPY --from=build /app/.build/web/app.js /app/.build/web/sw.js /app/.build/web/guest.js ./.build/web/
COPY web/ ./web/
COPY libs4/web/ ./libs4/web/
COPY libs4/license/ ./libs4/license/
COPY license/ ./license/
ENV SAPIENS_RELAY_BIND=0.0.0.0 SAPIENS_RELAY_DB=/data/relay.sqlite3
CMD ["/app/.build/bin/sapiens4", "relay"]
