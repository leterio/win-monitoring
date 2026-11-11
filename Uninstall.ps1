$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Configuration

$ServiceName = 'telegraf'
$SensorServiceName = 'librehardwaremonitor'

#endregion

#region Helpers

function Get-ScriptRootPath {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return $PSScriptRoot
    }

    return (Split-Path -Parent $PSCommandPath)
}

function Assert-Administrator {
    $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = [System.Security.Principal.WindowsPrincipal]::new($Identity)
    if (-not $Principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-UninstallLog -Message 'Run this uninstaller from an elevated PowerShell session.' -Level Error
        throw 'Uninstall.ps1 must run in an elevated PowerShell session.'
    }
}

function Write-UninstallLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Progress', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Progress'
    )

    $Color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        default { 'Cyan' }
    }

    Write-Host $Message -ForegroundColor $Color
}

function Test-RuntimeBinaryPath {
    param(
        [AllowEmptyString()]
        [string]$PathName
    )

    if ([string]::IsNullOrWhiteSpace($PathName)) {
        return $false
    }

    $Runtime = Join-Path (Get-ScriptRootPath) 'runtime'
    return $PathName.IndexOf($Runtime, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Remove-ServiceRegistration {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$NssmPath
    )

    if (Test-Path -LiteralPath $NssmPath) {
        $Output = & $NssmPath remove $Name confirm 2>&1
        if ($LASTEXITCODE -eq 0) {
            return
        }

        $Detail = ($Output | Out-String).Trim()
        Write-UninstallLog -Message "nssm remove $Name failed with exit code ${LASTEXITCODE}. $Detail" -Level Warning
    }

    $Output = & "$env:SystemRoot\System32\sc.exe" delete $Name 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1060 -or $Output -match '1060') {
        return
    }

    if ($LASTEXITCODE -eq 1072 -or $Output -match '1072') {
        Write-UninstallLog -Message "Service $Name is marked for deletion and will disappear after a reboot." -Level Warning
        return
    }

    throw "sc delete $Name failed with exit code $LASTEXITCODE. $($Output.Trim())"
}

