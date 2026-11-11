[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Configuration

$ServiceName = 'telegraf'
$ServiceDisplayName = 'Telegraf'
$ServiceRestartDelayMs = 5000
$ServiceThrottleMs = 10000

$NssmVersion = '2.24-101-g897c7ad'
$NssmDownloadUrl = 'https://nssm.cc/ci/nssm-2.24-101-g897c7ad.zip'
$NssmSha256 = '99f5045fffbffb745d67fe3a065a953c4a3d9c253b868892d9b685b0ee7d07b8'
$NssmEntryName = "nssm-$NssmVersion/win64/nssm.exe"

$TelegrafVersion = '1.38.2'
$TelegrafDownloadUrl = "https://dl.influxdata.com/telegraf/releases/telegraf-${TelegrafVersion}_windows_amd64.zip"
$TelegrafSha256 = '6b9c59feddd6ae1febcefa1b90a05e5591a226366670ac807e882b3ac3bb1f63'


$SensorServiceName = 'librehardwaremonitor'
$SensorServiceDisplayName = 'Telegraf Sensors'
$PackageId = 'LibreHardwareMonitorLib'
$SensorTargetFramework = 'net10.0'
$SensorRuntimeMajorVersion = 10
$TargetFrameworks = @(
    'net10.0',
    'net9.0',
    'net8.0',
    'net7.0',
    'net6.0',
    'net5.0',
    'netcoreapp3.1',
    'netstandard2.1',
    'netstandard2.0'
)
$NuGetIndexUrl = 'https://api.nuget.org/v3-flatcontainer/librehardwaremonitorlib/index.json'
$PawnIoReleasesUrl = 'https://api.github.com/repos/namazso/PawnIO.Setup/releases/latest'

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
        throw 'Install.ps1 must run in an elevated PowerShell session.'
    }
}

function Write-InstallLog {
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

function Save-WebFile {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Destination,

        [string]$FailureMessage = ''
    )

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($FailureMessage)) {
            throw $FailureMessage
        }

        throw
    }
}

function Assert-FileHash {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Algorithm,

        [Parameter(Mandatory)]
        [string]$Expected
    )

    $Actual = (Get-FileHash -Algorithm $Algorithm -LiteralPath $Path).Hash
    if (-not $Actual.Equals($Expected, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Algorithm verification failed for $Path. Expected $Expected but downloaded $Actual."
    }
}

function Expand-ZipEntry {
    param(
        [Parameter(Mandatory)]
        [string]$ZipPath,

        [Parameter(Mandatory)]
        [string]$EntrySuffix,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $Entry = $Zip.Entries | Where-Object {
            $_.FullName.Replace('\', '/').EndsWith($EntrySuffix, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1

        if ($null -eq $Entry) {
            throw "Archive entry ending in '$EntrySuffix' was not found in $ZipPath."
        }

        $Directory = Split-Path -Parent $Destination
        if (-not (Test-Path -LiteralPath $Directory)) {
            New-Item -ItemType Directory -Path $Directory | Out-Null
        }

        $Target = [System.IO.File]::Create($Destination)
        try {
            $Source = $Entry.Open()
            try {
                $Source.CopyTo($Target)
            } finally {
                $Source.Dispose()
            }
        } finally {
            $Target.Dispose()
        }
    } finally {
        $Zip.Dispose()
    }
}

function Wait-ServiceState {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$State,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $Service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'"
        if ($null -eq $Service -or $Service.State -eq $State) {
            return $Service
        }

        if ((Get-Date) -ge $Deadline) {
            return $Service
        }

        Start-Sleep -Seconds 1
    } while ($true)
}

function Invoke-Nssm {
    param(
        [Parameter(Mandatory)]
        [string]$NssmPath,

        [Parameter(Mandatory)]
        [string[]]$ArgumentList
    )

    $Output = & $NssmPath @ArgumentList 2>&1
    if ($LASTEXITCODE -ne 0) {
        $Detail = ($Output | Out-String).Trim()
        throw "nssm $($ArgumentList -join ' ') failed with exit code ${LASTEXITCODE}. $Detail"
    }
}

function Set-NssmServiceConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$NssmPath,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Application,

        [Parameter(Mandatory)]
        [string]$AppParameters,

        [Parameter(Mandatory)]
        [string]$AppDirectory,

        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter(Mandatory)]
        [string]$LogPath
    )

    $Settings = @(
        @('Application', $Application),
        @('AppParameters', $AppParameters),
        @('AppDirectory', $AppDirectory),
        @('DisplayName', $DisplayName),
        @('Start', 'SERVICE_AUTO_START'),
        @('ObjectName', 'LocalSystem'),
        @('AppExit', 'Default', 'Restart'),
        @('AppRestartDelay', "$ServiceRestartDelayMs"),
        @('AppThrottle', "$ServiceThrottleMs"),
        @('AppStdout', $LogPath),
        @('AppStderr', $LogPath),
        @('AppRotateFiles', '1'),
        @('AppRotateBytes', '1048576')
    )

    foreach ($Setting in $Settings) {
        Invoke-Nssm -NssmPath $NssmPath -ArgumentList (@('set', $Name) + $Setting)
    }
}

function Get-InstalledApplication {
    param(
        [Parameter(Mandatory)]
        [string]$NssmPath
    )

    $Output = & $NssmPath get $ServiceName Application 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return (($Output | Out-String).Trim())
}

