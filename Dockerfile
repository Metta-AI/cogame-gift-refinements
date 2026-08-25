# Build Docker. ONE image, TWO entrypoints: /bin/gift-refinements (the game
# server, which also owns the whole batched LLM decision layer) and
# /bin/gift-refinements-player (the thin seat registrar). The policy set is
# env-switched inside this same image (PLAYER_PROMPT vs PLAYER_SCRIPTED).
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/gift-refinements
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
RUN nim c \
  $NimFlags \
  --nimcache:/tmp/gift-refinements-nimcache \
  --out:gift-refinements \
  src/gift_refinements.nim && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/gift-refinements-player-nimcache \
  --out:gift-refinements-player \
  src/gift_refinements_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/gift-refinements
COPY --from=build /workspace/gift-refinements/gift-refinements /bin/gift-refinements
COPY --from=build /workspace/gift-refinements/gift-refinements-player /bin/gift-refinements-player
COPY --from=build /workspace/gift-refinements/data ./data

CMD ["/bin/gift-refinements"]