function Remove-InstalledService {
    param(
        [Parameter(Mandatory)]
        [string]$NssmPath,

        [Parameter(Mandatory)]
        [string]$TelegrafPath
    )

    $Service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'"
    if ($null -eq $Service) {
        Write-UninstallLog -Message "Service $ServiceName is not installed." -Level Warning
        return
    }

    $NssmExists = Test-Path -LiteralPath $NssmPath
    if ($NssmExists) {
        $null = & $NssmPath status $ServiceName 2>&1
        if ($LASTEXITCODE -eq 0) {
            $Application = ((& $NssmPath get $ServiceName Application 2>&1 | Out-String)).Trim()
            $Parameters = ((& $NssmPath get $ServiceName AppParameters 2>&1 | Out-String)).Trim()
            $StartScript = Join-Path (Get-ScriptRootPath) 'telegraf\Start-Telegraf.ps1'
            $Managed = ($Application -eq $TelegrafPath) -or ($Parameters.IndexOf($StartScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or (Test-RuntimeBinaryPath -PathName $Service.PathName)
            if (-not $Managed) {
                Write-UninstallLog -Message "Service $ServiceName points at '$Application' and was left installed." -Level Warning
                return
            }
        } elseif (-not (Test-RuntimeBinaryPath -PathName $Service.PathName)) {
            Write-UninstallLog -Message "Service $ServiceName was left installed." -Level Warning
            return
        }
    } elseif (-not (Test-RuntimeBinaryPath -PathName $Service.PathName)) {
        Write-UninstallLog -Message "nssm.exe was not found at $NssmPath. Service $ServiceName was left installed." -Level Warning
        return
    } else {
        Write-UninstallLog -Message "nssm.exe was not found at $NssmPath. Removing the remaining $ServiceName service record." -Level Warning
    }

    if ($Service.State -ne 'Stopped') {
        Write-UninstallLog -Message "Stopping $ServiceName service"
        Stop-HostService -Name $ServiceName
    }

    Write-UninstallLog -Message "Removing service $ServiceName"
    Remove-ServiceRegistration -Name $ServiceName -NssmPath $NssmPath
    Write-UninstallLog -Message "Service $ServiceName removed." -Level Success
}

function Stop-HostService {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $Service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'"
    if ($null -eq $Service -or $Service.State -eq 'Stopped') {
        return
    }

    $ProcessId = [int]$Service.ProcessId
    & "$env:SystemRoot\System32\sc.exe" stop $Name | Out-Null
    $Deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Seconds 1
        $Service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'"
    } while ($null -ne $Service -and $Service.State -ne 'Stopped' -and (Get-Date) -lt $Deadline)

    if ($null -ne $Service -and $Service.State -ne 'Stopped' -and $ProcessId -gt 0) {
        Write-UninstallLog -Message "Stopping process $ProcessId." -Level Warning
        Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$ProcessId" | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }

        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        $Deadline = (Get-Date).AddSeconds(15)
        do {
            Start-Sleep -Seconds 1
            $Service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'"
        } while ($null -ne $Service -and $Service.State -ne 'Stopped' -and (Get-Date) -lt $Deadline)
    }

    if ($null -ne $Service -and $Service.State -ne 'Stopped') {
        throw "Service $Name did not stop."
    }
}

function Remove-SensorService {
    param(
        [Parameter(Mandatory)]
        [string]$NssmPath
    )

    $Service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$SensorServiceName'"
    if ($null -eq $Service) {
        Write-UninstallLog -Message "Service $SensorServiceName is not installed." -Level Warning
        return
    }

    $NssmExists = Test-Path -LiteralPath $NssmPath
    $KnownToNssm = $false
    if ($NssmExists) {
        $null = & $NssmPath status $SensorServiceName 2>&1
        $KnownToNssm = $LASTEXITCODE -eq 0
    }

    if (-not $KnownToNssm -and -not (Test-RuntimeBinaryPath -PathName $Service.PathName)) {
        Write-UninstallLog -Message "Service $SensorServiceName was left installed." -Level Warning
        return
    }

    if (-not $NssmExists) {
        Write-UninstallLog -Message "nssm.exe was not found at $NssmPath. Removing the remaining $SensorServiceName service record." -Level Warning
    }

    if ($Service.State -ne 'Stopped') {
        Write-UninstallLog -Message "Stopping $SensorServiceName service"
        Stop-HostService -Name $SensorServiceName
    }

    Write-UninstallLog -Message "Removing service $SensorServiceName"
    Remove-ServiceRegistration -Name $SensorServiceName -NssmPath $NssmPath
    Write-UninstallLog -Message "Service $SensorServiceName removed." -Level Success
}

function Remove-SensorFiles {
    $Root = Join-Path (Get-ScriptRootPath) 'sensors'
    $GeneratedNames = @(
        'lhm',
        'sensors.metrics.line',
        'sensors.metrics.line.tmp'
    )

    foreach ($Name in $GeneratedNames) {
        $Path = Join-Path $Root $Name
        if (-not (Test-Path -LiteralPath $Path)) {
            continue
        }

        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-UninstallLog -Message "Removed $Path" -Level Success
        } catch {
            Write-UninstallLog -Message "Unable to remove $Path. Run Uninstall.ps1 again after the file is released." -Level Warning
        }
    }

    foreach ($Directory in @($Root, (Join-Path $Root 'logs'))) {
        if (-not (Test-Path -LiteralPath $Directory)) {
            continue
        }

        Get-ChildItem -LiteralPath $Directory -Filter 'watch-sensors*.log' -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                Write-UninstallLog -Message "Removed $($_.FullName)" -Level Success
            } catch {
                Write-UninstallLog -Message "Unable to remove $($_.FullName). Run Uninstall.ps1 again after the file is released." -Level Warning
            }
        }
    }

    $LogDirectory = Join-Path $Root 'logs'
    if ((Test-Path -LiteralPath $LogDirectory) -and -not (Get-ChildItem -LiteralPath $LogDirectory -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $LogDirectory -Force -ErrorAction SilentlyContinue
    }
}

