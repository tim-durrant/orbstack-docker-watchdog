#!/bin/bash
set -u

# Lightweight macOS watchdog for the OrbStack Docker engine.
# Three consecutive failed health checks trigger one Docker-engine restart.

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export PATH

CHECK_INTERVAL="${WATCHDOG_CHECK_INTERVAL:-60}"
FAILURE_THRESHOLD="${WATCHDOG_FAILURE_THRESHOLD:-3}"
COMMAND_TIMEOUT="${WATCHDOG_COMMAND_TIMEOUT:-20}"
RESTART_COOLDOWN="${WATCHDOG_RESTART_COOLDOWN:-3600}"
LOG_FILE="${WATCHDOG_LOG_FILE:-$HOME/Library/Logs/orbstack-docker-watchdog.log}"
STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/Library/Application Support/OrbStack Docker Watchdog}"
LAST_RESTART_FILE="$STATE_DIR/last-restart"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"
}

run_with_timeout() {
  local timeout="$1"
  shift
  /usr/bin/python3 - "$timeout" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
command = sys.argv[2:]
try:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=timeout)
except subprocess.TimeoutExpired:
    sys.exit(124)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
PY
}

healthy() {
  run_with_timeout "$COMMAND_TIMEOUT" /usr/local/bin/docker version --format '{{.Server.Version}}' >/dev/null 2>&1
}

restart_allowed() {
  [[ ! -f "$LAST_RESTART_FILE" ]] && return 0
  local last now
  last="$(cat "$LAST_RESTART_FILE" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  (( now - last >= RESTART_COOLDOWN ))
}

restart_docker() {
  if ! restart_allowed; then
    log "restart suppressed: cooldown is active"
    return 1
  fi

  date +%s > "$LAST_RESTART_FILE"
  log "restarting Docker engine with: orb restart docker"
  if run_with_timeout 60 /opt/homebrew/bin/orb restart docker >> "$LOG_FILE" 2>&1; then
    log "restart command completed"
    return 0
  fi
  log "restart command failed or timed out"
  return 1
}

run_once() {
  if healthy; then
    log "health check: healthy"
    return 0
  fi

  log "health check: failed"
  return 1
}

if [[ "${1:-}" == "--once" ]]; then
  run_once
  exit $?
fi

if [[ "${1:-}" == "--dry-run" ]]; then
  log "dry run: checking Docker health; restart would require $FAILURE_THRESHOLD consecutive failures"
  run_once
  exit $?
fi

log "started: interval=${CHECK_INTERVAL}s threshold=${FAILURE_THRESHOLD} timeout=${COMMAND_TIMEOUT}s cooldown=${RESTART_COOLDOWN}s"
failures=0
while true; do
  if healthy; then
    if (( failures > 0 )); then
      log "health recovered after $failures failed check(s)"
    fi
    failures=0
  else
    failures=$((failures + 1))
    log "failed health check $failures/$FAILURE_THRESHOLD"
    if (( failures >= FAILURE_THRESHOLD )); then
      restart_docker || true
      failures=0
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
