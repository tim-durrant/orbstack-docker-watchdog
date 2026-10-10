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
DOCKER_HEALTH_TIMEOUT="${WATCHDOG_DOCKER_HEALTH_TIMEOUT:-20}"
ORBSTACK_HEALTH_TIMEOUT="${WATCHDOG_ORBSTACK_HEALTH_TIMEOUT:-10}"
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

health_check() {
  local started_at docker_info orb_status elapsed
  started_at="$(date +%s)"

  if ! docker_info="$(run_with_timeout "$DOCKER_HEALTH_TIMEOUT" /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1)"; then
    docker_info="${docker_info//$'\n'/ }"
    log "health check failed: Docker API unavailable (${docker_info:-no response})"
    return 1
  fi

  if ! orb_status="$(run_with_timeout "$ORBSTACK_HEALTH_TIMEOUT" /opt/homebrew/bin/orb status 2>&1)"; then
    orb_status="${orb_status//$'\n'/ }"
    log "health check failed: OrbStack status unavailable (${orb_status:-no response})"
    return 1
  fi

  if [[ "$orb_status" != *Running* ]]; then
    orb_status="${orb_status//$'\n'/ }"
    log "health check failed: OrbStack status is not Running (${orb_status:-empty response})"
    return 1
  fi

  elapsed=$(( $(date +%s) - started_at ))
  docker_info="${docker_info//$'\n'/ }"
  orb_status="${orb_status//$'\n'/ }"
  log "health check healthy: Docker=${docker_info:-unknown} OrbStack=${orb_status} duration=${elapsed}s"
  return 0
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

force_restart_stack() {
  log "escalating recovery: terminating OrbStack and Docker process family"
  /usr/bin/python3 - >> "$LOG_FILE" 2>&1 <<'PY'
import os
import signal
import subprocess
import time

self_pid = os.getpid()
watchdog_marker = "orbstack-docker-watchdog"
targets = {"docker", "dockerd", "containerd", "OrbStack"}

def processes():
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,comm=,args="],
        capture_output=True, text=True, check=False,
    )
    found = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        comm, args = parts[1], parts[2]
        if pid in {self_pid, os.getpid()} or watchdog_marker in args:
            continue
        is_orbstack = "/OrbStack.app/Contents/" in args or " vmgr " in f" {args} " or " scon " in f" {args} "
        is_docker = comm in targets or "/docker-compose" in args or " docker compose " in f" {args} "
        if is_orbstack or is_docker:
            found.append((pid, comm, args))
    return found

initial = processes()
for pid, comm, args in initial:
    try:
        os.kill(pid, signal.SIGTERM)
        print(f"sent SIGTERM pid={pid} comm={comm}")
    except ProcessLookupError:
        pass
    except PermissionError as error:
        print(f"could not terminate pid={pid}: {error}")

time.sleep(8)
remaining = processes()
for pid, comm, args in remaining:
    try:
        os.kill(pid, signal.SIGKILL)
        print(f"sent SIGKILL pid={pid} comm={comm}")
    except ProcessLookupError:
        pass
    except PermissionError as error:
        print(f"could not force-kill pid={pid}: {error}")

print(f"terminated {len(initial)} process(es); force-killed {len(remaining)} remaining process(es)")
PY

  log "reopening OrbStack"
  /usr/bin/open -a OrbStack >> "$LOG_FILE" 2>&1 || log "could not open OrbStack"
  if run_with_timeout "$ORBSTACK_RESTART_TIMEOUT" /opt/homebrew/bin/orb start docker >> "$LOG_FILE" 2>&1; then
    log "OrbStack reopened and Docker start command completed"
    return 0
  fi
  log "OrbStack reopened but Docker start command failed or timed out"
  return 1
}

run_once() {
  health_check
}

if [[ "${1:-}" == "--once" ]]; then
  run_once
  exit $?
fi

if [[ "${1:-}" == "--dry-run" ]]; then
  log "dry run: checking Docker and OrbStack health; restart would require $FAILURE_THRESHOLD consecutive failures"
  run_once
  exit $?
fi

log "started: interval=${CHECK_INTERVAL}s threshold=${FAILURE_THRESHOLD} Docker timeout=${DOCKER_HEALTH_TIMEOUT}s OrbStack timeout=${ORBSTACK_HEALTH_TIMEOUT}s escalation=${RESTART_ESCALATION_DELAY}s"
failures=0
incident_started_at=0
docker_restart_at=0
docker_restart_attempted=0
orbstack_restart_attempted=0
while true; do
  if health_check; then
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
      force_restart_stack || true
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
