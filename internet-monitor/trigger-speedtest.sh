#!/bin/sh
set -eu

cd "$(dirname "$0")"

docker compose exec speedtest-scheduler \
    sh /etc/periodic/hourly/speedtest --force
