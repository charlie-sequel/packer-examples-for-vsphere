# © Broadcom. All Rights Reserved.
# The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-2-Clause

<#
    .SYNOPSIS
    Desktop and account configuration for the SDS client connector image.

    .DESCRIPTION
    Applies the things an operator expects to find on first logon, none of which belong in the
    Horizon golden image:

      - a local operator account
      - dark mode
      - Copilot and the Store removed from the taskbar
      - the operator's tools pinned to the taskbar

    Everything that is a per-user setting is written to the DEFAULT USER profile rather than to the
    account running the build. A golden image builds as the build account; settings written to its
    profile vanish with it and are never seen by anyone who logs in later. Writing them to the
    default profile means every account created afterwards -- including the operator account below
    and any created after deployment -- inherits them.

    .PARAMETER OperatorUsername
    Local account to create. Skipped when it already exists.

    .PARAMETER OperatorPassword
    Password for that account. Prefer the SDS_OPERATOR_PASSWORD environment variable: anything on
    the command line is visible in the guest's process list.

    .PARAMETER TaskbarPins
    Display names of applications to pin, in order. Each is matched against Start Menu shortcuts,
    so a pin follows the application wherever it installed itself rather than depending on a
    hard-coded path.

    .NOTES
    Intended to run from a Packer provisioner, after the applications are installed.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OperatorUsername,
    [string]$OperatorPassword,
    [string]$OperatorFullName = 'SDS Operator',

    [string[]]$TaskbarPins = @(
        'Notepad++',
        'Remote Desktop Manager',
        '1Password',
        'FortiClient',
        'GlobalProtect',
        'Cisco Secure Client'
    ),

    [switch]$DarkMode,
    [string]$LogPath = 'C:\Windows\Temp\sds-desktop'
)

$ErrorActionPreference = 'Stop'

foreach ($map in @(
        @{ P = 'OperatorUsername'; E = 'SDS_OPERATOR_USERNAME' }
        @{ P = 'OperatorPassword'; E = 'SDS_OPERATOR_PASSWORD' }
        @{ P = 'OperatorFullName'; E = 'SDS_OPERATOR_FULLNAME' }
    )) {
    if ($PSBoundParameters.ContainsKey($map.P)) { continue }
    $value = [Environment]::GetEnvironmentVariable($map.E)
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    Set-Variable -Name $map.P -Value $value
}
if (-not $PSBoundParameters.ContainsKey('DarkMode') -and $env:SDS_DARK_MODE -in @('1', 'true', 'True')) {
    $DarkMode = [switch]$true
}
if (-not $PSBoundParameters.ContainsKey('TaskbarPins') -and $env:SDS_TASKBAR_PINS) {
    $TaskbarPins = $env:SDS_TASKBAR_PINS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

function Write-Step {
    param([string]$Message, [ValidateSet('OK', 'FAIL', 'WARN', 'SKIP', 'RUN', 'Info')][string]$Status = 'Info')
    $prefix = switch ($Status) {
        'OK'   { '[OK]   ' }
        'FAIL' { '[FAIL] ' }
        'WARN' { '[WARN] ' }
        'SKIP' { '[SKIP] ' }
        'RUN'  { '[RUN]  ' }
        'Info' { '[----] ' }
    }
    Write-Host "  $prefix $Message"
}

Write-Host ''
Write-Host '  SDS Desktop Configuration'
Write-Host ''
if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }

#region Operator account

