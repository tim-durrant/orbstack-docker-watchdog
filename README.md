# OrbStack Docker watchdog

Small native macOS `launchd` agent that starts at login and monitors the
OrbStack Docker engine.

Behavior:

- Checks `docker version` every 60 seconds.
- Requires three consecutive failed checks.
- Runs `orb restart docker` after the third failure.
- If Docker remains unhealthy for five minutes after that attempt, runs
  `orb restart` to restart OrbStack itself.
- Times out health checks after 20 seconds, Docker-engine restarts after 60
  seconds, and OrbStack restarts after 120 seconds.
- Limits each recovery action to once per health incident and resets the
  escalation state when Docker recovers.
- Keeps a timestamped log in `~/Library/Logs/orbstack-docker-watchdog.log`.
- Uses no Docker container and no third-party daemon.

Install:

```sh
./install.sh
```

Inspect:

```sh
launchctl print gui/$(id -u)/com.tim.orbstack-docker-watchdog
tail -f ~/Library/Logs/orbstack-docker-watchdog.log
```

Test a single health check without restarting anything:

```sh
./watchdog.sh --once
```

Uninstall:

```sh
./uninstall.sh
```

The `WATCHDOG_*` environment variables are available for manual runs. The
launchd plist uses the safe defaults unless explicitly extended with an
`EnvironmentVariables` section.

The installer expands the local project path into the installed LaunchAgent,
so the repository can be cloned into any directory before installation.

The escalation delay and command timeouts can be overridden for testing with
`WATCHDOG_RESTART_ESCALATION_DELAY`, `WATCHDOG_DOCKER_RESTART_TIMEOUT`, and
`WATCHDOG_ORBSTACK_RESTART_TIMEOUT`.
