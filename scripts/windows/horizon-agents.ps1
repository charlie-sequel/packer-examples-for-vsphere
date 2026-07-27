# © Broadcom. All Rights Reserved.
# The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-2-Clause

<#
    .SYNOPSIS
    Installs the Omnissa Horizon agent stack on a golden image during a Packer build.

    .DESCRIPTION
    Resolves an installer source (SMB share, NFS export, or a mounted vSphere datastore ISO),
    locates each agent installer by filename pattern rather than by exact version, and installs it
    silently with the parameters appropriate to a golden image.

    Installation order is significant and is enforced regardless of the order of -Include:

      1. Horizon Agent
      2. Dynamic Environment Manager (FlexEngine)
      3. FSLogix
      4. App Volumes Agent   (always last)

    Every install is idempotent: if the agent's service is already present the installer is
    skipped, so the script is safe to re-run against a partially built image.

    This script is non-interactive by design. It never prompts, never reboots, and never releases
    the network adapter, any of which would strand a Packer build with no output. Exit code 3010
    (reboot required) is treated as success; Packer performs the restart between provisioners.

    .PARAMETER SourceType
    Where the installers live. 'Smb' and 'Nfs' mount a network path; 'Datastore' scans attached
    CD/DVD drives for an installer ISO. 'Auto' tries Datastore, then Smb, then Nfs.

    .PARAMETER SourcePath
    UNC path (Smb) or export path (Nfs). Unused for Datastore.

    .PARAMETER SourceUsername
    Username for the SMB share.

    .PARAMETER SourcePassword
    Password for the SMB share. Prefer the HORIZON_SOURCE_PASSWORD environment variable: anything
    passed on the command line is visible in the guest's process list and is echoed into the
    Packer log.

    .PARAMETER Include
    Which agents to install. Defaults to all four.

    .PARAMETER VcManagedAgent
    Maps to VDM_VC_MANAGED_AGENT. '1' for images consumed by vCenter-managed automated pools, in
    which case no Connection Server registration happens and the Connection Server parameters are
    unused. '0' for unmanaged or manual pools, which registers with -ConnectionServer at install
    time and requires the credentials.

    .PARAMETER ConnectionServer
    Connection Server FQDN, mapped to VDM_SERVER_NAME. Required when -VcManagedAgent is '0'.

    .PARAMETER ConnectionServerUsername
    Connection Server administrator, mapped to VDM_SERVER_USERNAME.

    .PARAMETER ConnectionServerPassword
    Connection Server password, mapped to VDM_SERVER_PASSWORD. Prefer the
    HORIZON_CONNECTION_SERVER_PASSWORD environment variable. The Horizon Agent installer cannot
    read passwords from a configuration file, so this necessarily reaches the installer on its
    command line; keeping it in an environment variable at least keeps it out of the Packer log.

    .PARAMETER DemConfigShare
    UNC path to the Dynamic Environment Manager configuration share, mapped to
    COMPENVCONFIGFILEPATH. Setting this enables computer environment settings support, which is
    what applies computer based policies. Requires DEM Agent 2103 or later.

    .PARAMETER DemLicenseFile
    UNC path to the DEM license file, mapped to LICENSEFILE.

    .PARAMETER FslogixProfilePath
    UNC path for FSLogix profile containers. When set, Profiles\Enabled and Profiles\VHDLocations
    are configured after FSLogix installs.

    .PARAMETER AppVolumesManager
    App Volumes Manager hostname or IP. The App Volumes Agent is skipped when this is empty.

    .EXAMPLE
    .\horizon-agents.ps1 -SourceType Smb -SourcePath \\nas\software\omnissa -AppVolumesManager av.example.com

    .EXAMPLE
    .\horizon-agents.ps1 -SourceType Datastore -Include HorizonAgent,Fslogix

    .NOTES
    Intended to run over WinRM from a Packer provisioner.
    Reference: https://techzone.omnissa.com/resource/manually-creating-optimized-windows-images-horizon-vms
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Smb', 'Nfs', 'Datastore')]
    [string]$SourceType = 'Auto',

    [string]$SourcePath,
    [string]$SourceUsername,
    [string]$SourcePassword,

    [ValidateSet('HorizonAgent', 'Dem', 'Fslogix', 'AppVolumes')]
    [string[]]$Include = @('HorizonAgent', 'Dem', 'Fslogix', 'AppVolumes'),

    # Horizon Agent
    [string]$HorizonAgentPattern = '*Horizon-Agent-x86_64*.exe',
    [string]$HorizonAgentFeatures = 'Core,USB,ClientDriveRedirection,PrintRedir,NGVC',
    [ValidateSet('0', '1')]
    [string]$VcManagedAgent = '1',
    [string]$ConnectionServer,
    [string]$ConnectionServerUsername,
    [string]$ConnectionServerPassword,

    # Dynamic Environment Manager
    [string]$DemPattern = '*Dynamic*Environment*Manager*.msi',
    [string]$DemFeatures = 'FlexEngine',
    [string]$DemConfigShare,
    [string]$DemLicenseFile,
    [string]$DemArgs,

    # FSLogix
    [string]$FslogixPattern = 'FSLogixAppsSetup.exe',
    [string]$FslogixArgs = '/install /quiet /norestart',
    [string]$FslogixProfilePath,

    # App Volumes
    [string]$AppVolumesPattern = '*App*Volumes*Agent*.msi',
    [string]$AppVolumesManager,
    [int]$AppVolumesPort = 443,

    # Identity the Windows NFS client presents to the server. It mounts with -o anon, and its
    # default anonymous UID is -2 (4294967294) -- not the Linux nobody (65534). An export whose
    # files are owned by a specific UID rejects that, and the mount then succeeds while the tree
    # reads as access denied. Set these to a UID/GID that can read the export.
    [string]$AnonymousUid,
    [string]$AnonymousGid,

    # Run the agent stack from a scheduled task instead of inline, and return immediately.
    #
    # The Horizon Agent replaces network and VMware Tools components and needs a restart before
    # either works again. An inline install loses the connection when they go down and the build
    # fails with "no route to host". Detached, the install is owned by the task scheduler, survives
    # the outage, publishes its exit code as a marker file, and then reboots the guest.
    [switch]$Detached,

    # OS Optimization Tool staging. OSOT has to be on the guest before the first optimization
    # provisioner runs, and it lives on the same share as the agents, so the source-resolution
    # logic here is reused rather than duplicated into horizon-osot.ps1. With this switch the
    # script copies OSOT and does nothing else.
    [switch]$StageOsotOnly,
    [string]$OsotPattern = '*OSOptimizationTool*.exe',
    [string]$OsotDestination = 'C:\Tools\OSOT',

    [string]$LogPath = 'C:\Windows\Temp\horizon-agents'
)