if ($OperatorUsername) {
    if (Get-LocalUser -Name $OperatorUsername -ErrorAction SilentlyContinue) {
        Write-Step "Local account '$OperatorUsername' already exists." -Status SKIP
    }
    elseif (-not $OperatorPassword) {
        Write-Step "No password supplied for '$OperatorUsername'; not creating it." -Status WARN
    }
    else {
        try {
            $secure = ConvertTo-SecureString $OperatorPassword -AsPlainText -Force
            New-LocalUser -Name $OperatorUsername -Password $secure -FullName $OperatorFullName `
                -Description 'SDS operator account' -PasswordNeverExpires -AccountNeverExpires | Out-Null
            # Local Administrators by SID, not by name: the group is localised and 'Administrators'
            # does not exist on a non-English image.
            $administrators = (Get-LocalGroup -SID 'S-1-5-32-544').Name
            Add-LocalGroupMember -Group $administrators -Member $OperatorUsername -ErrorAction Stop
            Write-Step "Created '$OperatorUsername' and added it to $administrators." -Status OK
        }
        catch {
            Write-Step "Could not create '$OperatorUsername': $($_.Exception.Message)" -Status FAIL
            throw
        }
    }
}

#endregion
#region Default user profile

# Per-user settings are applied by loading the default profile's hive and writing into it, so that
# accounts created later inherit them. HKU\SDSDEFAULT is a scratch mount point, unloaded below.
$defaultHive = 'C:\Users\Default\NTUSER.DAT'
$mount = 'SDSDEFAULT'
$loaded = $false

try {
    if (Test-Path $defaultHive) {
        & reg.exe load "HKU\$mount" $defaultHive 2>&1 | Out-Null
        $loaded = ($LASTEXITCODE -eq 0)
        $global:LASTEXITCODE = 0
    }
    if (-not $loaded) {
        Write-Step 'Could not load the default user hive; per-user settings apply to this account only.' -Status WARN
    }

    # Each target: the default profile (for future accounts) and the current one (so the image
    # itself looks right if someone consoles in before deployment).
    $userRoots = @()
    if ($loaded) { $userRoots += "Registry::HKEY_USERS\$mount" }
    $userRoots += 'HKCU:'

    foreach ($root in $userRoots) {
        if ($DarkMode) {
            $personalize = "$root\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
            if (-not (Test-Path $personalize)) { New-Item -Path $personalize -Force | Out-Null }
            Set-ItemProperty -Path $personalize -Name 'AppsUseLightTheme'   -Value 0 -Type DWord -Force
            Set-ItemProperty -Path $personalize -Name 'SystemUsesLightTheme' -Value 0 -Type DWord -Force
        }

        # Copilot and the Store: hide the buttons. The Copilot and Store packages themselves are
        # removed elsewhere in the build; this is the taskbar chrome.
        $advanced = "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        if (-not (Test-Path $advanced)) { New-Item -Path $advanced -Force | Out-Null }
        Set-ItemProperty -Path $advanced -Name 'ShowCopilotButton' -Value 0 -Type DWord -Force
        # Search box down to an icon, and widgets off: both are noise on an operator desktop.
        Set-ItemProperty -Path $advanced -Name 'TaskbarDa' -Value 0 -Type DWord -Force
    }
    if ($DarkMode) { Write-Step 'Dark mode set for the default profile and this account.' -Status OK }
    Write-Step 'Copilot button and widgets hidden.' -Status OK
}
finally {
    if ($loaded) {
        [gc]::Collect()
        Start-Sleep -Seconds 2
        & reg.exe unload "HKU\$mount" 2>&1 | Out-Null
        $global:LASTEXITCODE = 0
    }
}

# Machine-wide Copilot policy, which is what actually keeps it from coming back.
$copilotPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'
if (-not (Test-Path $copilotPolicy)) { New-Item -Path $copilotPolicy -Force | Out-Null }
Set-ItemProperty -Path $copilotPolicy -Name 'TurnOffWindowsCopilot' -Value 1 -Type DWord -Force

#endregion
#region Taskbar pins

# Pins are resolved by searching the Start Menu for each application's shortcut rather than by
# hard-coding paths: installers move between %ProgramFiles% and per-user locations between
# versions, and a pin to a path that does not exist is silently dropped by Explorer.
$startMenus = @(
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
) | Where-Object { Test-Path $_ }

$shortcuts = @()
foreach ($menu in $startMenus) {
    $shortcuts += Get-ChildItem -Path $menu -Filter '*.lnk' -Recurse -File -ErrorAction SilentlyContinue
}

$resolved = @()
foreach ($pin in $TaskbarPins) {
    $match = $shortcuts | Where-Object { $_.BaseName -like "*$pin*" } |
        Sort-Object { $_.BaseName.Length } | Select-Object -First 1
    if ($match) {
        Write-Step "pin: $pin -> $($match.FullName)" -Status OK
        $resolved += $match.FullName
    }
    else {
        Write-Step "pin: $pin -- no Start Menu shortcut found, skipping" -Status WARN
    }
}

if ($resolved.Count -gt 0) {
    $entries = ($resolved | ForEach-Object {
            "        <taskbar:DesktopApp DesktopApplicationLinkPath=`"$([System.Security.SecurityElement]::Escape($_))`" />"
        }) -join "`r`n"

    # PinListPlacement="Replace" is what removes the Windows defaults, which is how Store and the
    # rest leave the taskbar -- there is no supported way to unpin an individual default.
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
$entries
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@

    # Two placements, because Windows has moved this target between releases:
    #   - the default profile's Shell folder, read when a new profile is created
    #   - a machine path referenced by the Explorer policy below
    $defaultShell = 'C:\Users\Default\AppData\Local\Microsoft\Windows\Shell'
    if (-not (Test-Path $defaultShell)) { New-Item -Path $defaultShell -ItemType Directory -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $defaultShell 'LayoutModification.xml') -Value $xml -Encoding UTF8

    $machineLayout = 'C:\Windows\SDS\TaskbarLayoutModification.xml'
    if (-not (Test-Path (Split-Path $machineLayout))) { New-Item -Path (Split-Path $machineLayout) -ItemType Directory -Force | Out-Null }
    Set-Content -LiteralPath $machineLayout -Value $xml -Encoding UTF8

    $explorerPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
    if (-not (Test-Path $explorerPolicy)) { New-Item -Path $explorerPolicy -Force | Out-Null }
    Set-ItemProperty -Path $explorerPolicy -Name 'StartLayoutFile' -Value $machineLayout -Type ExpandString -Force
    Set-ItemProperty -Path $explorerPolicy -Name 'LockedStartLayout' -Value 0 -Type DWord -Force

    Copy-Item -LiteralPath $machineLayout -Destination (Join-Path $LogPath 'TaskbarLayoutModification.xml') -Force
    Write-Step "Taskbar layout written with $($resolved.Count) pin(s)." -Status OK
}
else {
    Write-Step 'No shortcuts resolved; taskbar left at defaults.' -Status WARN
}

#endregion

Write-Host ''
Write-Host '  Done. Taskbar pins apply to profiles created after this point, which is why the'
Write-Host '  operator account is created first and the settings go to the default profile.'
Write-Host ''
