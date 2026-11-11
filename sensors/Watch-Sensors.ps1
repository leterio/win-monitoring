$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:LhmResolverRegistered = $false

#region Configuration

$SensorMetricTemplate = 'lhm_sensor,device={0},type={1},hardwaretype={4} {2}={3}'
$SampleIntervalSeconds = 10
$SnapshotFileName = 'sensors.metrics.line'

$EnabledHardware = @{
    Cpu         = $true
    Gpu         = $true
    Memory      = $true
    Motherboard = $true
    Storage     = $true
    Network     = $true
    Battery     = $true
    Controller  = $true
    Psu         = $true
}

#endregion

#region Helpers

function Get-ScriptRootPath {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return $PSScriptRoot
    }

    return (Split-Path -Parent $PSCommandPath)
}

function Get-RuntimeDirectory {
    return (Join-Path (Split-Path -Parent (Get-ScriptRootPath)) 'runtime')
}

function Format-LineProtocolIdentifier {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    $Text = $Value.ToString().Replace('#', '')
    return $Text.Replace('\', '\\').Replace(' ', '\ ').Replace(',', '\,').Replace('=', '\=')
}

function Format-LineProtocolNumber {
    param(
        [Parameter(Mandatory)]
        [double]$Value
    )

    return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Add-TemperatureValue {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Map,

        [Parameter(Mandatory)]
        [string]$Device,

        [Parameter(Mandatory)]
        [double]$Value,

        [Parameter(Mandatory)]
        [string]$HardwareType
    )

    if (-not $Map.ContainsKey($Device)) {
        $Map[$Device] = @{
            Values       = @()
            HardwareType = $HardwareType
        }
    }

    $Map[$Device]['Values'] += $Value
}

function New-SensorMetric {
    param(
        [Parameter(Mandatory)]
        [string]$Device,

        [Parameter(Mandatory)]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$HardwareType
    )

    return ($SensorMetricTemplate -f `
        (Format-LineProtocolIdentifier $Device),
        (Format-LineProtocolIdentifier $Type),
        (Format-LineProtocolIdentifier $Name),
        (Format-LineProtocolNumber -Value ([double]$Value)),
        (Format-LineProtocolIdentifier $HardwareType))
}

function New-SensorMetricLines {
    param(
        [Parameter(Mandatory)]
        $Metrics,

        [Parameter(Mandatory)]
        [int]$UpdateMilliseconds
    )

    $Lines = New-Object System.Collections.Generic.List[object]
    foreach ($Metric in @($Metrics)) {
        $Lines.Add($Metric)
    }

    $Lines.Add((New-SensorMetric -Device 'lhm' -Type 'duration' -Name 'update_ms' -Value $UpdateMilliseconds -HardwareType 'computer'))
    return ,$Lines
}

function Initialize-LhmRuntime {
    $LibDirectory = Join-Path (Get-RuntimeDirectory) 'lhm'
    $LibraryPath = Join-Path $LibDirectory 'LibreHardwareMonitorLib.dll'

    if (-not (Test-Path -LiteralPath $LibraryPath)) {
        throw "LibreHardwareMonitorLib.dll was not found at: $LibraryPath"
    }

    # Mono.Posix DllImport looks up the native helper on the process PATH.
    if (-not $env:PATH.StartsWith($LibDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        $env:PATH = $LibDirectory + [System.IO.Path]::PathSeparator + $env:PATH
    }

    if (-not ('LhmAssemblyResolver' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
using System.Runtime.Loader;

public static class LhmAssemblyResolver
{
    public static string DirectoryPath;

    public static Assembly Resolve(AssemblyLoadContext context, AssemblyName assemblyName)
    {
        if (string.IsNullOrEmpty(DirectoryPath) || assemblyName == null)
            return null;

        var path = Path.Combine(DirectoryPath, assemblyName.Name + ".dll");
        if (!File.Exists(path))
            return null;

        return context.LoadFromAssemblyPath(path);
    }
}
'@
    }

    [LhmAssemblyResolver]::DirectoryPath = $LibDirectory

    if (-not $script:LhmResolverRegistered) {
        $Resolve = [LhmAssemblyResolver].GetMethod('Resolve')
        $script:LhmResolveHandler = [System.Delegate]::CreateDelegate(
            [System.Func[System.Runtime.Loader.AssemblyLoadContext, System.Reflection.AssemblyName, System.Reflection.Assembly]],
            $Resolve)

        [System.Runtime.Loader.AssemblyLoadContext]::Default.add_Resolving($script:LhmResolveHandler)
        $script:LhmResolverRegistered = $true
    }

    $Loaded = @([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'LibreHardwareMonitorLib' })
    if ($Loaded.Count -eq 0) {
        [void][System.Reflection.Assembly]::LoadFrom($LibraryPath)
    }
}

function New-LhmComputer {
    $Computer = New-Object LibreHardwareMonitor.Hardware.Computer
    $Computer.IsCpuEnabled = [bool]$EnabledHardware.Cpu
    $Computer.IsGpuEnabled = [bool]$EnabledHardware.Gpu
    $Computer.IsMemoryEnabled = [bool]$EnabledHardware.Memory
    $Computer.IsMotherboardEnabled = [bool]$EnabledHardware.Motherboard
    $Computer.IsControllerEnabled = [bool]$EnabledHardware.Controller
    $Computer.IsStorageEnabled = [bool]$EnabledHardware.Storage
    $Computer.IsNetworkEnabled = [bool]$EnabledHardware.Network
    $Computer.IsPsuEnabled = [bool]$EnabledHardware.Psu
    $Computer.IsBatteryEnabled = [bool]$EnabledHardware.Battery
    return $Computer
}

function Update-LhmHardware {
    param(
        [Parameter(Mandatory)]
        $Hardware
    )

    $Hardware.Update()

    foreach ($SubHardware in @($Hardware.SubHardware)) {
        Update-LhmHardware -Hardware $SubHardware
    }
}

function Get-LhmSensorReadings {
    param(
        [Parameter(Mandatory)]
        $Hardware
    )

    $Readings = [System.Collections.Generic.List[object]]::new()

    foreach ($Sensor in @($Hardware.Sensors)) {
        $Readings.Add([pscustomobject]@{
            Parent       = $Hardware.Identifier.ToString()
            Device       = [string]$Hardware.Name
            HardwareType = [string]$Hardware.HardwareType
            Type         = [string]$Sensor.SensorType
            Name         = [string]$Sensor.Name
            Value        = $Sensor.Value
        })
    }

    foreach ($SubHardware in @($Hardware.SubHardware)) {
        foreach ($Reading in @(Get-LhmSensorReadings -Hardware $SubHardware)) {
            $Readings.Add($Reading)
        }
    }

    return $Readings
}

function Get-SensorMetrics {
    param(
        [Parameter(Mandatory)]
        $Computer
    )

    $TemperatureMap = @{}
    $Metrics = [System.Collections.Generic.List[string]]::new()
    $Readings = [System.Collections.Generic.List[object]]::new()

    foreach ($Hardware in @($Computer.Hardware)) {
        Update-LhmHardware -Hardware $Hardware
    }

    foreach ($Hardware in @($Computer.Hardware)) {
        foreach ($Reading in @(Get-LhmSensorReadings -Hardware $Hardware)) {
            $Readings.Add($Reading)
        }
    }

    foreach ($Sensor in ($Readings | Sort-Object -Property Parent, Type, Name)) {
        if ($null -eq $Sensor.Value) {
            continue
        }

        $DeviceName = $Sensor.Device
        $HardwareType = $Sensor.HardwareType
        $Type = $Sensor.Type
        $Name = $Sensor.Name
        $Value = [double]$Sensor.Value

        if ($Type -eq 'Temperature') {
            Add-TemperatureValue -Map $TemperatureMap -Device $DeviceName -Value $Value -HardwareType $HardwareType
        }

        $Metrics.Add((New-SensorMetric -Device $DeviceName -Type $Type -Name $Name -Value $Value -HardwareType $HardwareType))
    }

    foreach ($Entry in $TemperatureMap.GetEnumerator()) {
        $Average = ($Entry.Value['Values'] | Measure-Object -Average).Average
        $HardwareType = $Entry.Value['HardwareType']

        $Metrics.Add((New-SensorMetric -Device $Entry.Key -Type 'Temperature' -Name 'Average' -Value $Average -HardwareType $HardwareType))
    }

    return $Metrics
}

function Write-WatchLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Progress', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Progress'
    )

    $Line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message

    if ($Level -eq 'Error') {
        [Console]::Error.WriteLine($Line)
        return
    }

    if ([Console]::IsOutputRedirected) {
        [Console]::WriteLine($Line)
        return
    }

    $Directory = Join-Path (Get-RuntimeDirectory) 'logs'
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory | Out-Null
    }

    $Path = Join-Path $Directory 'watch-sensors.log'
    $Stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try {
        $Writer = [System.IO.StreamWriter]::new($Stream, [System.Text.UTF8Encoding]::new($false))
        try {
            $Writer.WriteLine($Line)
        } finally {
            $Writer.Dispose()
        }
    } finally {
        $Stream.Dispose()
    }

    [Console]::WriteLine($Line)
}

function Write-SensorSnapshot {
    param(
        [Parameter(Mandatory)]
        $Metrics
    )

    $SnapshotPath = Join-Path (Get-ScriptRootPath) $SnapshotFileName
    $TemporaryPath = "$SnapshotPath.tmp"
    $Encoding = [System.Text.UTF8Encoding]::new($false)
    $Content = (($Metrics -join [Environment]::NewLine) + [Environment]::NewLine)

    [System.IO.File]::WriteAllText($TemporaryPath, $Content, $Encoding)
    [System.IO.File]::Move($TemporaryPath, $SnapshotPath, $true)
}

#endregion

#region Main

function Invoke-Main {
    Write-WatchLog -Message 'Starting watcher'
    Initialize-LhmRuntime

    $Computer = New-LhmComputer

    try {
        $OpenWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $Computer.Open()
        $OpenWatch.Stop()
        Write-WatchLog -Message ("Computer.Open took {0} ms" -f [int]$OpenWatch.Elapsed.TotalMilliseconds)

        while ($true) {
            $UpdateWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $Metrics = Get-SensorMetrics -Computer $Computer
            $UpdateWatch.Stop()
            $Metrics = New-SensorMetricLines -Metrics $Metrics -UpdateMilliseconds ([int]$UpdateWatch.Elapsed.TotalMilliseconds)
            Write-SensorSnapshot -Metrics $Metrics
            Start-Sleep -Seconds $SampleIntervalSeconds
        }
    } finally {
        if ($null -ne $Computer) {
            $CloseWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $Computer.Close()
            $CloseWatch.Stop()
            Write-WatchLog -Message ("Computer.Close took {0} ms" -f [int]$CloseWatch.Elapsed.TotalMilliseconds)
        }
    }
}

#endregion

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}
