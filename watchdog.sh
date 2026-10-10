#!/bin/bash
set -u

# Lightweight macOS watchdog for the OrbStack Docker engine.
# Three consecutive failed health checks trigger a Docker-engine restart. If
# Docker remains unhealthy for five minutes after that attempt, OrbStack is
# restarted as a second-level recovery action.

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export PATH

CHECK_INTERVAL="${WATCHDOG_CHECK_INTERVAL:-60}"
FAILURE_THRESHOLD="${WATCHDOG_FAILURE_THRESHOLD:-3}"
COMMAND_TIMEOUT="${WATCHDOG_COMMAND_TIMEOUT:-20}"
RESTART_ESCALATION_DELAY="${WATCHDOG_RESTART_ESCALATION_DELAY:-300}"
DOCKER_RESTART_TIMEOUT="${WATCHDOG_DOCKER_RESTART_TIMEOUT:-60}"
ORBSTACK_RESTART_TIMEOUT="${WATCHDOG_ORBSTACK_RESTART_TIMEOUT:-120}"
LOG_FILE="${WATCHDOG_LOG_FILE:-$HOME/Library/Logs/orbstack-docker-watchdog.log}"
STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/Library/Application Support/OrbStack Docker Watchdog}"

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

restart_docker() {
  log "restarting Docker engine with: orb restart docker"
  if run_with_timeout "$DOCKER_RESTART_TIMEOUT" /opt/homebrew/bin/orb restart docker >> "$LOG_FILE" 2>&1; then
    log "restart command completed"
    return 0
  fi
  log "restart command failed or timed out"
  return 1
}

restart_orbstack() {
  log "escalating recovery: restarting OrbStack with: orb restart"
  if run_with_timeout "$ORBSTACK_RESTART_TIMEOUT" /opt/homebrew/bin/orb restart >> "$LOG_FILE" 2>&1; then
    log "OrbStack restart command completed"
    return 0
  fi
  log "OrbStack restart command failed or timed out"
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

log "started: interval=${CHECK_INTERVAL}s threshold=${FAILURE_THRESHOLD} timeout=${COMMAND_TIMEOUT}s OrbStack escalation=${RESTART_ESCALATION_DELAY}s"
failures=0
incident_started_at=0
docker_restart_at=0
docker_restart_attempted=0
orbstack_restart_attempted=0
while true; do
  if healthy; then
    if (( failures > 0 )); then
      log "health recovered after $failures failed check(s)"
    fi
    failures=0
    incident_started_at=0
    docker_restart_at=0
    docker_restart_attempted=0
    orbstack_restart_attempted=0
  else
    now="$(date +%s)"
    if (( incident_started_at == 0 )); then
      incident_started_at="$now"
      log "health incident started"
    fi
    failures=$((failures + 1))
    log "failed health check $failures/$FAILURE_THRESHOLD"
    if (( failures >= FAILURE_THRESHOLD && docker_restart_attempted == 0 )); then
      docker_restart_attempted=1
      docker_restart_at="$now"
      restart_docker || true
    elif (( docker_restart_attempted == 1 && orbstack_restart_attempted == 0 && now - docker_restart_at >= RESTART_ESCALATION_DELAY )); then
      orbstack_restart_attempted=1
      restart_orbstack || true
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
