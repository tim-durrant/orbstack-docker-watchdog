# OrbStack Docker watchdog

Small native macOS `launchd` agent that starts at login and monitors the
OrbStack Docker engine.

Behavior:

- Checks `docker version` every 60 seconds.
- Requires three consecutive failed checks.
- Runs `orb restart docker` after the third failure.
- Times out health checks after 20 seconds and restarts after 60 seconds.
- Allows at most one automatic restart per hour.
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
