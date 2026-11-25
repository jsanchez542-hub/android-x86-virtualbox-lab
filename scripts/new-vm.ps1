<#
.SYNOPSIS
Creates the VirtualBox machine for the Android-x86 9.0-r2 tablet.

.EXAMPLE
.\new-vm.ps1 -IsoPath "$HOME\Downloads\android-x86_64-9.0-r2.iso"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $IsoPath,

    [string] $Name = 'android-x86-tablet',

    [ValidateRange(2048, 16384)]
    [int] $MemoryMB = 3072,

    [ValidateRange(1, 16)]
    [int] $Cpus = 2,

    [ValidateRange(8, 512)]
    [int] $DiskGB = 16,

    [ValidateRange(1024, 65535)]
    [int] $AdbHostPort = 5555,

    [string] $VBoxManage,

    [switch] $SkipChecksum
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ReleaseSha1 = '1cc85b5ed7c830ff71aecf8405c7281a9c995aa0'

if (-not $VBoxManage) {
    $installed = Get-Command VBoxManage -ErrorAction SilentlyContinue
    $VBoxManage = if ($installed) { $installed.Source } else { Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe' }
}
if (-not (Test-Path -LiteralPath $VBoxManage)) {
    throw "VBoxManage not found at '$VBoxManage'. Install VirtualBox 7.2 or pass -VBoxManage."
}

function Invoke-VBoxManage([string[]] $Arguments) {
    & $VBoxManage @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "VBoxManage $($Arguments -join ' ') exited with code $LASTEXITCODE."
    }
}

$iso = (Resolve-Path -LiteralPath $IsoPath).Path
if (-not $SkipChecksum) {
    $sha1 = (Get-FileHash -LiteralPath $iso -Algorithm SHA1).Hash.ToLowerInvariant()
    if ($sha1 -ne $ReleaseSha1) {
        throw "SHA-1 of '$iso' is $sha1, but the 9.0-r2 release note lists $ReleaseSha1."
    }
}

$registered = & $VBoxManage list vms
if ($registered | Where-Object { $_ -like "`"$Name`" *" }) {
    throw "A VM named '$Name' is already registered."
}

Invoke-VBoxManage @('createvm', '--name', $Name, '--ostype', 'Linux26_64', '--register')

$diskCreated = $false
$diskAttached = $false
try {
    $hardware = @(
        '--memory', $MemoryMB,
        '--cpus', $Cpus,
        '--firmware', 'bios',
        '--ioapic', 'on',
        '--rtc-use-utc', 'on',
        '--graphicscontroller', 'vboxvga',
        '--vram', 128,
        '--accelerate-3d', 'off',
        '--usb-ohci', 'on',
        '--mouse', 'usbtablet',
        '--audio-enabled', 'off',
        '--clipboard-mode', 'disabled',
        '--drag-and-drop', 'disabled',
        '--boot1', 'dvd',
        '--boot2', 'disk',
        '--boot3', 'none',
        '--boot4', 'none',
        '--nic1', 'nat',
        '--nat-pf1', "adb,tcp,127.0.0.1,$AdbHostPort,,5555"
    )
    Invoke-VBoxManage (@('modifyvm', $Name) + $hardware)

    $configLine = & $VBoxManage showvminfo $Name --machinereadable | Where-Object { $_ -like 'CfgFile=*' }
    $configFile = ($configLine -replace '^CfgFile="(.*)"$', '$1') -replace '\\\\', '\'
    $disk = Join-Path (Split-Path -Parent $configFile) "$Name.vdi"

    Invoke-VBoxManage @('createmedium', 'disk', '--filename', $disk, '--size', ($DiskGB * 1024), '--format', 'VDI')
    $diskCreated = $true
    Invoke-VBoxManage @('storagectl', $Name, '--name', 'SATA', '--add', 'sata', '--controller', 'IntelAhci', '--portcount', 2)
    Invoke-VBoxManage @('storageattach', $Name, '--storagectl', 'SATA', '--port', 0, '--device', 0, '--type', 'hdd', '--medium', $disk)
    $diskAttached = $true
    Invoke-VBoxManage @('storageattach', $Name, '--storagectl', 'SATA', '--port', 1, '--device', 0, '--type', 'dvddrive', '--medium', $iso)
}
catch {
    # A half-created VM would block the next run, because the script refuses to overwrite an existing VM.
    # Only the disk created by this run is deleted, never a file that was already there. unregistervm
    # deletes the disk once it is attached; before that it has to be closed on its own.
    Write-Warning "Setup of '$Name' failed, so the VM and its new disk are being removed."
    if ($diskCreated -and -not $diskAttached) {
        & $VBoxManage closemedium disk $disk --delete
    }
    & $VBoxManage unregistervm $Name --delete
    throw
}

Write-Host ""
Write-Host "Created '$Name'. Start it with:"
Write-Host "  & `"$VBoxManage`" startvm `"$Name`""
Write-Host "When the installer finishes, eject the ISO before rebooting:"
Write-Host "  & `"$VBoxManage`" storageattach `"$Name`" --storagectl SATA --port 1 --device 0 --medium emptydrive"
