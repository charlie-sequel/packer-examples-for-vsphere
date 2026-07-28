# © Broadcom. All Rights Reserved.
# The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-2-Clause

<#
    .SYNOPSIS
    Installs a list of applications onto a Windows image during a Packer build.

    .DESCRIPTION
    Resolves an installer source (SMB share, NFS export, or a mounted vSphere datastore ISO),
    locates each installer by filename pattern rather than by exact version, copies it to local
    disk, and installs it silently with the arguments supplied for that application.

    The application list is data, not code: it arrives as JSON in the SDS_APPLICATIONS environment
    variable and is defined in config/sds.pkrvars.hcl. Adding an application to an image is a
    configuration change, never a change to this script.

    Each entry supports:

      name      Display name, used in logs and the summary.
      pattern   Filename pattern matched against the source tree. Highest file version wins.
      type      'msi' or 'exe'. An msi is handed to msiexec; an exe is run directly.
      args      Silent-install arguments. For msi, appended to /i "<path>" /qn.
      detect    Optional. Skip the install when it is already satisfied:
                  a path            -> skipped when the path exists
                  svc:<name>        -> skipped when that service exists
                  reg:<path>        -> skipped when that registry key exists
      required  Optional. When true, a missing installer fails the build instead of warning.

    Order is preserved: applications install in the order they are listed.

    This script is non-interactive by design. It never prompts and never reboots; exit code 3010
    (reboot required) and 1641 (reboot initiated) are both treated as success, and Packer performs
    the restart between provisioners.

    .PARAMETER StageOsotOnly
    Copy the OS Optimization Tool from the installer source and do nothing else. OSOT has to be on
    the guest before the optimization provisioner runs, and it lives on the same share as the
    application installers, so the source-resolution code here is reused rather than duplicated.

    .NOTES
    Intended to run over WinRM from a Packer provisioner.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Smb', 'Nfs', 'Datastore')]
    [string]$SourceType = 'Auto',

    [string]$SourcePath,
    [string]$SourceUsername,
    [string]$SourcePassword,

    # Identity the Windows NFS client presents to the server. It mounts with -o anon, and its
    # default anonymous UID is -2 (4294967294) -- not the Linux nobody (65534). An export whose
    # files are owned by a specific UID rejects that, and the mount then succeeds while the tree
    # reads as access denied.
    [string]$AnonymousUid,
    [string]$AnonymousGid,

    # JSON array of application definitions. See the .DESCRIPTION above for the shape.
    [string]$ApplicationsJson,

    [switch]$StageOsotOnly,
    [string]$OsotPattern = '*OSOptimizationTool*.exe',
    [string]$OsotDestination = 'C:\Tools\OSOT',

    [string]$LogPath = 'C:\Windows\Temp\sds-apps'
)

$ErrorActionPreference = 'Stop'
$script:MountedDrive = $null
$script:Results = @()
$script:SourceFileCache = $null
$script:CopiedMedia = @()
$script:ChocolateyAttempted = $false

# Environment-variable fallbacks, supplied by the Packer provisioner. An explicitly bound
# parameter always wins, so running this by hand behaves as documented.
foreach ($map in @(
        @{ P = 'SourceType';       E = 'SDS_SOURCE_TYPE' }
        @{ P = 'SourcePath';       E = 'SDS_SOURCE_PATH' }
        @{ P = 'SourceUsername';   E = 'SDS_SOURCE_USERNAME' }
        @{ P = 'SourcePassword';   E = 'SDS_SOURCE_PASSWORD' }
        @{ P = 'AnonymousUid';     E = 'SDS_SOURCE_ANON_UID' }
        @{ P = 'AnonymousGid';     E = 'SDS_SOURCE_ANON_GID' }
        @{ P = 'ApplicationsJson'; E = 'SDS_APPLICATIONS' }
        @{ P = 'OsotPattern';      E = 'SDS_OSOT_PATTERN' }
        @{ P = 'OsotDestination';  E = 'SDS_OSOT_PATH' }
    )) {
    if ($PSBoundParameters.ContainsKey($map.P)) { continue }
    $value = [Environment]::GetEnvironmentVariable($map.E)
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    Set-Variable -Name $map.P -Value $value
}

