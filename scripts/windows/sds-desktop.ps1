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
        'AnyConnect',
        'RVTools'
    ),

    [switch]$DarkMode,
    [switch]$BlackBackground,
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
if (-not $PSBoundParameters.ContainsKey('BlackBackground') -and $env:SDS_BLACK_BACKGROUND -in @('1', 'true', 'True')) {
    $BlackBackground = [switch]$true
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
#region Black wallpaper

# A real image, written once to a machine path so every profile can reach it.
$script:BlackWallpaper = 'C:\Windows\Web\Wallpaper\Windows\sds-black.bmp'
if ($BlackBackground) {
    try {
        $dir = Split-Path $script:BlackWallpaper
        if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        # Built byte by byte rather than with System.Drawing: GDI+ is not guaranteed to be
        # present, and a failure there would leave the desktop on its default wallpaper. A 4x4
        # image is enough -- WallpaperStyle 2 stretches it to any resolution.
        $width = 4; $height = 4
        $rowBytes = [Math]::Ceiling($width * 3 / 4) * 4
        $pixelBytes = $rowBytes * $height
        $bytes = New-Object System.Collections.Generic.List[byte]
        $bytes.AddRange([byte[]]@(0x42, 0x4D))
        $bytes.AddRange([BitConverter]::GetBytes([int](54 + $pixelBytes)))
        $bytes.AddRange([BitConverter]::GetBytes([int]0))
        $bytes.AddRange([BitConverter]::GetBytes([int]54))
        $bytes.AddRange([BitConverter]::GetBytes([int]40))
        $bytes.AddRange([BitConverter]::GetBytes([int]$width))
        $bytes.AddRange([BitConverter]::GetBytes([int]$height))
        $bytes.AddRange([BitConverter]::GetBytes([int16]1))
        $bytes.AddRange([BitConverter]::GetBytes([int16]24))
        $bytes.AddRange([BitConverter]::GetBytes([int]0))
        $bytes.AddRange([BitConverter]::GetBytes([int]$pixelBytes))
        $bytes.AddRange([BitConverter]::GetBytes([int]2835))
        $bytes.AddRange([BitConverter]::GetBytes([int]2835))
        $bytes.AddRange([BitConverter]::GetBytes([int]0))
        $bytes.AddRange([BitConverter]::GetBytes([int]0))
        $bytes.AddRange([byte[]]::new($pixelBytes))   # all zero = black
        [IO.File]::WriteAllBytes($script:BlackWallpaper, $bytes.ToArray())
        Write-Step "Black wallpaper written to $script:BlackWallpaper" -Status OK
    }
    catch {
        Write-Step "Could not create the black wallpaper: $($_.Exception.Message)" -Status WARN
        $script:BlackWallpaper = ''
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

    # Each of these is cosmetic. Not one is worth failing a build that has already installed every
    # application -- and some values in the default hive are ACL-protected and simply refuse to be
    # written. Set them individually and report what did not take.
    function Set-UserValue {
        param([string]$Key, [string]$Name, [int]$Value)
        try {
            if (-not (Test-Path $Key)) { New-Item -Path $Key -Force | Out-Null }
            Set-ItemProperty -Path $Key -Name $Name -Value $Value -Type DWord -Force -ErrorAction Stop
            return $true
        }
        catch {
            Write-Step "could not set $Name : $($_.Exception.Message)" -Status WARN
            return $false
        }
    }

    function Set-UserString {
        param([string]$Key, [string]$Name, [string]$Value)
        try {
            if (-not (Test-Path $Key)) { New-Item -Path $Key -Force | Out-Null }
            Set-ItemProperty -Path $Key -Name $Name -Value $Value -Type String -Force -ErrorAction Stop
            return $true
        }
        catch {
            Write-Step "could not set $Name : $($_.Exception.Message)" -Status WARN
            return $false
        }
    }

    foreach ($root in $userRoots) {
        if ($DarkMode) {
            $personalize = "$root\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
            [void](Set-UserValue -Key $personalize -Name 'AppsUseLightTheme'    -Value 0)
            [void](Set-UserValue -Key $personalize -Name 'SystemUsesLightTheme' -Value 0)
        }

        # Hide the Copilot button. The Copilot package itself is removed elsewhere in the build;
        # this is the taskbar chrome.
        $advanced = "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        [void](Set-UserValue -Key $advanced -Name 'ShowCopilotButton' -Value 0)

        # Solid black desktop -- KNOWN NOT TO WORK, left in place because it is harmless.
        #
        # Neither clearing Wallpaper nor pointing it at a black bitmap survives first logon on
        # Windows 11: the theme applied at that point re-asserts its own image and wins over both.
        # The values below are set correctly and the bitmap is written; the desktop still comes up
        # with the default wallpaper.
        #
        # What would actually work, if it ever matters enough: overwrite the theme's own image at
        # C:\Windows\Web\Wallpaper\Windows\img0.jpg, or set the wallpaper POLICY value under
        # ...\Policies\System\Wallpaper, which does outrank the theme. Deliberately not done --
        # the setting is cosmetic and was not worth another hour of build cycles.
        #
        # (OSOT advertises -Background $HEX_COLOR for this, but 1.2.2603 rejects every value format
        # tried, and a rejected argument voids its ENTIRE optimize run while still exiting 0.)
        #
        if ($BlackBackground) {
            [void](Set-UserString -Key "$root\Control Panel\Desktop" -Name 'Wallpaper' -Value $script:BlackWallpaper)
            [void](Set-UserString -Key "$root\Control Panel\Desktop" -Name 'WallpaperStyle' -Value '2')
            [void](Set-UserString -Key "$root\Control Panel\Desktop" -Name 'TileWallpaper' -Value '0')
            [void](Set-UserString -Key "$root\Control Panel\Colors" -Name 'Background' -Value '0 0 0')
        }

    }
    if ($DarkMode) { Write-Step 'Dark mode set for the default profile and this account.' -Status OK }
    # The desktop background is OSOT's job -- see sds_osot_background. Setting it here as well
    # would be two mechanisms racing over the same setting.
    Write-Step 'Copilot button hidden.' -Status OK
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
try {
    $copilotPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'
    if (-not (Test-Path $copilotPolicy)) { New-Item -Path $copilotPolicy -Force | Out-Null }
    Set-ItemProperty -Path $copilotPolicy -Name 'TurnOffWindowsCopilot' -Value 1 -Type DWord -Force -ErrorAction Stop
    Write-Step 'Copilot disabled by machine policy.' -Status OK
}
catch {
    Write-Step "Could not set the Copilot policy: $($_.Exception.Message)" -Status WARN
}

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
        # No shortcut: some installers (RVTools via Chocolatey, for one) drop an executable and
        # never create one. Find the executable and make the shortcut, so the pin has a target.
        $exe = $null
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:ProgramData\chocolatey\bin")) {
            if (-not $base -or -not (Test-Path $base)) { continue }
            $exe = Get-ChildItem -Path $base -Filter "*.exe" -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -like "*$pin*" } |
                Sort-Object { $_.BaseName.Length } | Select-Object -First 1
            if ($exe) { break }
        }
        if ($exe) {
            try {
                $created = Join-Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" "$pin.lnk"
                $shell = New-Object -ComObject WScript.Shell
                $link = $shell.CreateShortcut($created)
                $link.TargetPath = $exe.FullName
                $link.WorkingDirectory = $exe.DirectoryName
                $link.Save()
                Write-Step "pin: $pin -> created $created (installer left no shortcut)" -Status OK
                $resolved += $created
            }
            catch {
                Write-Step "pin: $pin -- found $($exe.FullName) but could not create a shortcut: $($_.Exception.Message)" -Status WARN
            }
        }
        else {
            Write-Step "pin: $pin -- no Start Menu shortcut and no matching executable, skipping" -Status WARN
        }
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
