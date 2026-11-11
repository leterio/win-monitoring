$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Configuration

$SnapshotFileName = 'sensors.metrics.line'
$MaxSnapshotAgeSeconds = 30

#endregion

#region Helpers

function Get-ScriptRootPath {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return $PSScriptRoot
    }

    return (Split-Path -Parent $PSCommandPath)
}

function ConvertFrom-LineProtocolIdentifier {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $Placeholder = [string]([char]1)
    $Text = $Value.Replace('\\', $Placeholder)
    $Text = $Text.Replace('\ ', ' ').Replace('\,', ',').Replace('\=', '=')
    return $Text.Replace($Placeholder, '\')
}

function Test-ExcludedNetworkAdapter {
    param(
        [Parameter(Mandatory)]
        [string]$Line
    )

    if ($Line -notmatch 'device=((?:\\.|[^,])*)') {
        return $false
    }

    $Device = ConvertFrom-LineProtocolIdentifier -Value $Matches[1]
    return $Device -match '(?i)Depurador de Kernel|Kernel Debug|WAN Miniport'
}

#endregion

#region Main

function Invoke-Main {
    $SnapshotPath = Join-Path (Get-ScriptRootPath) $SnapshotFileName

    if (-not (Test-Path -LiteralPath $SnapshotPath)) {
        [Console]::Error.WriteLine("Sensor snapshot was not found at: $SnapshotPath")
        exit 1
    }

    $Snapshot = Get-Item -LiteralPath $SnapshotPath
    $AgeSeconds = ((Get-Date) - $Snapshot.LastWriteTime).TotalSeconds

    if ($AgeSeconds -gt $MaxSnapshotAgeSeconds) {
        [Console]::Error.WriteLine(("Sensor snapshot is stale ({0:N0}s) at: {1}" -f $AgeSeconds, $SnapshotPath))
        exit 1
    }

    if ($Snapshot.Length -eq 0) {
        [Console]::Error.WriteLine("Sensor snapshot is empty at: $SnapshotPath")
        exit 1
    }

    $Encoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $Encoding
    $Lines = [System.IO.File]::ReadAllLines($SnapshotPath, $Encoding) | Where-Object {
        -not (Test-ExcludedNetworkAdapter -Line $_)
    }
    [Console]::Out.Write(($Lines -join "`n") + "`n")
}

#endregion

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}