function Get-SensorsDirectory {
    return (Join-Path (Get-ScriptRootPath) 'sensors')
}

function Get-NssmPath {
    $Path = Join-Path (Get-ScriptRootPath) 'runtime\nssm\nssm.exe'
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "nssm.exe was not found at: $Path"
    }

    return $Path
}

#endregion

#region NuGet

function ConvertTo-NuGetTfm {
    param(
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }

    $Value = $Name.Trim()
    if ($Value.StartsWith('.NETStandard', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'netstandard' + $Value.Substring('.NETStandard'.Length)
    }

    if ($Value.StartsWith('.NETCoreApp', [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'netcoreapp' + $Value.Substring('.NETCoreApp'.Length)
    }

    return $Value.ToLowerInvariant()
}

function ConvertTo-NuGetVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Version
    )

    $Text = $Version.Trim()
    $Metadata = $Text.IndexOf('+')
    if ($Metadata -ge 0) {
        $Text = $Text.Substring(0, $Metadata)
    }

    $PreRelease = ''
    if ($Text.Contains('-')) {
        $Parts = $Text.Split('-', 2)
        $Text = $Parts[0]
        $PreRelease = $Parts[1]
    }

    $Numbers = [System.Collections.Generic.List[int]]::new()
    foreach ($Piece in $Text.Split('.')) {
        $Number = 0
        if (-not [int]::TryParse($Piece, [ref]$Number)) {
            throw "Unsupported NuGet version: $Version"
        }

        $Numbers.Add($Number)
    }

    while ($Numbers.Count -lt 4) {
        $Numbers.Add(0)
    }

    return [pscustomobject]@{
        Numbers    = $Numbers
        PreRelease = $PreRelease
    }
}

function Compare-NuGetVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Left,

        [Parameter(Mandatory)]
        [string]$Right
    )

    $LeftVersion = ConvertTo-NuGetVersion -Version $Left
    $RightVersion = ConvertTo-NuGetVersion -Version $Right
    for ($Index = 0; $Index -lt 4; $Index++) {
        $Difference = $LeftVersion.Numbers[$Index] - $RightVersion.Numbers[$Index]
        if ($Difference -ne 0) {
            return $Difference
        }
    }

    if ([string]::IsNullOrEmpty($LeftVersion.PreRelease) -and [string]::IsNullOrEmpty($RightVersion.PreRelease)) {
        return 0
    }

    if ([string]::IsNullOrEmpty($LeftVersion.PreRelease)) {
        return 1
    }

    if ([string]::IsNullOrEmpty($RightVersion.PreRelease)) {
        return -1
    }

    return (Compare-NuGetPreRelease -Left $LeftVersion.PreRelease -Right $RightVersion.PreRelease)
}

function Compare-NuGetPreRelease {
    param(
        [Parameter(Mandatory)]
        [string]$Left,

        [Parameter(Mandatory)]
        [string]$Right
    )

    $LeftParts = @($Left.Split('.'))
    $RightParts = @($Right.Split('.'))
    $Count = [Math]::Min($LeftParts.Count, $RightParts.Count)
    for ($Index = 0; $Index -lt $Count; $Index++) {
        $LeftPart = $LeftParts[$Index]
        $RightPart = $RightParts[$Index]
        $LeftIsNumber = $LeftPart -match '^\d+$'
        $RightIsNumber = $RightPart -match '^\d+$'
        if ($LeftIsNumber -and $RightIsNumber) {
            $LeftDigits = $LeftPart.TrimStart('0')
            $RightDigits = $RightPart.TrimStart('0')
            if ($LeftDigits.Length -eq 0) { $LeftDigits = '0' }
            if ($RightDigits.Length -eq 0) { $RightDigits = '0' }
            if ($LeftDigits.Length -ne $RightDigits.Length) {
                if ($LeftDigits.Length -lt $RightDigits.Length) { return -1 }
                return 1
            }

            $DigitDifference = [string]::Compare($LeftDigits, $RightDigits, [System.StringComparison]::Ordinal)
            if ($DigitDifference -ne 0) {
                return $DigitDifference
            }

            continue
        }

        if ($LeftIsNumber) {
            return -1
        }

        if ($RightIsNumber) {
            return 1
        }

        $TextDifference = [string]::Compare($LeftPart, $RightPart, [System.StringComparison]::OrdinalIgnoreCase)
        if ($TextDifference -ne 0) {
            return $TextDifference
        }
    }

    return ($LeftParts.Count - $RightParts.Count)
}

function Get-DeclaredPackageVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Range
    )

    $Text = $Range.Trim()
    if ($Text -match '^\[([^,\]]+)\]$') {
        return $Matches[1]
    }

    if ($Text -match '^\[([^,\]]+),') {
        return $Matches[1]
    }

    if ($Text -match '^[\[\(]') {
        throw "Unsupported NuGet version range: $Range"
    }

    return $Text
}

function Select-PreferredFramework {
    param(
        [string[]]$Names
    )

    foreach ($Framework in $TargetFrameworks) {
        if ($Names -contains $Framework) {
            return $Framework
        }
    }

    if ($Names -contains '') {
        return ''
    }

    return $null
}

