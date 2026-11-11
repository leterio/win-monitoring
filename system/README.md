# System

## Purpose

`Collect-System.ps1` collects Windows and BIOS identity and prints one Influx line-protocol metric per line on stdout. A single run prints the lines and exits. Telegraf `inputs.exec` reads that stdout directly.

The collector does not write an output file and it is not a resident service. The Telegraf service loads this input from the InfluxDB web UI over HTTP. `telegraf\Start-Telegraf.ps1` reads the endpoint list, token, and bucket from `.env`.

## Layout

| Path | Role |
| --- | --- |
| `Collect-System.ps1` | One-shot collector. Prints `osinfo` and `biosinfo` on stdout. |
| `README.md` | This document. |

## Prerequisites

- PowerShell 7. The command below uses `pwsh.exe`.
- Permission to read `Win32_OperatingSystem`, `Win32_BIOS`, and `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion`.

No driver and no extra package are required.

## Install or update

The script is part of the project tree. `Install.ps1` does not register a service for it. That installer registers the Telegraf service, which runs the exec input entered in the web UI.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\Install.ps1"
```

Run the installer from an elevated session. Enter the exec block from [Telegraf](#telegraf) in the web UI after the service is installed.

## Remove

`Uninstall.ps1` removes the Telegraf service, NSSM, and `runtime\`. It leaves `Collect-System.ps1` in place. The same run also removes the sensor service, generated sensor files, and PawnIO. A second run continues from whatever that first run left behind. A file that is still open stays, with a warning, until a later run can delete it.

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\Uninstall.ps1"
```

## Data

| Measurement | Fields | Source |
| --- | --- | --- |
| `osinfo` | `os_name`, `os_version` | `Win32_OperatingSystem` and `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion` |
| `biosinfo` | `version`, `release_date` | `Win32_BIOS` |

`os_name` joins `ProductName` with `DisplayVersion`, or with `ReleaseId` when the display version is empty. An example is `Windows 10 Pro 25H2`. `os_version` is `Win32_OperatingSystem.Version` plus the `UBR` registry value. `version` is `SMBIOSBIOSVersion`. `release_date` is `Win32_BIOS.ReleaseDate`. String fields are quoted, and a quote inside a value is escaped. One collection takes about 200 ms.

## Run manually

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\system\Collect-System.ps1"
```

Expected stdout:

```text
osinfo os_name="Windows 10 Pro 25H2",os_version="10.0.26200.9711"
biosinfo version="R1EET65W(1.65 )",release_date="07/21/2025 21:00:00"
```

The values above are an example from this machine. The script prints nothing else and does not write `system.metrics.line`.

## Telegraf

Add this input in the InfluxDB web UI. The service receives it from the HTTP endpoints listed in `.env`. Stdout is already Influx line protocol.

```toml
[[inputs.exec]]
  commands = ['pwsh -NoProfile -ExecutionPolicy Bypass -File "<install>\system\Collect-System.ps1"']
  interval = "10s"
  timeout = "5s"
  data_format = "influx"
```

`interval` is 10 seconds. The script itself finishes in about 200 ms, and `timeout` gives the CIM queries room to finish. `data_format` is `influx` because stdout is already line protocol. Telegraf imports stdout and ignores stderr.

## Notes

- Run the collector from the command line, or let the Telegraf service call it through the HTTP configuration.
- The script does not create or update an output file. Metrics exist only on stdout.
- Stdout is UTF-8 without a byte-order mark.
- `Install.ps1` and `Uninstall.ps1` can be run again after an interrupted attempt. Finished steps stay, and the remaining steps continue from the current machine state.

## Disclaimer

These scripts were written with the assistance of an AI agent, in whole or in part. A human tested them in a real environment before publication.
