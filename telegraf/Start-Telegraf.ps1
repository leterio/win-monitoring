[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter()]
    [string]$TelegrafExe = '',

    [Parameter()]
    [string[]]$ConfigPath = @(),

    [Parameter()]
    [string]$InfluxToken = '',

    [Parameter()]
    [string]$InfluxBucket = '',

    [Parameter()]
    [switch]$Test,

    [Parameter()]
    [switch]$Once,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$TelegrafArgument = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Helpers

function Get-ScriptRootPath {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return $PSScriptRoot
    }

    return (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

function Get-InstallRootPath {
    return (Split-Path -Parent (Get-ScriptRootPath))
}

function Test-IsRemoteConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return $Path -match '^https?://'
}

function Import-DotEnv {
    $Path = Join-Path (Get-InstallRootPath) '.env'
    if (-not (Test-Path -LiteralPath $Path)) {
        throw ".env was not found at: $Path"
    }

    foreach ($Line in [System.IO.File]::ReadAllLines($Path)) {
        $Text = $Line.Trim()
        if ($Text.Length -eq 0 -or $Text.StartsWith('#')) {
            continue
        }

        $Separator = $Text.IndexOf('=')
        if ($Separator -lt 1) {
            throw '.env contains an invalid entry.'
        }

        $Name = $Text.Substring(0, $Separator).Trim()
        $Value = $Text.Substring($Separator + 1).Trim()
        $Quoted = (($Value.StartsWith('"') -and $Value.EndsWith('"')) -or ($Value.StartsWith("'") -and $Value.EndsWith("'")))
        if ($Quoted -and $Value.Length -ge 2) {
            $Value = $Value.Substring(1, $Value.Length - 2)
        }

        Set-Item -Path "Env:$Name" -Value $Value
    }
}

function Resolve-TelegrafExePath {
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $Root = Get-InstallRootPath
    $RuntimeExe = Join-Path $Root 'runtime\telegraf\telegraf.exe'
    if (Test-Path -LiteralPath $RuntimeExe) {
        return $RuntimeExe
    }

    return (Join-Path $Root 'telegraf.exe')
}

function Test-LocalConfigPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Assert-TelegrafInputs {
    param(
        [Parameter(Mandatory)]
        [string]$ExePath,

        [Parameter()]
        [string[]]$ConfigPaths = @()
    )

    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        throw "telegraf.exe was not found at: $ExePath"
    }

    foreach ($Path in $ConfigPaths) {
        if ((-not (Test-IsRemoteConfig -Path $Path)) -and (-not (Test-LocalConfigPath -Path $Path))) {
            throw "Telegraf config was not found at: $Path"
        }
    }
}

function New-TelegrafArgumentList {
    param(
        [Parameter()]
        [string[]]$ConfigPaths = @(),

        [Parameter()]
        [switch]$TestMode,

        [Parameter()]
        [switch]$OnceMode,

        [Parameter()]
        [string[]]$AdditionalArguments = @()
    )

    $Arguments = [System.Collections.Generic.List[string]]::new()

    foreach ($Path in $ConfigPaths) {
        $Arguments.Add('--config')
        $Arguments.Add($Path)
    }

    if ($TestMode) {
        $Arguments.Add('--test')
    } elseif ($OnceMode) {
        $Arguments.Add('--once')
    }

    foreach ($Argument in $AdditionalArguments) {
        $Arguments.Add($Argument)
    }

    return $Arguments.ToArray()
}

function Write-StartupSummary {
    param(
        [Parameter()]
        [string[]]$ConfigPaths = @(),

        [Parameter(Mandatory)]
        [string]$Bucket
    )

    if ($ConfigPaths.Count -gt 0) {
        Write-Host 'Starting Telegraf with configs:'

        foreach ($Path in $ConfigPaths) {
            Write-Host " - $Path"
        }
    } else {
        Write-Host 'Starting Telegraf without explicit configs.'
    }

    Write-Host "InfluxDB bucket: $Bucket"
}

#endregion

#region Main

function Invoke-Main {
    Import-DotEnv

    $Token = $InfluxToken
    if ([string]::IsNullOrWhiteSpace($Token)) {
        $Token = [string]$env:INFLUX_TOKEN
    }

    $Bucket = $InfluxBucket
    if ([string]::IsNullOrWhiteSpace($Bucket)) {
        $Bucket = [string]$env:INFLUX_BUCKET
    }

    $ResolvedTelegrafExe = Resolve-TelegrafExePath -Path $TelegrafExe
    $ConfigPaths = @($ConfigPath | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($ConfigPaths.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$env:TELEGRAF_CONFIGS)) {
        $ConfigPaths = @(([string]$env:TELEGRAF_CONFIGS).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw 'INFLUX_TOKEN is missing from .env.'
    }

    if ([string]::IsNullOrWhiteSpace($Bucket)) {
        throw 'INFLUX_BUCKET is missing from .env.'
    }

    if ($ConfigPaths.Count -eq 0) {
        throw 'TELEGRAF_CONFIGS is missing from .env.'
    }
    $AdditionalArguments = [System.Collections.Generic.List[string]]::new()

    foreach ($Argument in $TelegrafArgument) {
        if ([string]::IsNullOrWhiteSpace($Argument)) {
            continue
        }

        $AdditionalArguments.Add($Argument)
    }

    Assert-TelegrafInputs -ExePath $ResolvedTelegrafExe -ConfigPaths $ConfigPaths

    # Environment variables apply only to this process and to the telegraf.exe it starts.
    $env:INFLUX_TOKEN = $Token
    $env:INFLUX_BUCKET = $Bucket

    $Arguments = @(New-TelegrafArgumentList `
        -ConfigPaths $ConfigPaths `
        -TestMode:$Test `
        -OnceMode:$Once `
        -AdditionalArguments $AdditionalArguments.ToArray())

    Write-StartupSummary -ConfigPaths $ConfigPaths -Bucket $Bucket

    & $ResolvedTelegrafExe @Arguments
    exit $LASTEXITCODE
}

#endregion

Invoke-Main