function Get-PreferredAssemblyPrefix {
    param(
        [Parameter(Mandatory)]
        $Zip
    )

    $LibFrameworks = [System.Collections.Generic.List[string]]::new()
    $RuntimeFrameworks = [System.Collections.Generic.List[string]]::new()
    foreach ($Entry in $Zip.Entries) {
        $Name = $Entry.FullName.Replace('\', '/')
        if ($Name -match '^lib/([^/]+)/[^/]+\.dll$') {
            $EntryFramework = $Matches[1].ToLowerInvariant()
            if (-not $LibFrameworks.Contains($EntryFramework)) {
                $LibFrameworks.Add($EntryFramework)
            }
        }

        if ($Name -match '^runtimes/win-x64/lib/([^/]+)/[^/]+\.dll$') {
            $EntryFramework = $Matches[1].ToLowerInvariant()
            if (-not $RuntimeFrameworks.Contains($EntryFramework)) {
                $RuntimeFrameworks.Add($EntryFramework)
            }
        }
    }

    $AvailableFrameworks = [System.Collections.Generic.List[string]]::new()
    foreach ($EntryFramework in @($RuntimeFrameworks + $LibFrameworks)) {
        if (-not $AvailableFrameworks.Contains($EntryFramework)) {
            $AvailableFrameworks.Add($EntryFramework)
        }
    }

    $Framework = Select-PreferredFramework -Names @($AvailableFrameworks)
    if ($null -eq $Framework) {
        return $null
    }

    $Prefix = if ($RuntimeFrameworks.Contains($Framework)) { "runtimes/win-x64/lib/$Framework/" } else { "lib/$Framework/" }
    return [pscustomobject]@{
        Framework = $Framework
        Prefix    = $Prefix
    }
}

function Get-AssemblyReferenceVersions {
    param(
        [Parameter(Mandatory)]
        $Entry
    )

    Add-Type -AssemblyName System.Reflection.Metadata
    $Source = $Entry.Open()
    try {
        $Memory = [System.IO.MemoryStream]::new()
        $Source.CopyTo($Memory)
    } finally {
        $Source.Dispose()
    }

    $Memory.Position = 0
    $Pe = [System.Reflection.PortableExecutable.PEReader]::new($Memory)
    try {
        $Reader = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($Pe)
        $Versions = @{}
        foreach ($Handle in $Reader.AssemblyReferences) {
            $Reference = $Reader.GetAssemblyReference($Handle)
            $Versions[$Reader.GetString($Reference.Name)] = $Reference.Version
        }

        return $Versions
    } finally {
        $Pe.Dispose()
    }
}

function Test-PackageLoadsOnHost {
    param(
        [Parameter(Mandatory)]
        $Zip
    )

    $Selected = Get-PreferredAssemblyPrefix -Zip $Zip
    if ($null -eq $Selected -or $Selected.Framework -ne $SensorTargetFramework) {
        return $false
    }

    $HostDirectory = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    foreach ($Entry in $Zip.Entries) {
        $Name = $Entry.FullName.Replace('\', '/')
        $IsDirectDll = $Name.StartsWith($Selected.Prefix, [System.StringComparison]::OrdinalIgnoreCase) -and
            $Name.EndsWith('.dll', [System.StringComparison]::OrdinalIgnoreCase) -and
            -not $Name.Substring($Selected.Prefix.Length).Contains('/')
        if (-not $IsDirectDll) {
            continue
        }

        foreach ($Reference in (Get-AssemblyReferenceVersions -Entry $Entry).GetEnumerator()) {
            if ($Reference.Value.Major -gt $SensorRuntimeMajorVersion) {
                return $false
            }

            $HostPath = Join-Path $HostDirectory ($Reference.Key + '.dll')
            if (-not (Test-Path -LiteralPath $HostPath)) {
                continue
            }

            $HostVersion = [System.Reflection.AssemblyName]::GetAssemblyName($HostPath).Version
            if ($Reference.Value -gt $HostVersion) {
                return $false
            }
        }
    }

    return $true
}

function Resolve-LibreHardwareMonitorVersion {
    param(
        [Parameter(Mandatory)]
        [string]$CacheDirectory
    )

    $Index = Invoke-RestMethod -Uri $NuGetIndexUrl
    $Versions = @($Index.versions)
    for ($IndexNumber = $Versions.Count - 1; $IndexNumber -ge 0; $IndexNumber--) {
        $Candidate = [string]$Versions[$IndexNumber]
        $Nupkg = Get-NuGetPackagePath -Id $PackageId -PackageVersion $Candidate -CacheDirectory $CacheDirectory
        $Compatible = Invoke-NuGetPackage -Path $Nupkg -Action {
            param($Zip)
            Test-PackageLoadsOnHost -Zip $Zip
        }
        if ($Compatible) {
            $Latest = [string]$Versions[-1]
            if ($Candidate -ne $Latest) {
                Write-InstallLog -Message "LibreHardwareMonitorLib $Latest is newer than .NET 10. Using $Candidate." -Level Warning
            }

            return $Candidate
        }

        Write-InstallLog -Message "Skipping LibreHardwareMonitorLib $Candidate because it is not a .NET 10 build this host can load." -Level Warning
    }

    throw 'No LibreHardwareMonitorLib version targets .NET 10 on this PowerShell runtime.'
}

function Get-NuGetPackagePath {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$PackageVersion,

        [Parameter(Mandatory)]
        [string]$CacheDirectory
    )

    $IdLower = $Id.ToLowerInvariant()
    $VersionLower = $PackageVersion.ToLowerInvariant()
    $Destination = Join-Path $CacheDirectory "$IdLower.$VersionLower.nupkg"
    if (-not (Test-Path -LiteralPath $Destination)) {
        $Url = "https://api.nuget.org/v3-flatcontainer/$IdLower/$VersionLower/$IdLower.$VersionLower.nupkg"
        Write-InstallLog -Message "Downloading $Id $PackageVersion"
        Save-WebFile -Url $Url -Destination $Destination -FailureMessage "NuGet package '$Id' $PackageVersion was not found."
    }

    Assert-NuGetPackageHash -Id $Id -PackageVersion $PackageVersion -Path $Destination
    return $Destination
}

function Assert-NuGetPackageHash {
    param(
        [Parameter(Mandatory)]
        [string]$Id,

        [Parameter(Mandatory)]
        [string]$PackageVersion,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $IdLower = $Id.ToLowerInvariant()
    $VersionLower = $PackageVersion.ToLowerInvariant()
    $LeafUrl = "https://api.nuget.org/v3/registration5-gz-semver2/$IdLower/$VersionLower.json"
    $Headers = @{
        Accept = 'application/json'
    }
    $Leaf = Invoke-RestMethod -Uri $LeafUrl -Headers $Headers
    $Catalog = $Leaf.PSObject.Properties['catalogEntry']
    $Entry = if ($null -eq $Catalog) { $null } else { $Catalog.Value }
    if ($Entry -is [string]) {
        $Entry = Invoke-RestMethod -Uri $Entry -Headers $Headers
    }

    $Algorithm = ''
    $Published = ''
    if ($null -ne $Entry) {
        $AlgorithmProperty = $Entry.PSObject.Properties['packageHashAlgorithm']
        $HashProperty = $Entry.PSObject.Properties['packageHash']
        if ($null -ne $AlgorithmProperty) {
            $Algorithm = [string]$AlgorithmProperty.Value
        }

        if ($null -ne $HashProperty) {
            $Published = [string]$HashProperty.Value
        }
    }

    if ([string]::IsNullOrWhiteSpace($Algorithm) -or [string]::IsNullOrWhiteSpace($Published)) {
        throw "NuGet did not publish a hash for '$Id' $PackageVersion. Installation aborted."
    }

    Write-InstallLog -Message "Verifying $Id $PackageVersion $Algorithm"
    $ComputedHex = (Get-FileHash -Algorithm $Algorithm -LiteralPath $Path).Hash
    $Computed = [Convert]::ToBase64String([Convert]::FromHexString($ComputedHex))
    if (-not $Computed.Equals($Published, [System.StringComparison]::Ordinal)) {
        throw "NuGet package '$Id' $PackageVersion failed $Algorithm verification. Expected $Published but downloaded $Computed. Installation aborted."
    }
}

function Invoke-NuGetPackage {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        return (& $Action $Zip)
    } finally {
        $Zip.Dispose()
    }
}

function Read-NuspecDocument {
    param(
        [Parameter(Mandatory)]
        $Zip
    )

    $Entry = $Zip.Entries | Where-Object { $_.FullName -like '*.nuspec' -and ($_.FullName -notmatch '[\\/]') } | Select-Object -First 1
    if ($null -eq $Entry) {
        throw 'NuGet package does not contain a nuspec.'
    }

    $Stream = $Entry.Open()
    try {
        $Reader = [System.IO.StreamReader]::new($Stream, [System.Text.Encoding]::UTF8, $true, 1024, $true)
        try {
            $Content = $Reader.ReadToEnd()
        } finally {
            $Reader.Dispose()
        }
    } finally {
        $Stream.Dispose()
    }

    return [xml]$Content
}

function Read-PackageNuspec {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return Invoke-NuGetPackage -Path $Path -Action {
        param($Zip)
        Read-NuspecDocument -Zip $Zip
    }
}

function Get-NuspecDependencies {
    param(
        [Parameter(Mandatory)]
        [xml]$Document
    )

    $Groups = @($Document.SelectNodes("//*[local-name()='dependencies']/*[local-name()='group']"))
    if ($Groups.Count -eq 0) {
        return @($Document.SelectNodes("//*[local-name()='dependencies']/*[local-name()='dependency']"))
    }

    $ByFramework = @{}
    foreach ($Group in $Groups) {
        $Framework = ConvertTo-NuGetTfm -Name $Group.GetAttribute('targetFramework')
        if (-not $ByFramework.ContainsKey($Framework)) {
            $ByFramework[$Framework] = $Group
        }
    }

    $Framework = Select-PreferredFramework -Names @($ByFramework.Keys)
    if ($null -eq $Framework) {
        return @()
    }

    return @($ByFramework[$Framework].SelectNodes("*[local-name()='dependency']"))
}

function Get-PackageIdentity {
    param(
        [Parameter(Mandatory)]
        [xml]$Document,

        [Parameter(Mandatory)]
        [string]$FallbackId
    )

    $Node = $Document.SelectSingleNode("//*[local-name()='metadata']/*[local-name()='id']")
    if ($null -eq $Node -or [string]::IsNullOrWhiteSpace($Node.InnerText)) {
        return $FallbackId
    }

    return $Node.InnerText.Trim()
}

function Test-RelevantDependency {
    param(
        [AllowEmptyString()]
        [string]$Id,

        [AllowEmptyString()]
        [string]$Range
    )

    if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Range)) {
        return $false
    }

    # NuGet RID packages for other operating systems are declared beside the Windows assets.
    if ($Id -match '^runtime\.' -and $Id -notmatch '^runtime\.(win-x64|win|native)\.') {
        return $false
    }

    return $true
}