#region Helpers

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
    # Write-Host, not Write-Output: this is called from inside functions whose return value the
    # caller assigns, and Write-Output there becomes part of that return value instead of printing.
    Write-Host "  $prefix $Message"
}

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail)
    $script:Results += [pscustomobject]@{ Application = $Name; Status = $Status; Detail = $Detail }
}

# Works backwards from Z: so it never collides with the CD/DVD drives Packer attaches.
function Get-FreeDriveLetter {
    foreach ($letter in [char[]](90..68)) {
        if (-not (Test-Path "${letter}:")) { return [string]$letter }
    }
    throw 'No free drive letter available for the installer source.'
}

function Connect-SmbSource {
    param([string]$Path, [string]$Username, [string]$Password)

    if (-not $Path) { return $null }
    Write-Step "Connecting to SMB source: $Path" -Status RUN

    $letter = Get-FreeDriveLetter
    try {
        if ($Username) {
            $secure = ConvertTo-SecureString $Password -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential($Username, $secure)
            New-PSDrive -Name $letter -PSProvider FileSystem -Root $Path -Credential $cred -Scope Script -ErrorAction Stop | Out-Null
        }
        else {
            New-PSDrive -Name $letter -PSProvider FileSystem -Root $Path -Scope Script -ErrorAction Stop | Out-Null
        }
        $script:MountedDrive = $letter
        Write-Step "Mounted $Path as ${letter}:" -Status OK
        return "${letter}:\"
    }
    catch {
        Write-Step "SMB mount failed: $($_.Exception.Message)" -Status WARN
        return $null
    }
}

