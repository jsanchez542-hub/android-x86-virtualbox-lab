<#
.SYNOPSIS
Reads the security settings of the Android-x86 tablet over ADB. Nothing on the device is changed.

.EXAMPLE
.\audit-tablet.ps1

.EXAMPLE
.\audit-tablet.ps1 -Device 127.0.0.1:5555 -Adb "$HOME\Downloads\platform-tools\adb.exe"
#>
[CmdletBinding()]
param(
    [string] $Device = '127.0.0.1:5555',
    [string] $Adb = 'adb'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SecurityApps = [ordered]@{
    'com.paranoiaworks.unicus.android.sse' = 'SSE'
    'com.cloudflare.onedotonedotonedotone' = '1.1.1.1 + WARP'
    'com.google.android.apps.adm'          = 'Find Hub'
}

$KnownAdmins = @{
    'com.google.android.gms/.mdm.receivers.MdmDeviceAdminReceiver' = 'Find Hub'
}

$LockTypes = @{
    '65536'  = 'pattern'
    '131072' = 'PIN'
    '196608' = 'PIN'
    '262144' = 'password'
    '327680' = 'password'
    '393216' = 'password'
}

function Invoke-AdbCommand([string[]] $Arguments, [string] $InputText) {
    $ErrorActionPreference = 'Continue'
    $output = if ($InputText) { $InputText | & $Adb @Arguments 2>&1 } else { & $Adb @Arguments 2>&1 }
    (($output | ForEach-Object { "$_".TrimEnd() }) -join "`n").Trim()
}

function Invoke-Shell([string] $Command) {
    Invoke-AdbCommand @('-s', $Device, 'shell', $Command)
}

function Get-Prop([string] $Name) {
    Invoke-Shell "getprop $Name"
}

function New-Check([string] $Check, [string] $Value, [string] $Status) {
    [pscustomobject]@{ Check = $Check; Value = $Value; Status = $Status }
}

function Get-PatchCheck {
    $patch = Get-Prop 'ro.build.version.security_patch'
    try {
        $date = [datetime]::ParseExact($patch, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return New-Check 'Security patch' "unreadable ('$patch')" 'Unknown'
    }
    $age = [int]((Get-Date) - $date).TotalDays
    $status = if ($age -gt 90) { 'Risk' } else { 'OK' }
    New-Check 'Security patch' "$patch ($age days old)" $status
}

function Get-ScreenLockCheck {
    $query = "select value from locksettings where user=0 and name='lockscreen.password_type';"
    $quality = Invoke-AdbCommand @('-s', $Device, 'shell', 'su', '0', 'sqlite3', '/data/system/locksettings.db') $query
    if ($LockTypes.ContainsKey($quality)) {
        return New-Check 'Screen lock' $LockTypes[$quality] 'OK'
    }
    if ($quality -eq '0' -or $quality -eq '') {
        return New-Check 'Screen lock' 'none or swipe' 'Risk'
    }
    New-Check 'Screen lock' 'not readable without root' 'Unknown'
}

function Get-DeviceAdminCheck {
    $admins = [ordered]@{}
    $current = $null
    foreach ($line in (Invoke-Shell 'dumpsys device_policy') -split "`n") {
        if ($line -match '^\s{4}(\S+/\S+):\s*$') {
            $current = $Matches[1]
            $admins[$current] = New-Object System.Collections.Generic.List[string]
        }
        elseif ($current -and $line -match '^\s{8}([a-z][a-z-]+)\s*$' -and $Matches[1] -ne 'null') {
            $admins[$current].Add($Matches[1])
        }
        elseif ($line -match '^\S') {
            $current = $null
        }
    }
    if ($admins.Count -eq 0) {
        return New-Check 'Device admin' 'none' 'Warning'
    }
    $described = foreach ($component in $admins.Keys) {
        $label = if ($KnownAdmins.ContainsKey($component)) { $KnownAdmins[$component] } else { $component }
        "$label ($($admins[$component] -join ', '))"
    }
    $canWipe = @($admins.Values | Where-Object { $_ -contains 'wipe-data' }).Count -gt 0
    New-Check 'Device admin' ($described -join '; ') $(if ($canWipe) { 'OK' } else { 'Warning' })
}

function Get-SecurityAppsCheck {
    $found = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($package in $SecurityApps.Keys) {
        $version = [regex]::Match((Invoke-Shell "dumpsys package $package"), 'versionName=(\S+)')
        if ($version.Success) {
            $found.Add("$($SecurityApps[$package]) $($version.Groups[1].Value)")
        }
        else {
            $missing.Add($SecurityApps[$package])
        }
    }
    $value = $found -join ', '
    if ($missing.Count -gt 0) {
        $value = ($value, "missing: $($missing -join ', ')" | Where-Object { $_ }) -join '; '
        return New-Check 'Security apps' $value 'Warning'
    }
    New-Check 'Security apps' $value 'OK'
}

if (-not (Get-Command $Adb -ErrorAction SilentlyContinue)) {
    throw "adb not found. Install Android SDK Platform-Tools or pass -Adb with the path to adb.exe."
}
if ($Device -match ':\d+$') {
    $null = Invoke-AdbCommand @('connect', $Device)
}
if ((Invoke-AdbCommand @('-s', $Device, 'get-state')) -ne 'device') {
    throw "No ADB connection to $Device. Start the VM and check that ADB listens on TCP port 5555."
}

$buildType = Get-Prop 'ro.build.type'
$buildTags = Get-Prop 'ro.build.tags'
$cryptoState = Get-Prop 'ro.crypto.state'
$selinux = Invoke-Shell 'getenforce'
$adbSecure = Get-Prop 'ro.adb.secure'
$adbPort = Get-Prop 'persist.adb.tcp.port'
if (-not $adbPort) { $adbPort = Get-Prop 'service.adb.tcp.port' }
$suPaths = @('/system/bin/su', '/system/xbin/su') | Where-Object { (Invoke-Shell "ls $_ 2>/dev/null") -eq $_ }
$timeoutMs = Invoke-Shell 'settings get system screen_off_timeout'
$privateNotifications = Invoke-Shell 'settings get secure lock_screen_allow_private_notifications'
$locationProviders = Invoke-Shell 'settings get secure location_providers_allowed'
$tunnel = [regex]::Match((Invoke-Shell 'ip -4 addr show tun0 2>/dev/null'), 'inet (\S+)')
$size = (Invoke-Shell 'wm size') -replace '.*:\s*', ''
$density = (Invoke-Shell 'wm density') -replace '.*:\s*', ''

New-Check 'Device' "$(Get-Prop 'ro.product.manufacturer') $(Get-Prop 'ro.product.model'), $size at $density dpi" 'Info'
New-Check 'Android version' "$(Get-Prop 'ro.build.version.release') (API $(Get-Prop 'ro.build.version.sdk'))" 'Info'
New-Check 'Build' "$buildType, $buildTags" $(if ($buildType -eq 'user' -and $buildTags -eq 'release-keys') { 'OK' } else { 'Risk' })
Get-PatchCheck
New-Check 'Kernel' (Invoke-Shell 'uname -r') 'Info'
New-Check 'SELinux' $selinux $(if ($selinux -eq 'Enforcing') { 'OK' } else { 'Risk' })
New-Check 'Storage encryption' $(if ($cryptoState) { $cryptoState } else { 'not reported' }) $(if ($cryptoState -eq 'encrypted') { 'OK' } else { 'Risk' })
New-Check 'Root shell' $(if ($suPaths) { "su at $($suPaths -join ', ')" } else { 'no su binary' }) $(if ($suPaths) { 'Risk' } else { 'OK' })
New-Check 'ADB authorization' $(if ($adbSecure -eq '1') { 'required' } else { 'not required' }) $(if ($adbSecure -eq '1') { 'OK' } else { 'Risk' })
New-Check 'ADB over TCP' $(if ($adbPort) { "port $adbPort" } else { 'off' }) $(if ($adbPort) { 'Warning' } else { 'OK' })
Get-ScreenLockCheck
if ($timeoutMs -match '^\d+$') {
    New-Check 'Screen timeout' "$([int]$timeoutMs / 1000) s" $(if ([int]$timeoutMs -le 300000) { 'OK' } else { 'Warning' })
}
else {
    New-Check 'Screen timeout' $timeoutMs 'Unknown'
}
New-Check 'Lock screen notifications' $(if ($privateNotifications -eq '0') { 'sensitive content hidden' } else { 'full content shown' }) $(if ($privateNotifications -eq '0') { 'OK' } else { 'Warning' })
New-Check 'Location' $(if ($locationProviders) { "on ($locationProviders)" } else { 'off' }) $(if ($locationProviders) { 'OK' } else { 'Warning' })
Get-DeviceAdminCheck
New-Check 'VPN tunnel' $(if ($tunnel.Success) { "tun0 $($tunnel.Groups[1].Value)" } else { 'no tun0 interface' }) $(if ($tunnel.Success) { 'OK' } else { 'Warning' })
Get-SecurityAppsCheck