function Copy-ZipEntryToFile {
    param(
        [Parameter(Mandatory)]
        $Entry,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $Directory = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory | Out-Null
    }

    $Source = $Entry.Open()
    try {
        $Target = [System.IO.File]::Create($Destination)
        try {
            $Source.CopyTo($Target)
        } finally {
            $Target.Dispose()
        }
    } finally {
        $Source.Dispose()
    }
}

function Copy-PackageAssemblies {
    param(
        [Parameter(Mandatory)]
        $Zip,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $Copied = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $Entries = [System.Collections.Generic.List[object]]::new()
    $Selected = Get-PreferredAssemblyPrefix -Zip $Zip
    $Framework = if ($null -eq $Selected) { $null } else { $Selected.Framework }
    if ($null -ne $Selected) {
        foreach ($Entry in $Zip.Entries) {
            $Name = $Entry.FullName.Replace('\', '/')
            $IsDirectDll = $Name.StartsWith($Selected.Prefix, [System.StringComparison]::OrdinalIgnoreCase) -and
                $Name.EndsWith('.dll', [System.StringComparison]::OrdinalIgnoreCase) -and
                -not $Name.Substring($Selected.Prefix.Length).Contains('/')
            if ($IsDirectDll) {
                $Entries.Add($Entry)
            }
        }
    }

    foreach ($Entry in $Zip.Entries) {
        $Name = $Entry.FullName.Replace('\', '/')
        if ($Name -match '^runtimes/win-x64/native/.+\.dll$') {
            $Entries.Add($Entry)
        }
    }

    foreach ($Entry in $Entries) {
        $FileName = [System.IO.Path]::GetFileName($Entry.FullName)
        Copy-ZipEntryToFile -Entry $Entry -Destination (Join-Path $Destination $FileName)
        [void]$Copied.Add($FileName)
    }

    return [pscustomobject]@{
        Count     = $Copied.Count
        Framework = $Framework
    }
}

function Resolve-SensorPackages {
    param(
        [Parameter(Mandatory)]
        [string]$CacheDirectory
    )

    Write-InstallLog -Message 'Resolving NuGet packages'
    $ResolvedVersion = Resolve-LibreHardwareMonitorVersion -CacheDirectory $CacheDirectory

    $Selected = @{}
    $Pending = [System.Collections.Generic.Queue[object]]::new()
    $Pending.Enqueue([pscustomobject]@{
        Id      = $PackageId
        Version = $ResolvedVersion
    })

    while ($Pending.Count -gt 0) {
        $Item = $Pending.Dequeue()
        $Key = $Item.Id.ToLowerInvariant()
        if ($Selected.ContainsKey($Key) -and ((Compare-NuGetVersion -Left $Item.Version -Right $Selected[$Key].Version) -le 0)) {
            continue
        }

        $Nupkg = Get-NuGetPackagePath -Id $Item.Id -PackageVersion $Item.Version -CacheDirectory $CacheDirectory
        $Document = Read-PackageNuspec -Path $Nupkg
        $Selected[$Key] = [pscustomobject]@{
            Id      = (Get-PackageIdentity -Document $Document -FallbackId $Item.Id)
            Version = $Item.Version
            Nupkg   = $Nupkg
        }

        foreach ($Dependency in @(Get-NuspecDependencies -Document $Document)) {
            $DependencyId = $Dependency.GetAttribute('id')
            $DependencyRange = $Dependency.GetAttribute('version')
            if (-not (Test-RelevantDependency -Id $DependencyId -Range $DependencyRange)) {
                continue
            }

            $Pending.Enqueue([pscustomobject]@{
                Id      = $DependencyId.Trim()
                Version = (Get-DeclaredPackageVersion -Range $DependencyRange)
            })
        }
    }

    return [pscustomobject]@{
        Version  = $ResolvedVersion
        Packages = @($Selected.Values)
    }
}

function Clear-LhmDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
        return
    }

    $ReplaceFailed = $false
    foreach ($Item in @(Get-ChildItem -LiteralPath $Path -Force)) {
        try {
            Remove-Item -LiteralPath $Item.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            $ReplaceFailed = $true
            break
        }
    }

    if (-not $ReplaceFailed) {
        return
    }

    # A loaded DLL can be renamed with its directory, and cannot be deleted until that process exits.
    $Backup = Join-Path ([System.IO.Path]::GetTempPath()) ('lhm-replaced-' + [guid]::NewGuid().ToString('n'))
    try {
        [System.IO.Directory]::Move($Path, $Backup)
    } catch {
        throw "Unable to replace '$Path'. Stop Watch-Sensors.ps1 and retry."
    }

    New-Item -ItemType Directory -Path $Path | Out-Null
    try {
        Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction Stop
    } catch {
        Write-InstallLog -Message "Previous lhm directory left at '$Backup' because a file is still loaded." -Level Warning
    }
}

function Install-SensorPackages {
    param(
        [Parameter(Mandatory)]
        $Packages,

        [Parameter(Mandatory)]
        [string]$ResolvedVersion,

        [Parameter(Mandatory)]
        [string]$LibDirectory
    )

    Clear-LhmDirectory -Path $LibDirectory
    Write-InstallLog -Message 'Extracting DLLs to lhm'

    $ManifestPackages = [System.Collections.Generic.List[object]]::new()
    $InstalledFramework = ''
    foreach ($Package in ($Packages | Sort-Object Id)) {
        $Extracted = Invoke-NuGetPackage -Path $Package.Nupkg -Action {
            param($Zip)
            Copy-PackageAssemblies -Zip $Zip -Destination $LibDirectory
        }
        $CopiedCount = $Extracted.Count
        $PackageFramework = [string]$Extracted.Framework
        if ($Package.Id.Equals($PackageId, [System.StringComparison]::OrdinalIgnoreCase)) {
            $InstalledFramework = $PackageFramework
        }

        $FrameworkText = if ([string]::IsNullOrWhiteSpace($PackageFramework)) { 'no target framework' } else { $PackageFramework }
        Write-InstallLog -Message "Extracted $($Package.Id) $($Package.Version) $FrameworkText ($CopiedCount)" -Level Success
        $ManifestPackages.Add([pscustomobject]@{
            id      = $Package.Id
            version = $Package.Version
        })
    }

    $LibraryPath = Join-Path $LibDirectory 'LibreHardwareMonitorLib.dll'
    if (-not (Test-Path -LiteralPath $LibraryPath)) {
        throw "LibreHardwareMonitorLib.dll was not found after install at: $LibraryPath"
    }

    if ([string]::IsNullOrWhiteSpace($InstalledFramework)) {
        throw 'LibreHardwareMonitorLib did not select a supported target framework.'
    }

    $Manifest = [pscustomobject]@{
        id              = $PackageId
        version         = $ResolvedVersion
        targetFramework = $InstalledFramework
        packages        = @($ManifestPackages)
    }
    $ManifestPath = Join-Path $LibDirectory 'install-manifest.json'
    $Json = $Manifest | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($ManifestPath, $Json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Write-InstallLog -Message 'DLLs extracted to lhm' -Level Success
}

#endregion

#region PawnIO

function Get-InstalledPawnIoVersion {
    $Keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO'
    )

    foreach ($Key in $Keys) {
        $Item = Get-ItemProperty -Path $Key -ErrorAction SilentlyContinue
        if ($null -ne $Item -and -not [string]::IsNullOrWhiteSpace([string]$Item.DisplayVersion)) {
            return ([string]$Item.DisplayVersion).Trim()
        }
    }

    return ''
}

function Get-LatestPawnIoRelease {
    $Release = Invoke-RestMethod -Uri $PawnIoReleasesUrl -Headers @{
        'User-Agent' = 'Monitoring'
        Accept       = 'application/vnd.github+json'
    }

    $Tag = ([string]$Release.tag_name).Trim().TrimStart('v')
    $Asset = @($Release.assets | Where-Object { $_.name -eq 'PawnIO_setup.exe' } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($Tag) -or $Asset.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$Asset[0].browser_download_url)) {
        throw 'The latest PawnIO release does not include PawnIO_setup.exe.'
    }

    $DigestProperty = $Asset[0].PSObject.Properties['digest']
    $Digest = if ($null -eq $DigestProperty) { '' } else { [string]$DigestProperty.Value }
    $Sha256 = ''
    if ($Digest.StartsWith('sha256:', [System.StringComparison]::OrdinalIgnoreCase)) {
        $Sha256 = $Digest.Substring(7).Trim()
    }

    return [pscustomobject]@{
        Version = $Tag
        Url     = [string]$Asset[0].browser_download_url
        Sha256  = $Sha256
    }
}

