#!/usr/bin/env bash
# Set up the Lichess external engine provider on your own server.
#
# Standalone script (no repo checkout needed): it installs the prerequisites, checks out
# the reference provider from https://github.com/lichess-org/external-engine into a Python
# venv, and — unless --no-service is given — installs and starts a systemd service so the
# provider registers your engine and long-polls the broker across reboots.
#
# Target: Ubuntu/Debian- or Fedora-family Linux with systemd. Run as root (or via sudo) for
# the default service install; --no-service only needs sudo for the package install step.
#
# Quick start:
#   sudo LICHESS_API_TOKEN=lip_xxx ./setup-external-engine.sh
#
# Create the token (scopes engine:read + engine:write) at:
#   https://lichess.org/account/oauth/token/create?scopes[]=engine:read&scopes[]=engine:write&description=External+engine+provider
#
# Run with --help for all options.

set -euo pipefail

# --- Defaults (override with flags or environment variables) ------------------------------

TOKEN="${LICHESS_API_TOKEN:-}"
ENGINE_NAME="${ENGINE_NAME:-Stockfish (home server)}"
ENGINE_BIN="${ENGINE_BIN:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/external-engine}"
SERVICE_USER="${SERVICE_USER:-engine}"
SERVICE_NAME="${SERVICE_NAME:-lichess-engine-provider}"
PROVIDER_REPO="${PROVIDER_REPO:-https://github.com/lichess-org/external-engine.git}"
MAX_THREADS="${MAX_THREADS:-}"
MAX_HASH="${MAX_HASH:-}"
KEEP_ALIVE=0
INSTALL_SERVICE=1

usage() {
  cat <<'EOF'
Usage: setup-external-engine.sh [options]

Sets up the Lichess external engine provider (see docs/external-engine.md).

Options:
  --token TOKEN         Lichess OAuth token (engine:read + engine:write).
                        Defaults to $LICHESS_API_TOKEN.
  --name NAME           Engine name shown in the app (default: "Stockfish (home server)").
  --engine PATH         Path to the UCI engine binary. Auto-detected from `stockfish`
                        (including /usr/games) when omitted.
  --install-dir DIR     Where to check out the provider (default: /opt/external-engine).
  --user USER           System user to run the service as (default: engine).
  --service-name NAME   systemd unit name (default: lichess-engine-provider).
  --max-threads N       Pass --default-max-threads N to the provider.
  --max-hash MB         Pass --default-max-hash MB to the provider.
  --keep-alive          Pass --keep-alive to the provider (keep the engine process warm).
  --no-service          Skip the systemd install; do a foreground test run instead.
  -h, --help            Show this help.

Environment variables mirror the long options (LICHESS_API_TOKEN, ENGINE_NAME, ENGINE_BIN,
INSTALL_DIR, SERVICE_USER, SERVICE_NAME, MAX_THREADS, MAX_HASH).
EOF
}

# --- Parse arguments ----------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --name) ENGINE_NAME="$2"; shift 2 ;;
    --engine) ENGINE_BIN="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --user) SERVICE_USER="$2"; shift 2 ;;
    --service-name) SERVICE_NAME="$2"; shift 2 ;;
    --max-threads) MAX_THREADS="$2"; shift 2 ;;
    --max-hash) MAX_HASH="$2"; shift 2 ;;
    --keep-alive) KEEP_ALIVE=1; shift ;;
    --no-service) INSTALL_SERVICE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; }

# Where to create (or replace) the OAuth token the provider needs.
TOKEN_URL="https://lichess.org/account/oauth/token/create?scopes[]=engine:read&scopes[]=engine:write&description=External+engine+provider"

# sudo only when we are not already root.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo > /dev/null; then
    SUDO="sudo"
  elif [ "$INSTALL_SERVICE" -eq 1 ]; then
    err "run as root or install sudo (the systemd service install needs privileges)."
    exit 1
  fi
fi

if [ -z "$TOKEN" ]; then
  err "no Lichess token. Pass --token or set LICHESS_API_TOKEN."
  echo "Create one (scopes engine:read + engine:write) at:" >&2
  echo "  $TOKEN_URL" >&2
  exit 1
fi

log "Using the supplied Lichess token"
echo "  To create or replace it (scopes engine:read + engine:write), visit:"
echo "  $TOKEN_URL"

# --- 1. Prerequisites ---------------------------------------------------------------------