function Uninstall-PawnIo {
    $Keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO'
    )
    $Entry = $null
    foreach ($Key in $Keys) {
        $Item = Get-ItemProperty -Path $Key -ErrorAction SilentlyContinue
        if ($null -ne $Item) {
            $Entry = $Item
            break
        }
    }

    if ($null -eq $Entry) {
        Write-UninstallLog -Message 'PawnIO is not installed.' -Level Warning
        Remove-PawnIoDriver
        return
    }

    $Command = [string]$Entry.QuietUninstallString
    if ([string]::IsNullOrWhiteSpace($Command)) {
        $Command = [string]$Entry.UninstallString
    }

    if ([string]::IsNullOrWhiteSpace($Command)) {
        throw 'PawnIO is installed, but its uninstall command is missing.'
    }

    Write-UninstallLog -Message "Uninstalling PawnIO $($Entry.DisplayVersion)"
    $ExitCode = 0
    try {
        $Process = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $Command) -Wait -PassThru -WindowStyle Hidden
        $ExitCode = $Process.ExitCode
    } catch {
        $ExitCode = -1
        Write-UninstallLog -Message "PawnIO uninstaller could not be started. $($_.Exception.Message)" -Level Warning
    }

    if ($ExitCode -ne 0) {
        Write-UninstallLog -Message "PawnIO uninstall reported exit code $ExitCode. Removing the remaining driver registration." -Level Warning
    }

    Remove-PawnIoDriver
    $Remaining = foreach ($Key in $Keys) { Get-ItemProperty -Path $Key -ErrorAction SilentlyContinue }
    if ($Remaining) {
        throw 'PawnIO uninstall finished, but the product is still registered.'
    }

    Write-UninstallLog -Message 'PawnIO removed.' -Level Success
}

function Remove-PawnIoDriver {
    $Enum = (& pnputil.exe /enum-drivers 2>&1 | Out-String)
    $Published = [regex]::Matches($Enum, '(?im)oem\d+\.inf\s*(?:\r?\n).*?pawnio\.inf')
    foreach ($Match in $Published) {
        $Inf = [regex]::Match($Match.Value, '(?i)oem\d+\.inf').Value
        if ([string]::IsNullOrWhiteSpace($Inf)) {
            continue
        }

        Write-UninstallLog -Message "Removing driver package $Inf"
        & pnputil.exe /delete-driver $Inf /uninstall | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-UninstallLog -Message "pnputil /delete-driver $Inf /uninstall failed with exit code $LASTEXITCODE." -Level Warning
        }
    }

    & sc.exe query PawnIO 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        & sc.exe delete PawnIO | Out-Null
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1060 -and $LASTEXITCODE -ne 1072) {
            Write-UninstallLog -Message "sc delete PawnIO failed with exit code $LASTEXITCODE." -Level Warning
        }
    }
}

function Invoke-Main {
    Write-UninstallLog -Message 'Starting uninstaller'
    Assert-Administrator

    $RuntimeDirectory = Join-Path (Get-ScriptRootPath) 'runtime'
    $NssmPath = Join-Path $RuntimeDirectory 'nssm\nssm.exe'
    $TelegrafPath = Join-Path $RuntimeDirectory 'telegraf\telegraf.exe'

    Remove-InstalledService -NssmPath $NssmPath -TelegrafPath $TelegrafPath
    Remove-SensorService -NssmPath $NssmPath

    if (Test-Path -LiteralPath $RuntimeDirectory) {
        try {
            Remove-Item -LiteralPath $RuntimeDirectory -Recurse -Force -ErrorAction Stop
            Write-UninstallLog -Message "Removed $RuntimeDirectory" -Level Success
        } catch {
            Write-UninstallLog -Message "Unable to remove $RuntimeDirectory. Run Uninstall.ps1 again after the remaining files are released." -Level Warning
        }
    }

    Remove-SensorFiles
    Uninstall-PawnIo
    Write-UninstallLog -Message 'Uninstall complete.' -Level Success
}

#endregion

Invoke-Main
