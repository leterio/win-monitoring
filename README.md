# Monitoring

Windows collectors published through Telegraf. Telegraf's usual setup is a `telegraf.conf` file edited by hand on each machine. The goal of this project is to use InfluxDB as the provider of those configurations instead. This repository does not contain a `telegraf.conf`.

`telegraf\Start-Telegraf.ps1` reads `.env` and starts `runtime\telegraf\telegraf.exe` by passing each URL in `TELEGRAF_CONFIGS` as a `--config` argument. That start command does not use a local `telegraf.conf`. `Install.ps1` does not read those values and does not write them into the service. It does require `.env` to exist before it starts the service.

## Layout

| Path | Role |
| --- | --- |
| `Install.ps1` | Downloads NSSM and Telegraf into `runtime\`, installs both services, the sensor libraries, and PawnIO. |
| `Uninstall.ps1` | Removes both services, `runtime\`, generated sensor files, and PawnIO. The scripts stay. |
| `telegraf\` | Runtime entry point `Start-Telegraf.ps1`. Loads `.env` and starts Telegraf. |
| `.env` | Endpoint list, Influx token, and bucket. Omitted from git. |
| `runtime\` | NSSM, Telegraf, the LibreHardwareMonitor libraries, and the service logs. Omitted from git. |
| `system\` | One-shot Windows and BIOS collector. See `system/README.md`. |
| `sensors\` | Resident hardware sampler and its reader. See `sensors/README.md`. |

`Install.ps1` downloads NSSM `2.24-101-g897c7ad` and Telegraf `1.38.2`. LibreHardwareMonitorLib stays on .NET 10. The installer takes the latest package, including prerelease, whose Windows build targets `net10.0` and whose runtime references are not newer than .NET 10. A .NET 11 build is skipped. PawnIO is the latest GitHub release when the installed driver is missing or older. Resolving those two on every run is intentional. `runtime\lhm\install-manifest.json` records the package versions that run installed and the framework selected for LibreHardwareMonitorLib.

## Prerequisites

- Windows x64.
- PowerShell 7 installed for all users. Both services run `<PowerShell>\pwsh.exe`.
- An elevated session for `Install.ps1` and `Uninstall.ps1`.
- A `.env` file in the project root before installation. The installer starts Telegraf, and the runtime script stops when the token, bucket, or endpoint list is missing.
- Network access to the Telegraf release, the NSSM build, NuGet, and the PawnIO GitHub release.

## Environment

Create `.env` in the project root. `telegraf\Start-Telegraf.ps1` reads it:

```text
INFLUX_TOKEN=
INFLUX_BUCKET=monit_terminals
TELEGRAF_CONFIGS=https://influx.example/api/v2/telegrafs/<config-id>,https://influx.example/api/v2/telegrafs/<config-id>
```

`TELEGRAF_CONFIGS` is the configuration passed to Telegraf. It is a comma-separated list of URLs. `Start-Telegraf.ps1` gives each URL to Telegraf with `--config`. The agent is not started from a local `telegraf.conf`. `INFLUX_TOKEN` and `INFLUX_BUCKET` are process environment variables for that Telegraf process. Blank lines and lines that start with `#` are ignored. A value may be wrapped in one pair of matching quotes.

A non-empty `-InfluxToken`, `-InfluxBucket`, `-ConfigPath`, or `-TelegrafExe` on `Start-Telegraf.ps1` overrides the matching `.env` value for that run. Any other arguments are passed to Telegraf unchanged. A path or URL among them stays with the argument it belongs to.

## Install and remove