function Install-PawnIo {
    param(
        [Parameter(Mandatory)]
        [string]$CacheDirectory
    )

    $InstalledVersion = Get-InstalledPawnIoVersion
    try {
        $Latest = Get-LatestPawnIoRelease
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($InstalledVersion)) {
            Write-InstallLog -Message "PawnIO $InstalledVersion is already installed. The latest release could not be checked." -Level Warning
            return
        }

        throw
    }

    if (-not [string]::IsNullOrWhiteSpace($InstalledVersion) -and (Compare-NuGetVersion -Left $InstalledVersion -Right $Latest.Version) -ge 0) {
        Write-InstallLog -Message "PawnIO $InstalledVersion is already installed." -Level Success
        return
    }

    if ([string]::IsNullOrWhiteSpace($Latest.Sha256)) {
        throw 'The latest PawnIO release does not publish a SHA-256 digest. Installation aborted.'
    }

    $SetupPath = Join-Path $CacheDirectory 'PawnIO_setup.exe'
    Write-InstallLog -Message "Downloading PawnIO $($Latest.Version)"
    Save-WebFile -Url $Latest.Url -Destination $SetupPath

    Write-InstallLog -Message 'Verifying PawnIO SHA-256'
    $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SetupPath).Hash
    if (-not $ActualHash.Equals($Latest.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "PawnIO $($Latest.Version) failed SHA-256 verification. Expected $($Latest.Sha256) but downloaded $ActualHash. Installation aborted."
    }

    Write-InstallLog -Message "Installing PawnIO $($Latest.Version)"
    $Process = Start-Process -FilePath $SetupPath -ArgumentList '-install', '-silent' -Wait -PassThru
    if ($Process.ExitCode -ne 0) {
        throw "PawnIO setup failed with exit code $($Process.ExitCode)."
    }

    $InstalledVersion = Get-InstalledPawnIoVersion
    if ([string]::IsNullOrWhiteSpace($InstalledVersion)) {
        throw 'PawnIO setup finished, but the driver is not registered.'
    }

    Write-InstallLog -Message "PawnIO $InstalledVersion installed." -Level Success
}

