#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") <stack-name>" >&2
    exit 1
}

[[ $# -ne 1 ]] && usage

STACK="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="${SCRIPT_DIR}/${STACK}"

[[ -d "$STACK_DIR" ]] || { echo "Stack directory not found: ${STACK_DIR}" >&2; exit 1; }

COMPOSE_FILE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "${STACK_DIR}/${f}" ]]; then
        COMPOSE_FILE="${STACK_DIR}/${f}"
        break
    fi
done

[[ -n "$COMPOSE_FILE" ]] || { echo "No compose file found in ${STACK_DIR}" >&2; exit 1; }

cd "$STACK_DIR"

docker compose down --remove-orphans

# 'down' only removes containers owned by this Compose project (by label).
# Containers started under a different project name or via 'docker run'
# are not touched but still hold their names, blocking 'up'.
# Force-remove any declared container names that still exist after 'down'.
while IFS= read -r name; do
    [ -n "$name" ] || continue
    if docker inspect "${name}" &>/dev/null; then
        echo "Removing stale container not owned by this project: ${name}"
        docker rm -f "${name}"
    fi
done < <(grep 'container_name:' "${COMPOSE_FILE}" | awk '{print $2}')

docker compose up -d --remove-orphans
