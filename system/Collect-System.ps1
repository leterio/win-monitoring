$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$OsInfoMetricTemplate = 'osinfo os_name={0},os_version={1}'
$BiosInfoMetricTemplate = 'biosinfo version={0},release_date={1}'

function Format-FieldString {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return '""'
    }

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-PropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $Property = $InputObject.PSObject.Properties[$Name]
    if (($null -eq $Property) -or ($null -eq $Property.Value)) {
        return $DefaultValue
    }

    return $Property.Value
}

function Get-OsInfoMetric {
    $Os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $CurrentVersion = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    $WindowsVersion = Get-PropertyValue -InputObject $CurrentVersion -Name 'DisplayVersion'
    if ([string]::IsNullOrWhiteSpace($WindowsVersion)) {
        $WindowsVersion = Get-PropertyValue -InputObject $CurrentVersion -Name 'ReleaseId'
    }

    $ProductName = Get-PropertyValue -InputObject $CurrentVersion -Name 'ProductName' -DefaultValue ''
    $OsName = '{0} {1}' -f $ProductName, $WindowsVersion

    $OsBaseVersion = Get-PropertyValue -InputObject $Os -Name 'Version'
    if ([string]::IsNullOrWhiteSpace($OsBaseVersion)) {
        $OsBaseVersion = Get-PropertyValue -InputObject $CurrentVersion -Name 'CurrentBuildNumber'
    }

    $UpdateBuildRevision = Get-PropertyValue -InputObject $CurrentVersion -Name 'UBR' -DefaultValue 0
    $OsVersion = '{0}.{1}' -f $OsBaseVersion, $UpdateBuildRevision

    return ($OsInfoMetricTemplate -f `
        (Format-FieldString $OsName),
        (Format-FieldString $OsVersion))
}

function Get-BiosInfoMetric {
    $Bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue

    return ($BiosInfoMetricTemplate -f `
        (Format-FieldString (Get-PropertyValue -InputObject $Bios -Name 'SMBIOSBIOSVersion')),
        (Format-FieldString (Get-PropertyValue -InputObject $Bios -Name 'ReleaseDate')))
}

$Encoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $Encoding
foreach ($Metric in @(
        (Get-OsInfoMetric),
        (Get-BiosInfoMetric)
    )) {
    [Console]::Out.WriteLine($Metric)
}