function Set-NfsAnonymousIdentity {
    param([string]$Uid, [string]$Gid)

    if (-not $Uid -and -not $Gid) { return }
    $key = 'HKLM:\SOFTWARE\Microsoft\ClientForNFS\CurrentVersion\Default'
    try {
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        $changed = $false
        foreach ($pair in @(@{ Name = 'AnonymousUid'; Value = $Uid }, @{ Name = 'AnonymousGid'; Value = $Gid })) {
            if (-not $pair.Value) { continue }
            $current = (Get-ItemProperty -Path $key -Name $pair.Name -ErrorAction SilentlyContinue).($pair.Name)
            if ($current -ne [int]$pair.Value) {
                Set-ItemProperty -Path $key -Name $pair.Name -Value ([int]$pair.Value) -Type DWord -Force
                $changed = $true
            }
        }
        Write-Step "NFS anonymous identity: uid=$Uid gid=$Gid" -Status OK
        # The client reads these once at service start, so a change needs a restart to take effect.
        if ($changed) {
            foreach ($name in @('NfsClnt', 'NfsRdr')) {
                $service = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($service -and $service.Status -eq 'Running') {
                    Restart-Service -Name $name -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    catch {
        Write-Step "Could not set the NFS anonymous identity: $($_.Exception.Message)" -Status WARN
    }
}

function Connect-NfsSource {
    param([string]$Path)

    if (-not $Path) { return $null }
    Write-Step "Connecting to NFS source: $Path" -Status RUN

    $nfsFeature = Get-WindowsOptionalFeature -Online -FeatureName 'ServicesForNFS-ClientOnly' -ErrorAction SilentlyContinue
    if ($nfsFeature -and $nfsFeature.State -ne 'Enabled') {
        Write-Step 'The NFS client is not enabled. Enable it before the patching pass; enabling it here needs a restart that has not happened.' -Status WARN
        return $null
    }

    # OSOT optimization leaves this service stopped, so a mount after optimizing fails with
    # "Network Error - 1222" unless it is started again.
    $client = Get-Service -Name NfsClnt -ErrorAction SilentlyContinue
    if ($client -and $client.Status -ne 'Running') {
        Write-Step 'Starting the NFS client service...' -Status RUN
        try { Start-Service -Name NfsClnt -ErrorAction Stop } catch { Write-Step "Could not start NfsClnt: $($_.Exception.Message)" -Status WARN }
    }

    Set-NfsAnonymousIdentity -Uid $AnonymousUid -Gid $AnonymousGid

    $letter = Get-FreeDriveLetter

    # mount.exe accepts host:/export and a UNC form, and they are not equally reliable.
    $candidates = @($Path)
    if ($Path -match '^([^:\\]+):(/.*)$') {
        $candidates += ('\\{0}{1}' -f $Matches[1], ($Matches[2] -replace '/', '\'))
    }

    foreach ($candidate in $candidates) {
        try {
            $output = (& mount.exe -o anon "$candidate" "${letter}:" 2>&1 | Out-String).Trim()
            if (Test-Path "${letter}:\") {
                $script:MountedDrive = $letter
                Write-Step "Mounted $candidate as ${letter}:" -Status OK
                return "${letter}:\"
            }
            Write-Step "Mount failed for '$candidate': $output" -Status WARN
        }
        catch {
            Write-Step "Mount threw for '$candidate': $($_.Exception.Message)" -Status WARN
        }
    }
    Write-Step 'NFS needs portmapper 111 and mountd reachable, not just 2049, and the export must permit anonymous read.' -Status Info
    return $null
}

function Connect-DatastoreSource {
    param([string[]]$Patterns)

    Write-Step 'Scanning attached CD/DVD drives for an installer ISO...' -Status RUN
    $drives = Get-CimInstance Win32_CDROMDrive -ErrorAction SilentlyContinue | Where-Object { $_.MediaLoaded }
    foreach ($drive in $drives) {
        $root = "$($drive.Drive)\"
        foreach ($pattern in $Patterns) {
            $hit = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like $pattern } | Select-Object -First 1
            if ($hit) {
                Write-Step "Found installers on $root" -Status OK
                return $root
            }
        }
    }
    Write-Step 'No CD/DVD drive contained a recognizable installer.' -Status WARN
    return $null
}

function Resolve-InstallerSource {
    param([string[]]$Patterns)

    switch ($SourceType) {
        'Smb'       { return Connect-SmbSource -Path $SourcePath -Username $SourceUsername -Password $SourcePassword }
        'Nfs'       { return Connect-NfsSource -Path $SourcePath }
        'Datastore' { return Connect-DatastoreSource -Patterns $Patterns }
        'Auto' {
            $root = Connect-DatastoreSource -Patterns $Patterns
            if ($root) { return $root }
            if ($SourcePath -match '^\\\\') {
                $root = Connect-SmbSource -Path $SourcePath -Username $SourceUsername -Password $SourcePassword
                if ($root) { return $root }
            }
            if ($SourcePath -match ':') {
                $root = Connect-NfsSource -Path $SourcePath
                if ($root) { return $root }
            }
            return $null
        }
    }
}

function Disconnect-InstallerSource {
    if (-not $script:MountedDrive) { return }
    $letter = $script:MountedDrive
    try {
        if (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue) {
            Remove-PSDrive -Name $letter -Force -ErrorAction SilentlyContinue
        }
        else {
            & umount.exe -f "${letter}:" 2>&1 | Out-Null
        }
        Write-Step "Disconnected ${letter}:" -Status OK
    }
    catch {
        Write-Step "Could not disconnect ${letter}: $($_.Exception.Message)" -Status WARN
    }
    $script:MountedDrive = $null
}

# Enumerate once and match in PowerShell. Get-ChildItem -Filter is handed to the filesystem
# driver, and the NFS redirector ignores it -- a mounted NFS drive returns no matches for a
# pattern matching files that are plainly there.
function Get-SourceFiles {
    param([string]$Root)

    if ($script:SourceFileCache) { return $script:SourceFileCache }
    $errors = @()
    $script:SourceFileCache = @(Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable errors)
    Write-Step "Enumerated $($script:SourceFileCache.Count) file(s) under $Root" -Status Info
    foreach ($e in ($errors | Select-Object -First 3)) {
        Write-Step "  enumeration error: $($e.Exception.Message)" -Status WARN
    }
    return $script:SourceFileCache
}

function Write-SourceContents {
    param([string]$Root)

    $files = Get-SourceFiles -Root $Root
    if (-not $files -or $files.Count -eq 0) {
        Write-Step "Nothing enumerated under $Root. The mount succeeded but the tree is unreadable -- check the anonymous identity against the export." -Status WARN
        return
    }
    Write-Step "Files visible under ${Root}:" -Status Info
    foreach ($file in ($files | Select-Object -First 20)) {
        Write-Step "  $($file.FullName.Substring([Math]::Min($Root.Length, $file.FullName.Length)))" -Status Info
    }
    if ($files.Count -gt 20) { Write-Step "  ... and $($files.Count - 20) more" -Status Info }
}

function Find-Installer {
    param([string]$Root, [string]$Pattern, [string]$Name)

    $found = @(Get-SourceFiles -Root $Root | Where-Object { $_.Name -like $Pattern })
    if (-not $found -or $found.Count -eq 0) {
        Write-Step "$Name -- no installer matching '$Pattern' under $Root" -Status WARN
        Write-SourceContents -Root $Root
        return $null
    }
    $selected = $found |
        Sort-Object -Property @{ Expression = { try { [version]$_.VersionInfo.FileVersion } catch { [version]'0.0.0.0' } } }, Name -Descending |
        Select-Object -First 1
    if ($found.Count -gt 1) {
        Write-Step "$Name -- $($found.Count) candidates, selected $($selected.Name)" -Status Info
    }
    return $selected.FullName
}

# Installers run from local disk, never from the mounted share: a network blip during an install
# is then a copy failure with a clear message rather than an installer that appears to hang.
function Copy-InstallerLocally {
    param([string]$Path, [string]$Name)

    try {
        $staging = Join-Path $LogPath 'media'
        if (-not (Test-Path $staging)) { New-Item -Path $staging -ItemType Directory -Force | Out-Null }
        $local = Join-Path $staging (Split-Path $Path -Leaf)
        $size = [Math]::Round((Get-Item -LiteralPath $Path).Length / 1MB, 1)
        Write-Step "$Name -- copying $size MB locally before installing..." -Status RUN
        Copy-Item -LiteralPath $Path -Destination $local -Force
        $script:CopiedMedia += $local
        return $local
    }
    catch {
        Write-Step "$Name -- local copy failed ($($_.Exception.Message)); installing from the source." -Status WARN
        return $Path
    }
}

# Is this application already on the image? Supports a path, svc:<name>, or reg:<path>.
function Test-AlreadyInstalled {
    param([string]$Detect)

    if (-not $Detect) { return $false }
    try {
        if ($Detect -match '^svc:(.+)$') { return [bool](Get-Service -Name $Matches[1] -ErrorAction SilentlyContinue) }
        if ($Detect -match '^reg:(.+)$') { return (Test-Path -Path $Matches[1]) }
        return (Test-Path -LiteralPath $Detect)
    }
    catch { return $false }
}

function Invoke-Installer {
    param([string]$Name, [string]$FilePath, [string]$Arguments, [string]$LogFile, [int]$TimeoutMinutes = 30)

    Write-Step "$Name -- installing $(Split-Path $FilePath -Leaf)" -Status RUN
    try {
        # Run through a .cmd wrapper rather than passing arguments to Start-Process. Installer
        # command lines carry embedded quotes that PowerShell re-quotes on the way to
        # CreateProcess; cmd parses the line exactly as typed by hand. The file is left in place
        # so the exact command line is visible when an install fails.
        $safeName = ($Name -replace '[^\w]', '-')
        $wrapper = Join-Path $LogPath "$safeName-install.cmd"
        Set-Content -LiteralPath $wrapper -Encoding ASCII -Value @"
@echo off
"$FilePath" $Arguments
exit /b %ERRORLEVEL%
"@
        $process = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', "`"$wrapper`"" -PassThru -ErrorAction Stop
        # A ceiling rather than an indefinite wait: an installer that never returns would otherwise
        # hang the build with no output until Packer's own timeout.
        if (-not $process.WaitForExit($TimeoutMinutes * 60 * 1000)) {
            Write-Step "$Name did not finish within $TimeoutMinutes minutes; killing it." -Status FAIL
            try { $process.Kill() } catch { }
            Add-Result -Name $Name -Status 'Failed' -Detail "timed out after $TimeoutMinutes min"
            return $false
        }
        switch ($process.ExitCode) {
            0    { Write-Step "$Name installed." -Status OK; Add-Result -Name $Name -Status 'Installed' -Detail 'exit 0'; return $true }
            3010 { Write-Step "$Name installed; reboot required (3010)." -Status OK; Add-Result -Name $Name -Status 'Installed' -Detail 'exit 3010'; return $true }
            1641 { Write-Step "$Name installed; restart initiated (1641)." -Status OK; Add-Result -Name $Name -Status 'Installed' -Detail 'exit 1641'; return $true }
            default {
                Write-Step "$Name installer exited with code $($process.ExitCode). Command line: $wrapper" -Status FAIL
                Add-Result -Name $Name -Status 'Failed' -Detail "exit $($process.ExitCode)"
                return $false
            }
        }
    }
    catch {
        Write-Step "$Name install threw: $($_.Exception.Message)" -Status FAIL
        Add-Result -Name $Name -Status 'Failed' -Detail $_.Exception.Message
        return $false
    }
}

#endregion

Write-Output ''
Write-Output '  SDS Client Connector -- Applications'
Write-Output "  Windows Build $([Environment]::OSVersion.Version.Build)"
Write-Output ''

if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }

if ($StageOsotOnly) {
    $root = Resolve-InstallerSource -Patterns @($OsotPattern)
    if ($root -isnot [string] -or [string]::IsNullOrWhiteSpace($root)) {
        throw "Could not resolve an installer source for OSOT staging (SourceType='$SourceType', SourcePath='$SourcePath')."
    }
    try {
        $osot = Get-SourceFiles -Root $root |
            Where-Object { $_.Name -like $OsotPattern } |
            Sort-Object -Property @{ Expression = { try { [version]$_.VersionInfo.FileVersion } catch { [version]'0.0.0.0' } } } -Descending |
            Select-Object -First 1
        if (-not $osot) {
            Write-SourceContents -Root $root
            throw "No OSOT executable matching '$OsotPattern' found under $root."
        }
        if (-not (Test-Path $OsotDestination)) { New-Item -Path $OsotDestination -ItemType Directory -Force | Out-Null }
        Copy-Item -LiteralPath $osot.FullName -Destination $OsotDestination -Force
        Write-Step "Staged $($osot.Name) to $OsotDestination" -Status OK
    }
    finally {
        Disconnect-InstallerSource
    }
    return
}

function Install-ChocolateyIfMissing {
    # Only called when an application declares type 'choco'. Chocolatey is deliberately NOT part
    # of the base image -- the Horizon golden image stays free of it -- so it is bootstrapped here,
    # once, for the SDS image alone.
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) { return $true }
    if ($script:ChocolateyAttempted) { return $false }
    $script:ChocolateyAttempted = $true

    Write-Step 'Chocolatey not present; installing it...' -Status RUN
    try {
        # curl.exe rather than WebClient/Invoke-WebRequest: it needs no .NET TLS or certificate
        # plumbing, which has misbehaved on these guests.
        $bootstrap = Join-Path $LogPath 'choco-install.ps1'
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        & $curl -sSL -o $bootstrap 'https://community.chocolatey.org/install.ps1' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $bootstrap)) {
            throw "could not download the Chocolatey bootstrap (curl exit $LASTEXITCODE)"
        }
        & powershell.exe -ExecutionPolicy Bypass -NoProfile -File $bootstrap 2>&1 | Out-Null
        $global:LASTEXITCODE = 0
        $env:Path = "$env:Path;$env:ProgramData\chocolatey\bin"
        if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
            Write-Step 'Chocolatey installed.' -Status OK
            return $true
        }
        throw 'the bootstrap ran but choco.exe is still not on PATH'
    }
    catch {
        Write-Step "Chocolatey bootstrap failed: $($_.Exception.Message)" -Status FAIL
        return $false
    }
}