Run both from an elevated PowerShell 7 session. `<install>` is the directory that contains these files. Either script can be run again after an interrupted attempt: finished steps are kept, and the remaining steps continue from the current machine state.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\Install.ps1"
pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\Uninstall.ps1"
```

The installer stops an existing copy of each service before it replaces binaries, updates a service that is already registered, and starts it again. A start that finds the service already running counts as success. An existing `telegraf` service whose NSSM application is not `pwsh.exe` is left unchanged.

The installer registers two automatic LocalSystem services through NSSM. It starts `librehardwaremonitor` first. `telegraf` depends on `librehardwaremonitor`, so Windows starts and runs it only after the sensor service is running.

| Service | Process |
| --- | --- |
| `librehardwaremonitor` | `pwsh` running `sensors\Watch-Sensors.ps1` |
| `telegraf` | `pwsh` running `telegraf\Start-Telegraf.ps1`, which passes the `TELEGRAF_CONFIGS` URLs as `--config` |

The installer sets these NSSM values on `telegraf`. The service runs `Start-Telegraf.ps1`. That script passes the URLs from `TELEGRAF_CONFIGS` as `--config`. It does not point Telegraf at a local `telegraf.conf`. The sensor service is documented in `sensors/README.md`.

```text
Application:       <PowerShell>\pwsh.exe
AppParameters:     -NoProfile -ExecutionPolicy Bypass -File "<install>\telegraf\Start-Telegraf.ps1"
AppDirectory:      <install>
DisplayName:       Telegraf
Start:             SERVICE_AUTO_START
ObjectName:        LocalSystem
DependOnService:   librehardwaremonitor
AppStdout:         <install>\runtime\logs\telegraf-service.log
AppStderr:         <install>\runtime\logs\telegraf-service.log
AppRotateFiles:    1
AppRotateBytes:    1048576
AppExit Default:   Restart
AppRestartDelay:   5000
AppThrottle:       10000
```

`AppExit Default = Restart` starts the process again after a crash. `AppRestartDelay` waits 5 seconds before that restart. `AppThrottle` stops the restart loop when the process dies within 10 seconds of starting. Stdout and stderr append to the same log. NSSM rotates that file at 1 MB and keeps the previous copy.

`Uninstall.ps1` removes `telegraf` before `librehardwaremonitor`, then deletes `runtime\`, leftover sensor files, and PawnIO. A file that is still open, a missing `nssm.exe`, or a PawnIO uninstall that leaves the driver behind is reported. The next run removes what remains. Exit `1060` means the service is already gone. Exit `1072` means Windows will delete it at the next reboot. The PowerShell scripts stay.

## Web UI inputs

Add these exec inputs in the web UI. Each collector prints Influx line protocol on stdout and then exits. The service receives the inputs from the HTTP endpoints listed in `.env`.

```toml
[[inputs.exec]]
  commands = ['pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\system\Collect-System.ps1"']
  interval = "10s"
  timeout = "5s"
  data_format = "influx"
```

```toml
[[inputs.exec]]
  commands = ['pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\sensors\Collect-Sensors.ps1"']
  interval = "10s"
  timeout = "5s"
  data_format = "influx"
```

Field layout, freshness, and the network-adapter filter are documented in `system/README.md` and `sensors/README.md`.

## Run manually

The service is the normal path. These commands run the same entry point in the current session, so Telegraf still receives the `TELEGRAF_CONFIGS` URLs as `--config` instead of a local `telegraf.conf`. `-Test` passes `--test` to Telegraf. `-Once` passes `--once`.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\telegraf\Start-Telegraf.ps1" -Test
pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\telegraf\Start-Telegraf.ps1" -Once
```

## Notes

- Create `.env` before `Install.ps1`. The installer starts Telegraf at the end of a successful run.
- Run `LibreHardwareMonitor.exe` or the `librehardwaremonitor` service, and keep the other closed. Both open the hardware.
- Service logs live in `runtime\logs\`. The sensor watcher log is `watch-sensors.log`.
- `Uninstall.ps1` leaves `Install.ps1`, `Uninstall.ps1`, `telegraf\`, `system\`, and `sensors\` in place.

## Disclaimer

These scripts were written with the assistance of an AI agent, in whole or in part. A human tested them in a real environment before publication.
