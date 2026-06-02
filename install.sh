#!/usr/bin/env bash
set -euo pipefail

# ─── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { printf "${BOLD}[install]${RESET} %s\n" "$*"; }
warn()    { printf "${YELLOW}[warn]${RESET}    %s\n" "$*" >&2; }
success() { printf "${GREEN}[ok]${RESET}      %s\n" "$*"; }
error()   { printf "${RED}[error]${RESET}   %s\n" "$*" >&2; }
die()     { error "$*"; exit 1; }

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat >&2 <<'EOF'
Usage: install.sh <stack-name>

Verifies prerequisites, then installs the given docker-compose stack and
configures it to start automatically on boot.

The stack directory inside this repo is referenced directly (not copied), so
a `git pull` in this repo is reflected when the stack is next restarted.

Example:
  ./install.sh internet-monitor
EOF
}

[[ $# -ne 1 ]] && { usage; exit 1; }

STACK="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="${SCRIPT_DIR}/${STACK}"

# ─── Prerequisites ────────────────────────────────────────────────────────────

info "Checking prerequisites..."

MISSING=()

if ! command -v docker &>/dev/null; then
    MISSING+=("docker  →  https://docs.docker.com/engine/install/")
else
    if ! docker info &>/dev/null 2>&1; then
        warn "Docker is installed but the daemon is not running."
        warn "  macOS : start Docker Desktop"
        warn "  Linux : sudo systemctl start docker"
    fi
fi

COMPOSE_CMD=""    # "plugin" or "standalone"
DOCKER_BIN=""
COMPOSE_BIN=""

if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="plugin"
    DOCKER_BIN="$(command -v docker)"
elif command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="standalone"
    COMPOSE_BIN="$(command -v docker-compose)"
    warn "docker-compose V1 detected. Consider upgrading to Docker Compose V2."
else
    MISSING+=("docker compose  →  https://docs.docker.com/compose/install/")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    error "Missing prerequisites — install the following and re-run:"
    for item in "${MISSING[@]}"; do
        error "  • ${item}"
    done
    exit 1
fi

success "Prerequisites OK"

# ─── Stack validation ─────────────────────────────────────────────────────────

info "Validating stack '${STACK}'..."

[[ -d "$STACK_DIR" ]] || die "Stack directory not found: ${STACK_DIR}"

COMPOSE_FILE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "${STACK_DIR}/${f}" ]]; then
        COMPOSE_FILE="$f"
        break
    fi
done

[[ -n "$COMPOSE_FILE" ]] || die "No compose file found in ${STACK_DIR}"

success "Stack found: ${STACK_DIR}/${COMPOSE_FILE}"

# ─── Environment setup ────────────────────────────────────────────────────────

ENV_CREATED=false
if [[ -f "${STACK_DIR}/.env.example" && ! -f "${STACK_DIR}/.env" ]]; then
    cp "${STACK_DIR}/.env.example" "${STACK_DIR}/.env"
    ENV_CREATED=true
fi

# ─── systemd installer (Linux) ────────────────────────────────────────────────