if ([string]::IsNullOrWhiteSpace($ApplicationsJson)) {
    Write-Step 'No applications defined; nothing to do.' -Status SKIP
    return
}

try {
    # Windows PowerShell 5.1 writes a JSON array to the pipeline as ONE object rather than
    # enumerating it, so @( ... | ConvertFrom-Json ) yields a single element containing the whole
    # array. The loop below then runs once with $app bound to the array, and $app.name returns
    # every name at once via member enumeration -- which reads as one application with a
    # concatenated name and pattern. Building the list with += unrolls it on 5.1 and 7 alike.
    $applications = @()
    $applications += ConvertFrom-Json -InputObject $ApplicationsJson
}
catch {
    throw "SDS_APPLICATIONS is not valid JSON: $($_.Exception.Message)"
}
if (-not $applications -or $applications.Count -eq 0) {
    Write-Step 'The application list is empty; nothing to do.' -Status SKIP
    return
}

Write-Step "$($applications.Count) application(s) to install: $(($applications | ForEach-Object { $_.name }) -join ', ')" -Status Info

# Chocolatey entries carry a package id in 'pattern', not a filename, so they neither contribute
# a search pattern nor need an installer source. An all-choco list skips source resolution.
$fileApplications = @($applications | Where-Object { $_.type -ne 'choco' })
$root = $null
if ($fileApplications.Count -gt 0) {
    $root = Resolve-InstallerSource -Patterns @($fileApplications | ForEach-Object { $_.pattern })
# Checked as a string rather than for truthiness: a helper that accidentally emits log lines would
# return a non-empty array here and sail past a plain -not test.
    if ($root -isnot [string] -or [string]::IsNullOrWhiteSpace($root)) {
        throw "Could not resolve an installer source (SourceType='$SourceType', SourcePath='$SourcePath')."
    }
    Write-Step "Installer source: $root" -Status OK
}
else {
    Write-Step 'Every application is a Chocolatey package; no installer source needed.' -Status Info
}
Write-Output ''