$ErrorActionPreference = 'Stop'
$script:MountedDrive = $null
$script:Results = @()
$script:SourceFileCache = $null
$script:CopiedMedia = @()

# Environment-variable fallbacks. The Packer provisioner supplies configuration this way rather
# than on the command line: several of these values contain characters that do not survive a round
# trip through a PowerShell execute_command, and the passwords must stay out of the Packer log.
# An explicitly bound parameter always wins, so running the script by hand behaves as documented.
foreach ($map in @(
        @{ P = 'SourceType';               E = 'HORIZON_SOURCE_TYPE' }
        @{ P = 'SourcePath';               E = 'HORIZON_SOURCE_PATH' }
        @{ P = 'SourceUsername';           E = 'HORIZON_SOURCE_USERNAME' }
        @{ P = 'SourcePassword';           E = 'HORIZON_SOURCE_PASSWORD' }
        @{ P = 'HorizonAgentPattern';      E = 'HORIZON_AGENT_PATTERN' }
        @{ P = 'HorizonAgentFeatures';     E = 'HORIZON_AGENT_FEATURES' }
        @{ P = 'VcManagedAgent';           E = 'HORIZON_AGENT_VC_MANAGED' }
        @{ P = 'ConnectionServer';         E = 'HORIZON_CONNECTION_SERVER' }
        @{ P = 'ConnectionServerUsername'; E = 'HORIZON_CONNECTION_SERVER_USERNAME' }
        @{ P = 'ConnectionServerPassword'; E = 'HORIZON_CONNECTION_SERVER_PASSWORD' }
        @{ P = 'DemPattern';               E = 'HORIZON_DEM_PATTERN' }
        @{ P = 'DemFeatures';              E = 'HORIZON_DEM_FEATURES' }
        @{ P = 'DemConfigShare';           E = 'HORIZON_DEM_CONFIG_SHARE' }
        @{ P = 'DemLicenseFile';           E = 'HORIZON_DEM_LICENSE_FILE' }
        @{ P = 'DemArgs';                  E = 'HORIZON_DEM_ARGS' }
        @{ P = 'FslogixPattern';           E = 'HORIZON_FSLOGIX_PATTERN' }
        @{ P = 'FslogixArgs';              E = 'HORIZON_FSLOGIX_ARGS' }
        @{ P = 'FslogixProfilePath';       E = 'HORIZON_FSLOGIX_PROFILE_PATH' }
        @{ P = 'AppVolumesPattern';        E = 'HORIZON_APPVOLUMES_PATTERN' }
        @{ P = 'AppVolumesManager';        E = 'HORIZON_APPVOLUMES_MANAGER' }
        @{ P = 'AnonymousUid';             E = 'HORIZON_SOURCE_ANON_UID' }
        @{ P = 'AnonymousGid';             E = 'HORIZON_SOURCE_ANON_GID' }
        @{ P = 'OsotPattern';              E = 'HORIZON_OSOT_PATTERN' }
        @{ P = 'OsotDestination';          E = 'HORIZON_OSOT_PATH' }
    )) {
    if ($PSBoundParameters.ContainsKey($map.P)) { continue }
    $value = [Environment]::GetEnvironmentVariable($map.E)
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    Set-Variable -Name $map.P -Value $value
}

