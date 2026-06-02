#!/usr/bin/env bash
set -euo pipefail

# ─── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { printf "${BOLD}[passwd]${RESET}  %s\n" "$*"; }
success() { printf "${GREEN}[ok]${RESET}      %s\n" "$*"; }
error()   { printf "${RED}[error]${RESET}   %s\n" "$*" >&2; }
die()     { error "$*"; exit 1; }

# ─── Setup ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

# ─── Load .env ────────────────────────────────────────────────────────────────

[[ -f "$ENV_FILE" ]] || die ".env not found. Copy .env.example to .env first."

# shellcheck source=/dev/null
source "$ENV_FILE"

[[ -n "${GF_ADMIN_PASSWORD:-}" ]] || die "GF_ADMIN_PASSWORD is not set in .env"

# ─── Validate container ───────────────────────────────────────────────────────

info "Checking that the Grafana container is running..."

docker compose -f "$COMPOSE_FILE" exec grafana true >/dev/null 2>&1 \
    || die "Grafana container is not running. Start the stack first: docker compose up -d"

success "Container is running"

# ─── Update password ──────────────────────────────────────────────────────────

info "Updating Grafana admin password..."

docker compose -f "$COMPOSE_FILE" exec grafana \
    grafana cli admin reset-admin-password "$GF_ADMIN_PASSWORD"

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
success "Admin password updated."
printf "  Login: ${BOLD}http://localhost:3000${RESET}  •  user: ${BOLD}admin${RESET}\n"