#endregion

#region Services

function Test-NssmService {
    param(
        [Parameter(Mandatory)]
        [string]$NssmPath,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $null = & $NssmPath status $Name 2>&1
    return $LASTEXITCODE -eq 0
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
    $Service = Wait-ServiceState -Name $Name -State 'Stopped' -TimeoutSeconds 20

    if ($null -ne $Service -and $Service.State -ne 'Stopped' -and $ProcessId -gt 0) {
        Write-InstallLog -Message "Stopping process $ProcessId." -Level Warning
        Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$ProcessId" | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }

        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        $Service = Wait-ServiceState -Name $Name -State 'Stopped' -TimeoutSeconds 15
    }

    if ($null -ne $Service -and $Service.State -ne 'Stopped') {
        throw "Service $Name did not stop."
    }
}

function Install-SensorService {
    $NssmPath = Get-NssmPath
    $Root = Get-SensorsDirectory
    $Pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    $WatchScript = Join-Path $Root 'Watch-Sensors.ps1'
    $LogDirectory = Join-Path (Get-ScriptRootPath) 'runtime\logs'
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory | Out-Null
    }

    $LogPath = Join-Path $LogDirectory 'watch-sensors.log'

    if (-not (Test-Path -LiteralPath $Pwsh)) {
        throw "pwsh.exe was not found at: $Pwsh"
    }

    if (-not (Test-Path -LiteralPath $WatchScript)) {
        throw "Watch-Sensors.ps1 was not found at: $WatchScript"
    }

    $Service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$SensorServiceName'"
    if ($null -eq $Service) {
        Write-InstallLog -Message "Creating service $SensorServiceName"
        Invoke-Nssm -NssmPath $NssmPath -ArgumentList @('install', $SensorServiceName, $Pwsh)
    } else {
        Write-InstallLog -Message "Service $SensorServiceName already exists. Updating configuration."
        if ($Service.State -ne 'Stopped') {
            Write-InstallLog -Message "Stopping $SensorServiceName service"
            Stop-HostService -Name $SensorServiceName
        }
    }

    $Parameters = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $WatchScript
    Set-NssmServiceConfiguration `
        -NssmPath $NssmPath `
        -Name $SensorServiceName `
        -Application $Pwsh `
        -AppParameters $Parameters `
        -AppDirectory (Get-SensorsDirectory) `
        -DisplayName $SensorServiceDisplayName `
        -LogPath $LogPath
    Invoke-Nssm -NssmPath $NssmPath -ArgumentList @('set', $SensorServiceName, 'AppStdoutCreationDisposition', '4')
    Invoke-Nssm -NssmPath $NssmPath -ArgumentList @('set', $SensorServiceName, 'AppStderrCreationDisposition', '4')
    Start-NssmService -NssmPath $NssmPath -Name $SensorServiceName
}

function Start-NssmService {
    param(
        [Parameter(Mandatory)]
        [string]$NssmPath,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $Service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'"
    if ($null -ne $Service -and $Service.State -eq 'Running') {
        Write-InstallLog -Message "Service $Name is already running." -Level Success
        return
    }

    Write-InstallLog -Message "Starting service $Name"
    $Output = & $NssmPath start $Name 2>&1
    $Service = Wait-ServiceState -Name $Name -State 'Running' -TimeoutSeconds 30
    if ($null -eq $Service -or $Service.State -ne 'Running') {
        $Detail = ($Output | Out-String).Trim()
        $State = if ($null -eq $Service) { 'missing' } else { $Service.State }
        throw "Service $Name did not reach SERVICE_RUNNING. Last status: $State. $Detail"
    }

    Write-InstallLog -Message "Service $Name is running." -Level Success
}

#endregion

#region Install

function Install-RuntimeBinaries {
    param(
        [Parameter(Mandatory)]
        [string]$CacheDirectory,

        [Parameter(Mandatory)]
        [string]$RuntimeDirectory
    )

    $NssmZip = Join-Path $CacheDirectory "nssm-$NssmVersion.zip"
    Write-InstallLog -Message "Downloading NSSM $NssmVersion"
    Save-WebFile -Url $NssmDownloadUrl -Destination $NssmZip -FailureMessage "NSSM $NssmVersion was not found at $NssmDownloadUrl."
    Write-InstallLog -Message 'Verifying NSSM SHA-256'
    Assert-FileHash -Path $NssmZip -Algorithm SHA256 -Expected $NssmSha256
    $NssmPath = Join-Path $RuntimeDirectory 'nssm\nssm.exe'
    Expand-ZipEntry -ZipPath $NssmZip -EntrySuffix $NssmEntryName -Destination $NssmPath
    Write-InstallLog -Message "nssm.exe extracted to $NssmPath" -Level Success

    $TelegrafZip = Join-Path $CacheDirectory "telegraf-$TelegrafVersion.zip"
    Write-InstallLog -Message "Downloading Telegraf $TelegrafVersion"
    Save-WebFile -Url $TelegrafDownloadUrl -Destination $TelegrafZip -FailureMessage "Telegraf $TelegrafVersion was not found at $TelegrafDownloadUrl."
    Write-InstallLog -Message 'Verifying Telegraf SHA-256'
    Assert-FileHash -Path $TelegrafZip -Algorithm SHA256 -Expected $TelegrafSha256
    $TelegrafPath = Join-Path $RuntimeDirectory 'telegraf\telegraf.exe'
    Expand-ZipEntry -ZipPath $TelegrafZip -EntrySuffix 'telegraf.exe' -Destination $TelegrafPath
    Write-InstallLog -Message "telegraf.exe extracted to $TelegrafPath" -Level Success
}

function Install-TelegrafService {
    param(
        [Parameter(Mandatory)]
        [string]$NssmPath,

        [Parameter(Mandatory)]
        [string]$TelegrafPath,

        [Parameter(Mandatory)]
        [string]$LogPath
    )

    $Pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    $StartScript = Join-Path (Get-ScriptRootPath) 'telegraf\Start-Telegraf.ps1'
    $EnvFile = Join-Path (Get-ScriptRootPath) '.env'
    if (-not (Test-Path -LiteralPath $Pwsh)) {
        throw "pwsh.exe was not found at: $Pwsh"
    }

    if (-not (Test-Path -LiteralPath $StartScript)) {
        throw "Start-Telegraf.ps1 was not found at: $StartScript"
    }

    if (-not (Test-Path -LiteralPath $TelegrafPath)) {
        throw "telegraf.exe was not found at: $TelegrafPath"
    }

    if (-not (Test-Path -LiteralPath $EnvFile)) {
        throw ".env was not found at: $EnvFile"
    }

    $ExistingApplication = Get-InstalledApplication -NssmPath $NssmPath
    $Service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'"
    if ($null -ne $Service -and $ExistingApplication -and ($ExistingApplication -ne $Pwsh)) {
        throw "Service $ServiceName already exists and points at '$ExistingApplication'. Installer left it unchanged."
    }

    if ($null -ne $Service -and $Service.State -ne 'Stopped') {
        Write-InstallLog -Message "Stopping $ServiceName service"
        Stop-HostService -Name $ServiceName
    }

    if ($null -eq $Service) {
        Write-InstallLog -Message "Creating service $ServiceName"
        Invoke-Nssm -NssmPath $NssmPath -ArgumentList @('install', $ServiceName, $Pwsh)
    } else {
        Write-InstallLog -Message "Service $ServiceName already exists. Updating configuration."
    }

    $Parameters = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $StartScript
    Set-NssmServiceConfiguration `
        -NssmPath $NssmPath `
        -Name $ServiceName `
        -Application $Pwsh `
        -AppParameters $Parameters `
        -AppDirectory (Get-ScriptRootPath) `
        -DisplayName $ServiceDisplayName `
        -LogPath $LogPath
    Invoke-Nssm -NssmPath $NssmPath -ArgumentList @('set', $ServiceName, 'DependOnService', $SensorServiceName)
    Start-NssmService -NssmPath $NssmPath -Name $ServiceName
}