if (-not $PSBoundParameters.ContainsKey('Include') -and $env:HORIZON_INCLUDE) {
    $Include = $env:HORIZON_INCLUDE -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
if (-not $PSBoundParameters.ContainsKey('AppVolumesPort') -and $env:HORIZON_APPVOLUMES_PORT) {
    $AppVolumesPort = [int]$env:HORIZON_APPVOLUMES_PORT
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
    # Write-Host, not Write-Output. This is called from inside functions whose return value the
    # caller assigns, and Write-Output there is captured as part of that return value instead of
    # being printed -- which turns a mount failure into an array of log strings that passes a
    # null check and then fails obscurely much further down.
    Write-Host "  $prefix $Message"
}

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail)
    $script:Results += [pscustomobject]@{ Agent = $Name; Status = $Status; Detail = $Detail }
}

# Returns a free drive letter, working backwards from Z: so it never collides with the CD/DVD
# drives Packer attaches for the answer file and the VMware Tools media.
function Get-FreeDriveLetter {
    foreach ($letter in [char[]](90..68)) {
        if (-not (Test-Path "${letter}:")) { return [string]$letter }
    }
    throw 'No free drive letter available for the installer source.'
}

#endregion

#region Source resolution

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

# Point the NFS client at a specific anonymous identity. The client reads these once at service
# start, so the service is restarted after a change -- otherwise the new values are ignored and the
# mount fails exactly as it did before, which is a confusing thing to debug.
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

    # The NFS client is not present by default on Windows client SKUs. Enable it on demand; this
    # is why the NFS path costs an extra feature install that the SMB path does not.
    #
    # Enabling it is not enough to use it in the same session: the client installs a redirector
    # driver, and until that is loaded every mount fails with "Network Error - 53". Start the
    # services explicitly after enabling, and report the need for a restart rather than reporting
    # an unreachable server, which is what error 53 reads like.
    $restartPending = $false
    $nfsFeature = Get-WindowsOptionalFeature -Online -FeatureName 'ServicesForNFS-ClientOnly' -ErrorAction SilentlyContinue
    if ($nfsFeature -and $nfsFeature.State -ne 'Enabled') {
        Write-Step 'Enabling the Windows NFS client feature...' -Status RUN
        try {
            $result = Enable-WindowsOptionalFeature -Online -FeatureName 'ServicesForNFS-ClientOnly' -All -NoRestart -ErrorAction Stop
            Enable-WindowsOptionalFeature -Online -FeatureName 'ClientForNFS-Infrastructure' -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
            if ($result -and $result.RestartNeeded) { $restartPending = $true }
            Write-Step 'NFS client enabled.' -Status OK
        }
        catch {
            Write-Step "Could not enable the NFS client: $($_.Exception.Message)" -Status WARN
            return $null
        }

        # Bring the client up without a restart where Windows allows it.
        foreach ($name in @('NfsRdr', 'NfsClnt')) {
            try {
                $service = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($service -and $service.Status -ne 'Running') {
                    Start-Service -Name $name -ErrorAction Stop
                    Write-Step "Started $name." -Status OK
                }
            }
            catch {
                Write-Step "Could not start ${name}: $($_.Exception.Message)" -Status WARN
                $restartPending = $true
            }
        }
    }

    Set-NfsAnonymousIdentity -Uid $AnonymousUid -Gid $AnonymousGid

    $letter = Get-FreeDriveLetter

    # Windows mount.exe documents two syntaxes for the same export, host:/export and a UNC form,
    # and they are not equally reliable -- the UNC form succeeds against some servers where the
    # colon form returns error 53. Try both before concluding anything is wrong with the server.
    $candidates = @($Path)
    if ($Path -match '^([^:\\]+):(/.*)$') {
        $candidates += ('\\{0}{1}' -f $Matches[1], ($Matches[2] -replace '/', '\'))
    }

    foreach ($candidate in $candidates) {
    foreach ($attempt in 1..2) {
        try {
            # Surface mount.exe's own message. Its wording is the fastest way to tell an
            # export-list rejection ("permission denied") apart from a squashed-root permissions
            # problem or a client that is not up yet ("Network Error - 53").
            $output = (& mount.exe -o anon "$candidate" "${letter}:" 2>&1 | Out-String).Trim()
            if (Test-Path "${letter}:\") {
                $script:MountedDrive = $letter
                Write-Step "Mounted $candidate as ${letter}:" -Status OK
                return "${letter}:\"
            }
            Write-Step "Mount failed for '$candidate' (attempt $attempt): $output" -Status WARN
            if ($attempt -eq 1) { Start-Sleep -Seconds 10 }
        }
        catch {
            Write-Step "Mount threw for '$candidate': $($_.Exception.Message)" -Status WARN
        }
    }
    }

    # Every syntax failed. Report what the guest can actually see, so the next step is a decision
    # rather than another guess: an unreachable portmapper is a firewall problem, a reachable one
    # that still refuses is an export or anonymous-access problem.
    Write-Step 'All mount syntaxes failed. Collecting diagnostics from the guest...' -Status Info
    $server = if ($Path -match '^([^:\\]+):') { $Matches[1] } elseif ($Path -match '^\\\\([^\\]+)') { $Matches[1] } else { $null }
    if ($server) {
        foreach ($port in @(111, 2049, 445)) {
            try {
                $test = Test-NetConnection -ComputerName $server -Port $port -WarningAction SilentlyContinue
                $label = switch ($port) { 111 { 'portmapper' } 2049 { 'nfs' } 445 { 'smb' } }
                Write-Step ("  {0}:{1} ({2}) reachable = {3}" -f $server, $port, $label, $test.TcpTestSucceeded) -Status Info
            }
            catch {
                Write-Step "  Could not test ${server}:${port}: $($_.Exception.Message)" -Status WARN
            }
        }
        # showmount ships with the Windows NFS client and asks the server directly what it exports.
        try {
            $exports = (& showmount.exe -e $server 2>&1 | Out-String).Trim()
            Write-Step "  showmount -e $server :" -Status Info
            foreach ($line in ($exports -split "`r?`n")) { Write-Step "    $line" -Status Info }
        }
        catch {
            Write-Step "  showmount failed: $($_.Exception.Message)" -Status WARN
        }
    }
    Write-Step 'The Smb source type needs no optional feature, no restart, and no anonymous access.' -Status Info
    return $null
}

function Connect-DatastoreSource {
    # Packer mounts datastore ISOs as CD/DVD drives. Identify the installer ISO by looking for a
    # drive that actually contains one of the agent installers, rather than by volume label, so
    # the ISO can be renamed without breaking the build.
    Write-Step 'Scanning attached CD/DVD drives for an installer ISO...' -Status RUN

    $patterns = @($HorizonAgentPattern, $DemPattern, $FslogixPattern, $AppVolumesPattern)
    $drives = Get-CimInstance Win32_CDROMDrive -ErrorAction SilentlyContinue | Where-Object { $_.MediaLoaded }

    foreach ($drive in $drives) {
        $root = "$($drive.Drive)\"
        foreach ($pattern in $patterns) {
            $hit = Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like $pattern } | Select-Object -First 1
            if ($hit) {
                Write-Step "Found installers on $root" -Status OK
                return $root
            }
        }
    }

    Write-Step 'No CD/DVD drive contained a recognizable agent installer.' -Status WARN
    return $null
}

