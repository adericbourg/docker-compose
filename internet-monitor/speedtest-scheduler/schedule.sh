#!/bin/sh
set -eu

PEAK_START=${PEAK_HOURS_START:-9}
PEAK_END=${PEAK_HOURS_END:-18}
LUNCH_START=${LUNCH_BREAK_START:-12}
LUNCH_END=${LUNCH_BREAK_END:-13}

hour=$((10#$(date +%H)))
dow=$(date +%u)

is_peak() {
    [ "$dow" -le 5 ] || return 1
    [ "$hour" -ge "$PEAK_START" ] && [ "$hour" -lt "$PEAK_END" ] || return 1
    ! { [ "$hour" -ge "$LUNCH_START" ] && [ "$hour" -lt "$LUNCH_END" ]; }
}

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ "$FORCE" -eq 0 ]; then
    if is_peak; then
        [ $((hour % 4)) -eq $((PEAK_START % 4)) ] || exit 0
    fi
fi

metrics=$(curl -sf "http://speedtest-exporter:9798/metrics") || exit 1
printf '%s\n' "$metrics" | curl -sf --data-binary @- \
    "http://victoriametrics:8428/api/v1/import/prometheus"