function Invoke-Main {
    Write-InstallLog -Message 'Starting installer'
    Assert-Administrator

    $Root = Get-ScriptRootPath
    $RuntimeDirectory = Join-Path $Root 'runtime'
    $CacheDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('telegraf-install-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $CacheDirectory | Out-Null

    try {
        foreach ($Name in @($ServiceName, $SensorServiceName)) {
            $Existing = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'"
            if ($null -ne $Existing -and $Existing.State -ne 'Stopped') {
                Write-InstallLog -Message "Stopping $Name service"
                Stop-HostService -Name $Name
            }
        }

        Install-RuntimeBinaries -CacheDirectory $CacheDirectory -RuntimeDirectory $RuntimeDirectory

        $LogDirectory = Join-Path $RuntimeDirectory 'logs'
        if (-not (Test-Path -LiteralPath $LogDirectory)) {
            New-Item -ItemType Directory -Path $LogDirectory | Out-Null
        }

        $NssmPath = Join-Path $RuntimeDirectory 'nssm\nssm.exe'
        $Resolved = Resolve-SensorPackages -CacheDirectory $CacheDirectory
        Install-SensorPackages -Packages $Resolved.Packages -ResolvedVersion $Resolved.Version -LibDirectory (Join-Path $RuntimeDirectory 'lhm')
        Install-PawnIo -CacheDirectory $CacheDirectory
        Install-SensorService

        Install-TelegrafService `
            -NssmPath $NssmPath `
            -TelegrafPath (Join-Path $RuntimeDirectory 'telegraf\telegraf.exe') `
            -LogPath (Join-Path $LogDirectory 'telegraf-service.log')

        Write-InstallLog -Message 'Installation complete.' -Level Success
    } finally {
        if (Test-Path -LiteralPath $CacheDirectory) {
            Remove-Item -LiteralPath $CacheDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}
