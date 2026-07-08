#!/usr/bin/env bash
# SkyView bridge installer.
#   curl -fsSL https://<relay-host>/install.sh | bash
# Idempotent: re-run to update or reconfigure.
set -euo pipefail

REPO="notnotjake/skyview-control"
IMAGE="ghcr.io/notnotjake/skyview-bridge:latest"
DIR="${SKYVIEW_HOME:-$HOME/.skyview}"
ENV_FILE="$DIR/bridge.env"
COMPOSE_FILE="$DIR/docker-compose.yml"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Prompts must come from the terminal even when piped through `curl | bash`.
TTY=/dev/tty
[ -r "$TTY" ] || fail "no terminal available for interactive setup (run the script from a shell)"

ask() { # ask VAR "prompt" [default] [secret]
  local var="$1" prompt="$2" default="${3:-}" secret="${4:-}" input=""
  local suffix=""
  [ -n "$default" ] && suffix=" [$default]"
  while [ -z "$input" ]; do
    if [ -n "$secret" ]; then
      printf '%s%s: ' "$prompt" "$suffix" > "$TTY"
      read -rs input < "$TTY"; printf '\n' > "$TTY"
    else
      printf '%s%s: ' "$prompt" "$suffix" > "$TTY"
      read -r input < "$TTY"
    fi
    [ -z "$input" ] && input="$default"
  done
  printf -v "$var" '%s' "$input"
}

# --- preflight ---------------------------------------------------------------
OS="$(uname -s)"
case "$OS" in
  Darwin) PLATFORM=macos ;;
  Linux)  PLATFORM=linux ;;
  *) fail "unsupported OS: $OS" ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  if [ "$PLATFORM" = macos ]; then
    fail "docker not found — install OrbStack (https://orbstack.dev) or Docker Desktop, then re-run"
  else
    fail "docker not found — try: sudo apt-get install -y docker.io docker-compose-plugin (then add your user to the docker group)"
  fi
fi
docker info >/dev/null 2>&1 || fail "docker is installed but the daemon isn't responding — start Docker and re-run"
docker compose version >/dev/null 2>&1 || fail "docker compose plugin not found"

say "Installing SkyView bridge into $DIR"
mkdir -p "$DIR"

# --- configuration -----------------------------------------------------------
declare RELAY_INPUT BRIDGE_TOKEN TUYA_DEVICE_ID TUYA_LOCAL_KEY TUYA_DEVICE_IP
reconfigure=yes
if [ -f "$ENV_FILE" ]; then
  say "Existing config found at $ENV_FILE"
  answer=""
  printf 'Keep existing config? [Y/n]: ' > "$TTY"; read -r answer < "$TTY"
  case "$answer" in n|N|no|NO) reconfigure=yes ;; *) reconfigure=no ;; esac
fi

if [ "$reconfigure" = yes ]; then
  ask RELAY_INPUT     "Relay URL (e.g. https://skyview.up.railway.app)" "${SKYVIEW_RELAY_URL:-}"
  ask BRIDGE_TOKEN    "Bridge token" "" secret
  ask TUYA_DEVICE_ID  "Tuya device ID"
  ask TUYA_LOCAL_KEY  "Tuya local key" "" secret
  ask TUYA_DEVICE_IP  "Lamp IP on this network"

  # Accept https://host, wss://host, or bare host; normalize to wss://host/bridge.
  relay_ws="$RELAY_INPUT"
  relay_ws="${relay_ws%/}"
  case "$relay_ws" in
    wss://*|ws://*) ;;
    https://*) relay_ws="wss://${relay_ws#https://}" ;;
    http://*)  relay_ws="ws://${relay_ws#http://}" ;;
    *)         relay_ws="wss://$relay_ws" ;;
  esac
  case "$relay_ws" in */bridge) ;; *) relay_ws="$relay_ws/bridge" ;; esac

  umask 177
  cat > "$ENV_FILE" <<EOF
RELAY_URL=$relay_ws
BRIDGE_TOKEN=$BRIDGE_TOKEN
TUYA_DEVICE_ID=$TUYA_DEVICE_ID
TUYA_LOCAL_KEY=$TUYA_LOCAL_KEY
TUYA_DEVICE_IP=$TUYA_DEVICE_IP
TUYA_VERSION=3.4
EOF
  umask 022
  say "Wrote $ENV_FILE"
fi

# --- compose file ------------------------------------------------------------
network_lines=""
if [ "$PLATFORM" = linux ]; then
  network_lines="    network_mode: host"
fi

cat > "$COMPOSE_FILE" <<EOF
services:
  bridge:
    image: $IMAGE
    container_name: skyview-bridge
    restart: unless-stopped
    env_file: bridge.env
    mem_limit: 128m
$network_lines
EOF
say "Wrote $COMPOSE_FILE"

# --- start -------------------------------------------------------------------
say "Pulling image and starting bridge"
if ! docker compose -p skyview-bridge -f "$COMPOSE_FILE" up -d --pull always 2>/dev/null; then
  say "Image pull failed — building from source instead"
  if [ -d "$DIR/src/.git" ]; then
    git -C "$DIR/src" pull --ff-only
  else
    git clone --depth 1 "https://github.com/$REPO.git" "$DIR/src"
  fi
  docker build -t "$IMAGE" "$DIR/src/bridge"
  docker compose -p skyview-bridge -f "$COMPOSE_FILE" up -d
fi

# --- verify ------------------------------------------------------------------
say "Waiting for bridge to connect to the relay"
for _ in $(seq 1 30); do
  if docker logs skyview-bridge 2>&1 | grep -qi "connected"; then
    say "Bridge is online ✓"
    printf '\nUseful commands:\n'
    printf '  docker logs -f skyview-bridge\n'
    printf '  docker compose -p skyview-bridge -f %s restart\n' "$COMPOSE_FILE"
    printf '  docker compose -p skyview-bridge -f %s down\n' "$COMPOSE_FILE"
    exit 0
  fi
  sleep 1
done

printf '\033[1;33mwarn:\033[0m bridge started but no relay connection seen yet — check: docker logs -f skyview-bridge\n'
exit 0