foreach ($app in $applications) {
    $name = $app.name
    if (-not $name) { $name = $app.pattern }

    if (Test-AlreadyInstalled -Detect $app.detect) {
        Write-Step "$name -- already installed." -Status SKIP
        Add-Result -Name $name -Status 'Skipped' -Detail 'already installed'
        continue
    }

    if ($app.type -eq 'choco') {
        # 'pattern' holds the package id for these.
        if (-not (Install-ChocolateyIfMissing)) {
            Add-Result -Name $name -Status $(if ($app.required) { 'Failed' } else { 'Missing' }) -Detail 'Chocolatey unavailable'
            continue
        }
        $logFile = Join-Path $LogPath (($name -replace '[^\w]', '-') + '.log')
        $arguments = "install $($app.pattern) $($app.args)"
        Invoke-Installer -Name $name -FilePath 'choco.exe' -Arguments $arguments -LogFile $logFile | Out-Null
        continue
    }

    $installer = Find-Installer -Root $root -Pattern $app.pattern -Name $name
    if (-not $installer) {
        if ($app.required) {
            Add-Result -Name $name -Status 'Failed' -Detail "required, no match for '$($app.pattern)'"
        }
        else {
            Add-Result -Name $name -Status 'Missing' -Detail "no match for '$($app.pattern)'"
        }
        continue
    }

    $installer = Copy-InstallerLocally -Path $installer -Name $name
    $logFile = Join-Path $LogPath (($name -replace '[^\w]', '-') + '.log')

    if ($app.type -eq 'msi') {
        $arguments = "/i `"$installer`" $($app.args) /l*v `"$logFile`""
        Invoke-Installer -Name $name -FilePath 'msiexec.exe' -Arguments $arguments -LogFile $logFile | Out-Null
    }
    else {
        Invoke-Installer -Name $name -FilePath $installer -Arguments $app.args -LogFile $logFile | Out-Null
    }
}

Disconnect-InstallerSource

# Staged installers are build scratch, not part of the image.
foreach ($file in $script:CopiedMedia) {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output '  Summary'
$script:Results | ForEach-Object { Write-Output "    $($_.Application): $($_.Status) ($($_.Detail))" }
Write-Output ''

# A missing optional installer is reported but does not stop the build, so a share that is short
# one application still yields an image. A failed install, or a missing required one, does not pass.
$failed = @($script:Results | Where-Object { $_.Status -eq 'Failed' })
if ($failed) {
    throw "$($failed.Count) application(s) failed: $($failed.Application -join ', ')"
}
