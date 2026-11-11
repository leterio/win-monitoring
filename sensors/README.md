# Sensors

## Purpose

These scripts publish hardware readings to Telegraf without opening LibreHardwareMonitor and without loading its library on every collection. `Watch-Sensors.ps1` stays running, opens the library once, and keeps a line-protocol snapshot up to date. `Collect-Sensors.ps1` only prints that snapshot for `inputs.exec`.

`LibreHardwareMonitor.exe` and `Watch-Sensors.ps1` both open the hardware. Run only one of them.

## Layout

| Path | Role |
| --- | --- |
| `Watch-Sensors.ps1` | Opens the library once, updates every 10 seconds, and replaces `sensors.metrics.line`. |
| `Collect-Sensors.ps1` | Prints the snapshot for Telegraf. |
| `..\runtime\lhm\` | LibreHardwareMonitor assemblies. Created by the installer and omitted from git. |
| `..\runtime\logs\` | Plain-text log for `Watch-Sensors.ps1`, beside the Telegraf service log. Omitted from git. |
| `sensors.metrics.line` | Latest line-protocol sample. Omitted from git. |
| `README.md` | This document. |

## Prerequisites

- An elevated PowerShell 7 session for install and removal. The library targets .NET 10, and the reader uses `pwsh.exe`.
- [PawnIO](https://github.com/namazso/PawnIO.Setup). `Install.ps1` downloads the latest release when the installed driver is missing or older. Without it, CPU temperature, clocks, and voltages stay empty.

## Install or update

`Install.ps1` replaces the files in `runtime\lhm`. If a DLL is still loaded, the previous directory is moved aside and a new `runtime\lhm` is written. It then installs PawnIO when needed and points the `librehardwaremonitor` service at `Watch-Sensors.ps1`. The service runs as LocalSystem and starts automatically. Reinstalling stops that service before starting it again. The desktop `LibreHardwareMonitor.exe` does not stay open beside the watcher.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\Install.ps1"
```

The installer stays on .NET 10. It downloads the latest LibreHardwareMonitorLib from NuGet, including prerelease, whose Windows build targets `net10.0` and whose runtime references are not newer than .NET 10. A .NET 11 build is skipped. That resolution on every run is intentional. Dependencies use the first available target framework from `net10.0` down to `netstandard2.0`, then the installer walks the dependencies of that group. Each package is downloaded at the minimum version the nuspec declares. Resolved ids, versions, and the framework selected for LibreHardwareMonitorLib are written to `runtime\lhm\install-manifest.json`.

A second run updates the service that is already registered and starts it when it is stopped. The installer starts `librehardwaremonitor` before it configures `telegraf`, and sets `telegraf` to depend on this service.

The installer sets these NSSM values on `librehardwaremonitor`:

```text
Application:       <PowerShell>\pwsh.exe
AppParameters:     -NoProfile -ExecutionPolicy Bypass -File "<install>\sensors\Watch-Sensors.ps1"
AppDirectory:      <install>\sensors
DisplayName:       Telegraf Sensors
Start:             SERVICE_AUTO_START
ObjectName:        LocalSystem
AppStdout:         <install>\runtime\logs\watch-sensors.log
AppStderr:         <install>\runtime\logs\watch-sensors.log
AppRotateFiles:    1
AppRotateBytes:    1048576
AppStdoutCreationDisposition: 4
AppStderrCreationDisposition: 4
AppExit Default:   Restart
AppRestartDelay:   5000
AppThrottle:       10000
```

`AppExit Default = Restart` starts the process again after a crash. `AppRestartDelay` waits 5 seconds before that restart. `AppThrottle` stops the restart loop when the process dies within 10 seconds of starting. Stdout and stderr append to the same log (`CreationDisposition` 4). NSSM rotates that file at 1 MB and keeps the previous copy.

Enter the exec block from [Telegraf](#telegraf) in the web UI after the service is installed.

## Remove

`Uninstall.ps1` removes the `telegraf` service first, then stops `librehardwaremonitor`, removes that service, and deletes `runtime\`, which holds `lhm` and `logs\watch-sensors*.log`, including the timestamped copies NSSM writes when that log rotates. It also deletes `sensors.metrics.line` and its temporary file. The PowerShell scripts stay. The same run removes NSSM and PawnIO. A file that is still open, a missing `nssm.exe`, or a PawnIO driver that is still registered is reported. Run the uninstaller again to remove what remains.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\Uninstall.ps1"
```

## Data

`Watch-Sensors.ps1` opens `LibreHardwareMonitor.Hardware.Computer` once, calls `Update()` every 10 seconds, and writes `sensors.metrics.line` through a temporary file in the same directory. Each sensor line uses this template:

```text
lhm_sensor,device={device},type={type},hardwaretype={hardwaretype} {name}={value}
```

Tags and field names drop `#`. A backslash, space, comma, or `=` in those values is escaped with a backslash. Field values are numbers written with a decimal point. Each cycle appends one duration line:

```text
lhm_sensor,device=lhm,type=duration,hardwaretype=computer update_ms={milliseconds}
```

`Collect-Sensors.ps1` prints the snapshot only when the file exists, is non-empty, and was written within the last 30 seconds. It drops lines whose `device` display name contains `Depurador de Kernel`, `Kernel Debug`, or `WAN Miniport`. The watcher still writes those lines into the snapshot. The reader removes them from stdout.

## Run manually

Start the watcher, or the `librehardwaremonitor` service, before reading the snapshot. A direct read does not open the hardware.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\sensors\Collect-Sensors.ps1"
```

Stdout is the filtered snapshot, UTF-8 without a byte-order mark, and the process exits 0. A missing, empty, or stale snapshot prints the reason on stderr and exits 1. Telegraf imports only stdout, so that failure publishes nothing.

## Telegraf

Add this input in the InfluxDB web UI. The service receives it from the HTTP endpoints listed in `.env`. Stdout is already Influx line protocol.

```toml
[[inputs.exec]]
  commands = ['pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\sensors\Collect-Sensors.ps1"']
  interval = "10s"
  timeout = "5s"
  data_format = "influx"
```

`interval` is 10 seconds, the same period the watcher uses to replace the snapshot. The 30 second freshness limit still accepts the previous sample if one cycle is late. `timeout` is 5 seconds. The reader only reads a file. `data_format` is `influx` because stdout is already line protocol. Telegraf imports stdout and ignores stderr.

## Notes

- Run only one hardware owner: `Watch-Sensors.ps1` or `LibreHardwareMonitor.exe`.
- Stdout and stderr of the service go to `runtime\logs\watch-sensors.log`. Log lines are plain text with a timestamp and no color codes. On an interactive console, info and warnings are printed there as well.
- The log records how long `Computer.Open` took when the process starts, and how long `Computer.Close` took when it exits.
- `Install.ps1` and `Uninstall.ps1` can be run again after an interrupted attempt. Finished steps stay, and the remaining steps continue from the current machine state.

## Disclaimer

These scripts were written with the assistance of an AI agent, in whole or in part. A human tested them in a real environment before publication.