function Resolve-InstallerSource {
    switch ($SourceType) {
        'Smb'       { return Connect-SmbSource -Path $SourcePath -Username $SourceUsername -Password $SourcePassword }
        'Nfs'       { return Connect-NfsSource -Path $SourcePath }
        'Datastore' { return Connect-DatastoreSource }
        'Auto' {
            # Cheapest and most reliable first: a locally attached ISO needs no credentials.
            $root = Connect-DatastoreSource
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
        Write-Step "Could not cleanly disconnect ${letter}: $($_.Exception.Message)" -Status WARN
    }
    $script:MountedDrive = $null
}

#endregion

#region Installer discovery and execution

# Finds the newest matching installer beneath $Root. "Newest" is decided by file version when the
# binary carries one and by name otherwise, so dropping a new agent build onto the share is enough
# to pick it up without a configuration change.
# Enumerate a source tree once. Deliberately does NOT use Get-ChildItem -Filter: -Filter is handed
# to the underlying filesystem driver, and the NFS redirector does not apply it -- a mounted NFS
# drive returns nothing for a pattern that matches files which are demonstrably there. Enumerating
# and matching in PowerShell with -like is slower but behaves the same on every source type.
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

# Report what the source actually contains. Called whenever a pattern matches nothing, so the
# failure says whether the tree is empty, unreadable, or simply named differently than expected.
function Write-SourceContents {
    param([string]$Root)

    $files = Get-SourceFiles -Root $Root
    if (-not $files -or $files.Count -eq 0) {
        Write-Step "Nothing enumerated under $Root. The mount succeeded but the tree is unreadable." -Status WARN
        Write-Step "The client presents the anonymous identity below; the export must grant it read and traverse." -Status Info
        $key = 'HKLM:\SOFTWARE\Microsoft\ClientForNFS\CurrentVersion\Default'
        $identity = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        $uid = if ($identity -and $null -ne $identity.AnonymousUid) { $identity.AnonymousUid } else { '-2 (default)' }
        $gid = if ($identity -and $null -ne $identity.AnonymousGid) { $identity.AnonymousGid } else { '-2 (default)' }
        Write-Step "  AnonymousUid=$uid AnonymousGid=$gid" -Status Info
        Write-Step "  Set horizon_agent_source_anon_uid / _gid to a UID that can read the export." -Status Info
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

# Copy an installer to local disk before running it. Installers are large -- the Horizon Agent
# alone is over 250 MB -- and running one directly from a mounted share makes the share a
# dependency for the whole install rather than just the copy, with a network blip surfacing as an
# installer hang rather than a copy failure. Returns the local path, or the original on failure.
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

function Invoke-Installer {
    param([string]$Name, [string]$FilePath, [string]$Arguments, [string]$LogFile, [int]$TimeoutMinutes = 45)

    Write-Step "$Name -- installing $(Split-Path $FilePath -Leaf)" -Status RUN
    try {
        # Run through a .cmd wrapper rather than passing the arguments to Start-Process.
        #
        # The InstallShield form is  setup.exe /s /v"/qn PROP=1 /norestart"  -- the inner quotes are
        # part of the /v argument and must survive verbatim. PowerShell re-quotes -ArgumentList on
        # its way to CreateProcess and breaks them, so the installer sees a bare /v, prints its
        # usage dialog, and exits 1814. cmd parses the line exactly as typed by hand. The file is
        # left in place afterwards so the exact command line is visible when an install fails.
        $safeName = ($Name -replace '[^\w]', '-')
        $wrapper = Join-Path $LogPath "$safeName-install.cmd"
        Set-Content -LiteralPath $wrapper -Encoding ASCII -Value @"
@echo off
"$FilePath" $Arguments
exit /b %ERRORLEVEL%
"@
        $process = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', "`"$wrapper`"" -PassThru -ErrorAction Stop
        # A ceiling rather than an indefinite wait: an installer that never returns would otherwise
        # hang the build with no output until Packer's own timeout, with nothing explaining why.
        if (-not $process.WaitForExit($TimeoutMinutes * 60 * 1000)) {
            Write-Step "$Name did not finish within $TimeoutMinutes minutes; killing it. Log: $LogFile" -Status FAIL
            try { $process.Kill() } catch { }
            Add-Result -Name $Name -Status 'Failed' -Detail "timed out after $TimeoutMinutes min"
            return $false
        }
        switch ($process.ExitCode) {
            0 {
                Write-Step "$Name installed." -Status OK
                Add-Result -Name $Name -Status 'Installed' -Detail 'exit 0'
                return $true
            }
            3010 {
                # Reboot required. Packer restarts between provisioners, so this is not a failure.
                Write-Step "$Name installed; reboot required (3010)." -Status OK
                Add-Result -Name $Name -Status 'Installed' -Detail 'exit 3010, reboot pending'
                return $true
            }
            1641 {
                # ERROR_SUCCESS_REBOOT_INITIATED: installed, and the installer started a restart of
                # its own despite REBOOT=ReallySuppress. Success, but worth seeing in the log.
                Write-Step "$Name installed; the installer initiated a restart (1641)." -Status OK
                Add-Result -Name $Name -Status 'Installed' -Detail 'exit 1641, restart initiated'
                return $true
            }
            default {
                Write-Step "$Name installer exited with code $($process.ExitCode). Log: $LogFile" -Status FAIL
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

#region Argument builders

function Get-HorizonAgentArguments {
    # The Horizon Agent is an InstallShield wrapper: /s is the wrapper's silent switch and
    # everything inside /v"..." is handed to the underlying MSI.
    $properties = @(
        "VDM_VC_MANAGED_AGENT=$VcManagedAgent"
        "VDM_FORCE_DESKTOP_AGENT=1"
        "ADDLOCAL=$HorizonAgentFeatures"
    )

    if ($VcManagedAgent -eq '0') {
        # Unmanaged and manual pools register with the Connection Server during installation.
        # Fail loudly here rather than letting the installer fail obscurely much later.
        if (-not $ConnectionServer) {
            throw 'VcManagedAgent is 0 but no ConnectionServer was supplied. Set horizon_connection_server, or set horizon_agent_vc_managed = true for vCenter-managed pools.'
        }
        if (-not $ConnectionServerUsername -or -not $ConnectionServerPassword) {
            throw "VcManagedAgent is 0 but the Connection Server credentials are incomplete. Both horizon_connection_server_username and horizon_connection_server_password are required to register with $ConnectionServer."
        }
        $properties += "VDM_SERVER_NAME=$ConnectionServer"
        $properties += "VDM_SERVER_USERNAME=$ConnectionServerUsername"
        $properties += "VDM_SERVER_PASSWORD=$ConnectionServerPassword"
        Write-Step "Registering with Connection Server $ConnectionServer" -Status Info
    }
    else {
        Write-Step 'vCenter-managed agent; no Connection Server registration.' -Status Info
    }

    # REBOOT=ReallySuppress, not /norestart.
    #
    # /norestart inside the /v string is rejected by the 2603 bootstrapper: it prints its usage
    # dialog and exits 1814 without installing anything. Verified by bisecting the command line on
    # a live guest -- /s /v"/qn" returns 0, /s /v"/qn ADDLOCAL=Core" installs, and the only form
    # that fails is the one carrying /norestart. REBOOT=ReallySuppress is the MSI property that
    # does the same job, and it keeps the restart under this script's control: the runner reboots
    # after the completion marker is written, so the marker survives.
    $properties += 'REBOOT=ReallySuppress'
    return "/s /v`"/qn $($properties -join ' ')`""
}

function Get-DemArguments {
    param([string]$InstallerPath, [string]$LogFile)

    $arguments = "/i `"$InstallerPath`" /qn /norestart ADDLOCAL=$DemFeatures"

    if ($DemConfigShare) {
        # Enables computer environment settings support, which is what applies computer based
        # policies. DEM Agent 2103 and later only; earlier agents use registry values instead.
        $arguments += " COMPENVCONFIGFILEPATH=`"$DemConfigShare`""
        Write-Step "Computer environment settings from $DemConfigShare" -Status Info
    }
    else {
        Write-Step 'No DEM configuration share set; computer based policies will not be applied.' -Status WARN
    }

    if ($DemLicenseFile) { $arguments += " LICENSEFILE=`"$DemLicenseFile`"" }
    if ($DemArgs) { $arguments += " $DemArgs" }

    return "$arguments /l*v `"$LogFile`""
}

function Set-FslogixProfileConfiguration {
    if (-not $FslogixProfilePath) {
        Write-Step 'No FSLogix profile path set; leaving profile containers unconfigured.' -Status SKIP
        return
    }
    try {
        $key = 'HKLM:\SOFTWARE\FSLogix\Profiles'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -Path $key -Name 'Enabled' -Value 1 -Type DWord -Force
        # VHDLocations is REG_MULTI_SZ; a single path is still written as a one-element array.
        Set-ItemProperty -Path $key -Name 'VHDLocations' -Value @($FslogixProfilePath) -Type MultiString -Force
        Write-Step "FSLogix profile containers configured: $FslogixProfilePath" -Status OK
    }
    catch {
        Write-Step "Could not configure FSLogix profile containers: $($_.Exception.Message)" -Status WARN
    }
}

#endregion

# ═══════════════════════════════════════════════════════════════════════
Write-Output ''
Write-Output '  Omnissa Horizon Agent Stack'
Write-Output "  Windows Build $([Environment]::OSVersion.Version.Build)"
Write-Output ''

if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }

# Hand the whole run to the task scheduler and return. See the -Detached parameter for why.
if ($Detached) {
    $runner   = Join-Path $LogPath 'run-agents.ps1'
    $envFile  = Join-Path $LogPath 'env.ps1'
    $selfCopy = Join-Path $LogPath 'horizon-agents.ps1'
    $marker   = Join-Path $LogPath 'agent-stack.done'

    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $PSCommandPath -Destination $selfCopy -Force

    # The task runs in a different session, so the configuration has to travel with it. This file
    # holds share and Connection Server passwords, so the runner deletes it the moment it has been
    # read, and again on the way out.
    $lines = foreach ($item in Get-ChildItem env: | Where-Object { $_.Name -like 'HORIZON_*' }) {
        "`$env:$($item.Name) = '$($item.Value -replace "'", "''")'"
    }
    Set-Content -LiteralPath $envFile -Value $lines -Encoding UTF8

    Set-Content -LiteralPath $runner -Encoding UTF8 -Value @"
`$ErrorActionPreference = 'Continue'
. '$envFile'
Remove-Item -LiteralPath '$envFile' -Force -ErrorAction SilentlyContinue
try {
    & '$selfCopy' *>&1 | Tee-Object -FilePath '$(Join-Path $LogPath "agent-stack.log")'
    `$code = if (`$LASTEXITCODE -ne `$null) { `$LASTEXITCODE } else { 0 }
}
catch {
    `$_ | Out-File -FilePath '$(Join-Path $LogPath "agent-stack.log")' -Append
    `$code = 1
}
Remove-Item -LiteralPath '$envFile' -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath '$marker' -Value `$code

# Reboot from inside the guest, after the marker is written.
#
# The agent installer replaces the network stack and VMware Tools components and needs a restart
# to reload them. Run with /norestart and neither comes back: the guest sits there with no
# network and no Tools, which looks like a hang from outside. Packer cannot issue this restart
# itself -- by the time the install finishes there is no connection left to issue it over -- so
# the guest has to do it. The marker is written first so its presence survives the reboot.
shutdown /r /f /t 15 /c "packer: agent stack complete"
"@

    $taskName = 'PackerHorizonAgentStack'
    & schtasks.exe /create /tn $taskName /ru SYSTEM /rl HIGHEST /sc once /st 00:00 /f `
        /tr "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$runner`"" | Out-Null
    & schtasks.exe /run /tn $taskName | Out-Null

    Write-Step "Agent stack launched as scheduled task '$taskName'." -Status OK
    Write-Step "Completion marker: $marker (contains the exit code)" -Status Info
    Write-Step 'This provisioner returns now; the install continues even if the guest drops off the network.' -Status Info
    return
}

# Staging OSOT is its own run: it happens before the optimization provisioner, which is before any
# agent is installed. Handled ahead of the $Include check because staging does not select agents.
if ($StageOsotOnly) {
    $root = Resolve-InstallerSource
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
        if (-not (Test-Path $OsotDestination)) {
            New-Item -Path $OsotDestination -ItemType Directory -Force | Out-Null
        }
        Copy-Item -LiteralPath $osot.FullName -Destination $OsotDestination -Force
        Write-Step "Staged $($osot.Name) to $OsotDestination" -Status OK
    }
    finally {
        Disconnect-InstallerSource
    }
    return
}

if (-not $Include) {
    Write-Step 'No agents selected; nothing to do.' -Status SKIP
    return
}

$root = Resolve-InstallerSource
# Checked as a string rather than for truthiness: a helper that accidentally emits log lines would
# return a non-empty array here and sail past a plain -not test.
if ($root -isnot [string] -or [string]::IsNullOrWhiteSpace($root)) {
    throw "Could not resolve an installer source (SourceType='$SourceType', SourcePath='$SourcePath')."
}
Write-Step "Installer source: $root" -Status OK
Write-Output ''

# The catalogue is ordered deliberately. App Volumes must be installed after everything else or it
# captures an incomplete machine state; DEM must follow the Horizon Agent.
$catalogue = @(
    @{
        Key       = 'HorizonAgent'
        Name      = 'Horizon Agent'
        Service   = 'WSNM'
        Pattern   = $HorizonAgentPattern
        Build     = { param($path, $log) Get-HorizonAgentArguments }
        Direct    = $true
    }
    @{
        Key       = 'Dem'
        Name      = 'Dynamic Environment Manager'
        Service   = @('VMware DEM', 'FlexEngine')
        Pattern   = $DemPattern
        Build     = { param($path, $log) Get-DemArguments -InstallerPath $path -LogFile $log }
        Direct    = $false
    }
    @{
        Key       = 'Fslogix'
        Name      = 'FSLogix'
        Service   = 'frxsvc'
        Pattern   = $FslogixPattern
        Build     = { param($path, $log) $FslogixArgs }
        Direct    = $true
        PostBuild = { Set-FslogixProfileConfiguration }
    }
    @{
        Key       = 'AppVolumes'
        Name      = 'App Volumes Agent'
        Service   = 'svservice'
        Pattern   = $AppVolumesPattern
        Build     = {
            param($path, $log)
            # ENFORCESSLCERTIFICATEVALIDATION, all caps. The registry value the installer writes is
            # spelled EnforceSSLCertificateValidation, but the MSI property that feeds it is the
            # uppercase one -- and only uppercase properties are public, so the mixed-case spelling
            # is silently ignored on the command line and certificate validation stays on.
            "/i `"$path`" /qn /norestart MANAGER_ADDR=$AppVolumesManager MANAGER_PORT=$AppVolumesPort ENFORCESSLCERTIFICATEVALIDATION=0 /l*v `"$log`""
        }
        Direct    = $false
    }
)

foreach ($agent in $catalogue) {
    if ($Include -notcontains $agent.Key) {
        Write-Step "$($agent.Name) -- not selected." -Status SKIP
        Add-Result -Name $agent.Name -Status 'Skipped' -Detail 'not selected'
        continue
    }

    # Idempotency: presence of the service means the agent is already in the image.
    $existing = @($agent.Service) | ForEach-Object { Get-Service -Name $_ -ErrorAction SilentlyContinue } | Where-Object { $_ }
    if ($existing) {
        Write-Step "$($agent.Name) -- already installed." -Status SKIP
        Add-Result -Name $agent.Name -Status 'Skipped' -Detail 'already installed'
        if ($agent.PostBuild) { & $agent.PostBuild }
        continue
    }

    if ($agent.Key -eq 'AppVolumes' -and -not $AppVolumesManager) {
        Write-Step 'App Volumes Agent -- no manager address supplied, skipping.' -Status WARN
        Add-Result -Name $agent.Name -Status 'Skipped' -Detail 'no manager address'
        continue
    }

    $installer = Find-Installer -Root $root -Pattern $agent.Pattern -Name $agent.Name
    if (-not $installer) {
        Add-Result -Name $agent.Name -Status 'Missing' -Detail "no match for '$($agent.Pattern)'"
        continue
    }

    $installer = Copy-InstallerLocally -Path $installer -Name $agent.Name

    $logFile = Join-Path $LogPath "$($agent.Key).log"
    $arguments = & $agent.Build $installer $logFile

    $installed = if ($agent.Direct) {
        Invoke-Installer -Name $agent.Name -FilePath $installer -Arguments $arguments -LogFile $logFile
    }
    else {
        Invoke-Installer -Name $agent.Name -FilePath 'msiexec.exe' -Arguments $arguments -LogFile $logFile
    }

    if ($installed -and $agent.PostBuild) { & $agent.PostBuild }
}

Disconnect-InstallerSource

# Staged installers are build scratch, not part of the image. Several hundred megabytes of them.
foreach ($file in $script:CopiedMedia) {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output '  Summary'
$script:Results | ForEach-Object { Write-Output "    $($_.Agent): $($_.Status) ($($_.Detail))" }
Write-Output ''

# Fail the provisioner only on a genuine installer failure. A missing optional installer is
# reported but does not stop the build, so a share that is short one agent still yields an image.
$failed = @($script:Results | Where-Object { $_.Status -eq 'Failed' })
if ($failed) {
    throw "$($failed.Count) agent installer(s) failed: $($failed.Agent -join ', ')"
}