install_systemd() {
    local service_file="/etc/systemd/system/${STACK}.service"

    local exec_start_down exec_start_up exec_stop
    if [[ "$COMPOSE_CMD" == "plugin" ]]; then
        exec_start_down="${DOCKER_BIN} compose down --remove-orphans"
        exec_start_up="${DOCKER_BIN} compose up -d --remove-orphans"
        exec_stop="${DOCKER_BIN} compose down"
    else
        exec_start_down="${COMPOSE_BIN} down --remove-orphans"
        exec_start_up="${COMPOSE_BIN} up -d --remove-orphans"
        exec_stop="${COMPOSE_BIN} down"
    fi

    for f in /etc/systemd/system/*.service; do
        [[ -f "$f" ]] || continue
        if grep -q "WorkingDirectory=${STACK_DIR}" "$f"; then
            stale=$(basename "$f" .service)
            if [[ "$stale" != "$STACK" ]]; then
                info "Removing stale service '${stale}' (same directory, different name)."
                sudo systemctl stop "$stale" 2>/dev/null || true
                sudo systemctl disable "$stale" 2>/dev/null || true
                sudo rm "$f"
            fi
        fi
    done

    [[ -f "$service_file" ]] && info "Existing service found — overwriting."

    info "Writing ${service_file} ..."
    sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=${STACK} docker compose stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${STACK_DIR}
ExecStart=${exec_start_down}
ExecStart=${exec_start_up}
ExecStop=${exec_stop}

[Install]
WantedBy=multi-user.target
EOF

    info "Enabling and starting service..."
    sudo systemctl daemon-reload
    sudo systemctl enable "$STACK"
    if sudo systemctl is-active --quiet "$STACK"; then
        sudo systemctl restart "$STACK"
        success "systemd service '${STACK}' updated and restarted"
    else
        sudo systemctl start "$STACK"
        success "systemd service '${STACK}' enabled and started"
    fi
    info "  File: ${service_file}"
    info "  Logs: sudo journalctl -u ${STACK} -f"
}

# ─── launchd installer (macOS) ────────────────────────────────────────────────

install_launchd() {
    local label="local.${STACK}"
    local plist_file="/Library/LaunchDaemons/${label}.plist"

    local prog_args
    if [[ "$COMPOSE_CMD" == "plugin" ]]; then
        prog_args="        <string>/bin/sh</string>
        <string>-c</string>
        <string>${DOCKER_BIN} compose down --remove-orphans; ${DOCKER_BIN} compose up -d --remove-orphans</string>"
    else
        prog_args="        <string>/bin/sh</string>
        <string>-c</string>
        <string>${COMPOSE_BIN} down --remove-orphans; ${COMPOSE_BIN} up -d --remove-orphans</string>"
    fi

    for f in /Library/LaunchDaemons/local.*.plist; do
        [[ -f "$f" ]] || continue
        if grep -q "<string>${STACK_DIR}</string>" "$f"; then
            stale_label=$(basename "$f" .plist)
            if [[ "$stale_label" != "$label" ]]; then
                info "Removing stale LaunchDaemon '${stale_label}' (same directory, different name)."
                sudo launchctl bootout "system/${stale_label}" 2>/dev/null || true
                sudo rm "$f"
            fi
        fi
    done

    if [[ -f "$plist_file" ]]; then
        info "Existing LaunchDaemon found — removing before reinstall."
        sudo launchctl bootout "system/${label}" 2>/dev/null || true
    fi

    info "Writing ${plist_file} ..."
    sudo tee "$plist_file" > /dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
${prog_args}
    </array>
    <key>WorkingDirectory</key>
    <string>${STACK_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/var/log/${label}.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/${label}.log</string>
</dict>
</plist>
EOF

    sudo chown root:wheel "$plist_file"
    sudo chmod 644 "$plist_file"
    sudo launchctl bootstrap system "$plist_file"
    success "LaunchDaemon '${label}' installed and started"
    info "  Plist: ${plist_file}"
    info "  Logs:  /var/log/${label}.log"
}

# ─── OS dispatch ──────────────────────────────────────────────────────────────

info "Configuring auto-start on boot..."

OS="$(uname -s)"
case "$OS" in
    Linux)  install_systemd ;;
    Darwin) install_launchd ;;
    *)      die "Unsupported OS: ${OS} (supported: Linux, Darwin/macOS)" ;;
esac

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}Stack '${STACK}' installed successfully.${RESET}\n"
printf "  Directory : %s\n" "$STACK_DIR"
printf "  Tip       : git pull in this repo → changes apply on next stack restart\n"

if $ENV_CREATED; then
    echo ""
    warn ".env was created from .env.example — review and edit it before the stack starts:"
    warn "  ${STACK_DIR}/.env"
fi