log "Installing prerequisites (python3, venv, git, stockfish)"
if command -v apt-get > /dev/null; then
  $SUDO apt-get update
  $SUDO apt-get install -y python3 python3-venv git stockfish
elif command -v dnf > /dev/null; then
  $SUDO dnf install -y python3 git stockfish
else
  echo "  (unknown package manager: ensure python3 (with venv), git and a UCI engine are installed)"
fi

# Ubuntu/Debian install stockfish to /usr/games, which is often off non-interactive PATH.
if [ -z "$ENGINE_BIN" ]; then
  ENGINE_BIN=$(PATH="$PATH:/usr/games" command -v stockfish || true)
fi
if [ -z "$ENGINE_BIN" ] || [ ! -x "$ENGINE_BIN" ]; then
  err "no engine binary found. Install stockfish or pass --engine /path/to/engine."
  exit 1
fi
log "Using engine binary: $ENGINE_BIN"

# --- 2. Check out the reference provider into a venv --------------------------------------

log "Setting up the reference provider in $INSTALL_DIR"
if [ -d "$INSTALL_DIR/.git" ]; then
  $SUDO git -C "$INSTALL_DIR" pull --ff-only
else
  $SUDO mkdir -p "$INSTALL_DIR"
  $SUDO git clone --depth 1 "$PROVIDER_REPO" "$INSTALL_DIR"
fi

$SUDO python3 -m venv "$INSTALL_DIR/venv"
$SUDO "$INSTALL_DIR/venv/bin/pip" install --upgrade pip
$SUDO "$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

# Assemble the provider arguments shared by the test run and the service.
PROVIDER_ARGS=(--engine "$ENGINE_BIN" --name "$ENGINE_NAME")
[ -n "$MAX_THREADS" ] && PROVIDER_ARGS+=(--default-max-threads "$MAX_THREADS")
[ -n "$MAX_HASH" ] && PROVIDER_ARGS+=(--default-max-hash "$MAX_HASH")
[ "$KEEP_ALIVE" -eq 1 ] && PROVIDER_ARGS+=(--keep-alive)

# --- 3. Foreground test run (when --no-service) ------------------------------------------

if [ "$INSTALL_SERVICE" -eq 0 ]; then
  log "Starting the provider in the foreground (Ctrl-C to stop)"
  echo "  Open https://lichess.org/analysis and pick your engine to verify it works."
  exec env LICHESS_API_TOKEN="$TOKEN" \
    "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/example-provider.py" "${PROVIDER_ARGS[@]}"
fi

# --- 4. systemd service ------------------------------------------------------------------

log "Creating system user '$SERVICE_USER'"
if ! id "$SERVICE_USER" > /dev/null 2>&1; then
  $SUDO useradd -r -s /usr/sbin/nologin "$SERVICE_USER"
fi

ENV_FILE="/etc/${SERVICE_NAME}.env"
log "Writing token to $ENV_FILE (mode 0600, root-owned)"
$SUDO install -m 0600 -o root -g root /dev/null "$ENV_FILE"
printf 'LICHESS_API_TOKEN=%s\n' "$TOKEN" | $SUDO tee "$ENV_FILE" > /dev/null

# Quote each provider arg for the ExecStart line so names with spaces survive.
EXEC_ARGS=""
for arg in "${PROVIDER_ARGS[@]}"; do
  EXEC_ARGS+=" $(printf '%q' "$arg")"
done

UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
log "Writing systemd unit $UNIT_FILE"
$SUDO tee "$UNIT_FILE" > /dev/null <<EOF
[Unit]
Description=Lichess external engine provider
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_DIR}/venv/bin/python ${INSTALL_DIR}/example-provider.py${EXEC_ARGS}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

log "Enabling and starting $SERVICE_NAME"
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now "$SERVICE_NAME"

echo
log "Done. The provider is registered and long-polling the broker."
echo "  Status:  ${SUDO:+$SUDO }systemctl status $SERVICE_NAME"
echo "  Logs:    ${SUDO:+$SUDO }journalctl -u $SERVICE_NAME -f"
echo
echo "In the app: sign in with the same account, then Settings -> Chess engine ->"
echo "External engines, and select \"$ENGINE_NAME\"."
echo
echo "To rotate the token later, create a new one at:"
echo "  $TOKEN_URL"
echo "then update $ENV_FILE and run: ${SUDO:+$SUDO }systemctl restart $SERVICE_NAME"
