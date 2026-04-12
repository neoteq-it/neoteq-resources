#!/usr/bin/env bash
set -euo pipefail

LOGIN_SERVER="https://atlas.neoteq.be"
AUTHKEY="${TAILSCALE_AUTHKEY:-}"
DELAY_SECONDS=8
UNIT_NAME="ntq-tailscale-migrate"
STRICT_LOCK_DISABLE=false

usage() {
  cat <<EOF
Usage: sudo $0 [options]

Migrates this host from the official Tailscale control server to a custom
login server. The migration is executed as a detached systemd unit, so it keeps
running if your SSH session drops when 'tailscale down' runs.

Options:
  --authkey <key>              Tailscale/Headscale auth key
  --login-server <url>         Login server (default: ${LOGIN_SERVER})
  --delay <seconds>            Delay before migration starts (default: ${DELAY_SECONDS})
  --strict-lock-disable        Fail if 'tailscale lock local-disable' fails
  -h, --help                   Show this help

Safer interactive use:
  sudo $0

Non-interactive use:
  sudo TAILSCALE_AUTHKEY='<key>' $0
EOF
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

env_quote() {
  local value="$1"
  value=${value//$'\n'/}
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

arg_value() {
  [[ $# -ge 2 && -n "${2:-}" && "${2:0:1}" != "-" ]] || err "$1 requires a value"
  printf '%s' "$2"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --authkey)
      AUTHKEY=$(arg_value "$1" "${2:-}")
      shift 2
      ;;
    --login-server)
      LOGIN_SERVER=$(arg_value "$1" "${2:-}")
      shift 2
      ;;
    --delay)
      DELAY_SECONDS=$(arg_value "$1" "${2:-}")
      shift 2
      ;;
    --strict-lock-disable)
      STRICT_LOCK_DISABLE=true
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || err "Run as root, for example: sudo $0"
need systemctl
need systemd-run
need tailscale
need install
need grep

[[ "$LOGIN_SERVER" =~ ^https://[^[:space:]]+$ ]] || err "--login-server must be an https URL"
[[ "$DELAY_SECONDS" =~ ^[0-9]+$ && "$DELAY_SECONDS" -ge 1 ]] || err "--delay must be a positive number"

if [[ -z "$AUTHKEY" ]]; then
  if [[ -t 0 ]]; then
    read -r -s -p "Tailscale auth key: " AUTHKEY
    echo
  else
    err "Provide --authkey <key> or TAILSCALE_AUTHKEY=<key>"
  fi
fi
[[ -n "$AUTHKEY" ]] || err "Auth key must not be empty"

SERVICE_NAME="${UNIT_NAME}.service"
WORKER_FILE="/run/${UNIT_NAME}.sh"
ENV_FILE="/run/${UNIT_NAME}.env"
LOG_FILE="/var/log/${UNIT_NAME}.log"
SCHEDULED=false

parent_cleanup() {
  if [[ "$SCHEDULED" != "true" ]]; then
    rm -f "$WORKER_FILE" "$ENV_FILE"
  fi
}

if systemctl is-active --quiet "$SERVICE_NAME"; then
  err "$SERVICE_NAME is already running"
fi

trap parent_cleanup EXIT

install -m 700 /dev/null "$WORKER_FILE"
cat >"$WORKER_FILE" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="${ENV_FILE}"
WORKER_FILE="${WORKER_FILE}"

if [[ ! -r "\$ENV_FILE" ]]; then
  echo "ERROR: Missing environment file: \$ENV_FILE" >&2
  exit 1
fi

source "\$ENV_FILE"
LOG_FILE="\${LOG_FILE:-${LOG_FILE}}"

log() {
  printf '[%s] %s\n' "\$(date -Is)" "\$*"
}

cleanup() {
  local status=\$?
  rm -f "\$ENV_FILE" "\$WORKER_FILE"
  if [[ "\$status" -eq 0 ]]; then
    log "Migration completed"
  else
    log "Migration failed with exit code \$status"
  fi
  exit "\$status"
}
trap cleanup EXIT

exec >>"\$LOG_FILE" 2>&1

log "Starting detached Tailscale migration in \${DELAY_SECONDS}s"
sleep "\$DELAY_SECONDS"

log "Current Tailscale status before migration"
tailscale status || true

log "Running: tailscale down"
if ! tailscale down; then
  log "WARN: tailscale down failed; continuing so tailscale up can still repair/reconfigure the node"
fi

log "Running: tailscale lock local-disable"
if ! tailscale lock local-disable; then
  if [[ "\${STRICT_LOCK_DISABLE}" == "true" ]]; then
    log "tailscale lock local-disable failed and strict mode is enabled"
    exit 1
  fi
  log "WARN: tailscale lock local-disable failed; continuing without strict mode"
fi

log "Running: tailscale up --login-server \${TAILSCALE_LOGIN_SERVER} --force-reauth --reset"
tailscale up \\
  --login-server "\$TAILSCALE_LOGIN_SERVER" \\
  --authkey "\$TAILSCALE_AUTHKEY" \\
  --force-reauth \\
  --reset

log "Running: systemctl restart tailscaled"
systemctl restart tailscaled

log "Current Tailscale status after migration"
tailscale status || true
EOF

install -m 600 /dev/null "$ENV_FILE"
{
  printf 'TAILSCALE_AUTHKEY=%s\n' "$(env_quote "$AUTHKEY")"
  printf 'TAILSCALE_LOGIN_SERVER=%s\n' "$(env_quote "$LOGIN_SERVER")"
  printf 'DELAY_SECONDS=%s\n' "$(env_quote "$DELAY_SECONDS")"
  printf 'STRICT_LOCK_DISABLE=%s\n' "$(env_quote "$STRICT_LOCK_DISABLE")"
  printf 'LOG_FILE=%s\n' "$(env_quote "$LOG_FILE")"
} >"$ENV_FILE"

echo "Starting detached systemd unit: $SERVICE_NAME"
SYSTEMD_RUN_ARGS=(
  --unit="$UNIT_NAME"
  --description="NEOTEQ Tailscale login-server migration"
  --property=Type=oneshot
  "$WORKER_FILE"
)

if ! SYSTEMD_RUN_OUTPUT=$(systemd-run --collect "${SYSTEMD_RUN_ARGS[@]}" 2>&1); then
  if grep -qi -- 'collect' <<<"$SYSTEMD_RUN_OUTPUT"; then
    systemd-run "${SYSTEMD_RUN_ARGS[@]}"
  else
    echo "$SYSTEMD_RUN_OUTPUT" >&2
    exit 1
  fi
else
  echo "$SYSTEMD_RUN_OUTPUT"
fi
SCHEDULED=true
trap - EXIT

cat <<EOF

Migration scheduled.
Your SSH session may disconnect in about ${DELAY_SECONDS} seconds if it uses Tailscale.

Local log on the host:
  ${LOG_FILE}

Systemd status/log:
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME}
EOF
