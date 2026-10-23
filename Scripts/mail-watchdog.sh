#!/bin/sh
set -u

PGREP=${APPLE_PLATFORM_MCP_MAIL_WATCHDOG_PGREP:-/usr/bin/pgrep}
OPEN=${APPLE_PLATFORM_MCP_MAIL_WATCHDOG_OPEN:-/usr/bin/open}
INTERVAL=${APPLE_PLATFORM_MCP_MAIL_WATCHDOG_INTERVAL_SECONDS:-15}
ONCE=${APPLE_PLATFORM_MCP_MAIL_WATCHDOG_ONCE:-0}
MAIL_APP=${APPLE_PLATFORM_MCP_MAIL_WATCHDOG_APP:-Mail}

case "$INTERVAL" in
  ''|*[!0-9]*)
    printf '%s invalid watchdog interval: %s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$INTERVAL" >&2
    exit 64
    ;;
esac

if [ "$INTERVAL" -lt 1 ]; then
  printf '%s watchdog interval must be at least one second\n' \
    "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" >&2
  exit 64
fi

while :; do
  if ! "$PGREP" -x Mail >/dev/null 2>&1; then
    if "$OPEN" -gj -a "$MAIL_APP"; then
      printf '%s started Mail.app\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
    else
      printf '%s failed to start Mail.app\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" >&2
    fi
  fi

  [ "$ONCE" = "1" ] && exit 0
  /bin/sleep "$INTERVAL"
done
