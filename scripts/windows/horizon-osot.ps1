# © Broadcom. All Rights Reserved.
# The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-2-Clause

<#
    .SYNOPSIS
    Runs one action of the Omnissa OS Optimization Tool (OSOT) during a Packer build.

    .DESCRIPTION
    Wraps the OSOT command-line interface so a Packer provisioner can drive a single action per
    invocation. The build calls this script once per phase:

      Optimize   -> apply the optimization template
      Finalize   -> run selected finalization steps
      Generalize -> sysprep the image (full-clone template source only, and always last)

    Ordering constraint that drives this design: Generalize is sysprep. It wipes the autologon,
    resets Windows Remote Management, and returns the machine to OOBE. Packer cannot reconnect
    afterwards, so Generalize must be the final provisioner in the chain. The interactive
    workflow's order (Generalize, then AppxCleanup, then Finalize) cannot be reproduced inside a
    single Packer run -- Finalize and the AppX cleanup are moved ahead of Generalize instead.

    .PARAMETER Action
    Which OSOT action to run.

    .PARAMETER OsotPath
    Directory containing the OSOT executable.

    .PARAMETER OsotExecutable
    Full path to the OSOT executable. When omitted, the script searches -OsotPath. The binary has
    been named VMwareOSOptimizationTool.exe historically; Omnissa-branded builds may differ, so
    discovery is by pattern rather than a fixed name.

    .PARAMETER Template
    Optimization template passed to OSOT as -t. Omit to use the tool's default for the detected OS.

    .PARAMETER OptimizationLevel
    Value for OSOT's -optimize argument: all-item or no-item.

    .PARAMETER FinalizeSteps
    Comma-separated OSOT finalize step numbers, or 'all'.

    Deliberately NOT defaulted to 'all'. OSOT's finalize set includes a step that releases the
    IP address; running it mid-build severs Windows Remote Management and strands Packer at its
    connection timeout with no output explaining why. The default here is the two steps whose
    numbering is publicly documented -- 0 (NGEN .NET precompile) and 1 (DISM side-by-side
    component cleanup). Add further steps only once you have confirmed what they do in your OSOT
    build; 'all' is safe only if the image is being finalized outside of a Packer run.

    .PARAMETER Shutdown
    Pass -shutdown to OSOT. Expected for Generalize, where losing the guest is the intended
    end state.

    .PARAMETER WrapperScript
    Optional path to a site-supplied OSOT wrapper (for example Invoke-HorizonOSOT.ps1). When
    present, this script delegates to it and passes -Action through, so an existing wrapper that
    already encodes the OSOT download, template handling, and finalize step mapping stays
    authoritative rather than being reimplemented here.

    .EXAMPLE
    .\horizon-osot.ps1 -Action Optimize -OsotPath C:\Tools\OSOT

    .EXAMPLE
    .\horizon-osot.ps1 -Action Generalize -Shutdown

    .NOTES
    Reference: https://techzone.omnissa.com/resource/using-automation-create-optimized-windows-images-horizon-vms
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Optimize', 'Finalize', 'Generalize')]
    [string]$Action,

    [string]$OsotPath = 'C:\Tools\OSOT',
    [string]$OsotExecutable,
    [string]$Template,

    # The only values OSOT accepts for -optimize. 'all-item' selects every item in the default or
    # selected template; 'no-item' selects none. Categories such as "recommended" live inside the
    # templates, not on the command line -- to apply a subset, supply a template with -t.
    [ValidateSet('all-item', 'no-item')]
    [string]$OptimizationLevel = 'all-item',

    [string]$FinalizeSteps = '0,1',

    [switch]$Shutdown,

    [string]$WrapperScript,

    [string]$LogPath = 'C:\Windows\Temp\horizon-osot',

    # Ceiling on a single OSOT action. Optimize is the long one; Generalize ends the guest anyway.
    [int]$TimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'

# Environment-variable fallbacks, supplied by the Packer provisioner. Only -Action is passed on
# the command line, so the provisioner definitions stay readable and free of quoting hazards.
# An explicitly bound parameter always wins.
foreach ($map in @(
        @{ P = 'OsotPath';          V = 'OsotPath';          E = 'HORIZON_OSOT_PATH' }
        @{ P = 'OsotExecutable';    V = 'OsotExecutable';    E = 'HORIZON_OSOT_EXECUTABLE' }
        @{ P = 'Template';          V = 'Template';          E = 'HORIZON_OSOT_TEMPLATE' }
        @{ P = 'OptimizationLevel'; V = 'OptimizationLevel'; E = 'HORIZON_OSOT_LEVEL' }
        @{ P = 'FinalizeSteps';     V = 'FinalizeSteps';     E = 'HORIZON_OSOT_FINALIZE_STEPS' }
        @{ P = 'WrapperScript';     V = 'WrapperScript';     E = 'HORIZON_OSOT_WRAPPER' }
    )) {
    if ($PSBoundParameters.ContainsKey($map.P)) { continue }
    $value = [Environment]::GetEnvironmentVariable($map.E)
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    Set-Variable -Name $map.V -Value $value
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
    # Write-Host so this can never be captured as a function's return value. See horizon-agents.ps1.
    Write-Host "  $prefix $Message"
}

Write-Output ''
Write-Output "  Omnissa OS Optimization Tool -- $Action"
Write-Output ''

if (-not (Test-Path $LogPath)) { New-Item -Path $LogPath -ItemType Directory -Force | Out-Null }

# A site-supplied wrapper wins. It already knows this environment's OSOT version, template, and
# finalize step numbering, none of which are stable across OSOT builds.
if ($WrapperScript) {
    if (-not (Test-Path $WrapperScript)) {
        throw "WrapperScript was specified but does not exist: $WrapperScript"
    }
    Write-Step "Delegating to site wrapper: $WrapperScript" -Status RUN
    & $WrapperScript -Action $Action -OSOTPath $OsotPath -NonInteractive
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "$WrapperScript exited with code $LASTEXITCODE."
    }
    Write-Step "$Action complete (via wrapper)." -Status OK
    return
}

# Locate the executable. Name varies between VMware- and Omnissa-branded releases.
if (-not $OsotExecutable) {
    if (-not (Test-Path $OsotPath)) {
        throw "OSOT path not found: $OsotPath. Stage OSOT there, or pass -OsotExecutable or -WrapperScript."
    }
    $candidate = Get-ChildItem -Path $OsotPath -Filter '*OSOptimizationTool*.exe' -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object -Property @{ Expression = { try { [version]$_.VersionInfo.FileVersion } catch { [version]'0.0.0.0' } } } -Descending |
        Select-Object -First 1
    if (-not $candidate) {
        throw "No OSOT executable matching '*OSOptimizationTool*.exe' found under $OsotPath."
    }
    $OsotExecutable = $candidate.FullName
}
Write-Step "Executable: $OsotExecutable" -Status Info

$report = Join-Path $LogPath "osot-$($Action.ToLower()).log"
$arguments = @()

switch ($Action) {
    'Optimize' {
        # -o IS the abbreviation for -optimize and takes all-item or no-item. Passing both, or any
        # other value, makes OSOT print "Invalid arguments" and then EXIT 0 -- so the exit code
        # alone cannot tell you it did nothing. The console check below is what catches that.
        $arguments += @('-optimize', $OptimizationLevel)
        if ($Template) { $arguments += @('-t', $Template) }
        $arguments += @('-r', "`"$report`"")
    }
    'Finalize' {
        if ($FinalizeSteps -eq 'all') {
            # Permitted, but call it out: 'all' includes the networking step, and if this runs
            # under Packer the build will lose Windows Remote Management here.
            Write-Step "FinalizeSteps='all' includes the IP release step; Packer will lose the guest." -Status WARN
            $arguments += @('-finalize', 'all')
        }
        else {
            $steps = $FinalizeSteps -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if (-not $steps) { throw "FinalizeSteps produced no usable step numbers: '$FinalizeSteps'" }
            Write-Step "Finalize steps: $($steps -join ', ')" -Status Info
            $arguments += '-finalize'
            $arguments += $steps
        }
    }
    'Generalize' {
        $arguments += '-generalize'
    }
}

if ($Shutdown) { $arguments += '-shutdown' }

Write-Step "Running: $(Split-Path $OsotExecutable -Leaf) $($arguments -join ' ')" -Status RUN

# Run through a .cmd wrapper with a bounded wait, for the same two reasons as the agent installer.
#
# Quoting: -ArgumentList re-quotes on its way to CreateProcess, which mangles the quoted report
# path. cmd takes the line exactly as written, and the file is left behind so the real command is
# visible after a failure.
#
# Timeout: Start-Process -Wait has no ceiling. OSOT has been observed exiting without writing its
# report while the wait never returned -- the build then sits silently on a healthy, idle guest
# until someone notices hours later. A ceiling turns that into a clear failure.
$wrapper = Join-Path $LogPath "osot-$($Action.ToLower()).cmd"
$consoleLog = Join-Path $LogPath "osot-$($Action.ToLower())-console.log"
Set-Content -LiteralPath $wrapper -Encoding ASCII -Value @"
@echo off
"$OsotExecutable" $($arguments -join ' ') > "$consoleLog" 2>&1
exit /b %ERRORLEVEL%
"@
Write-Step "Wrapper: $wrapper" -Status Info

try {
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', "`"$wrapper`"" -PassThru -ErrorAction Stop
    if (-not $process.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        try { $process.Kill() } catch { }
        throw "OSOT $Action did not finish within $TimeoutMinutes minutes. Report: $report"
    }
    $code = $process.ExitCode
}
catch {
    # Generalize with -shutdown tears the machine down underneath us. Losing the process here is
    # the expected outcome, not a failure.
    if ($Action -eq 'Generalize') {
        Write-Step "Lost the guest during Generalize, which is expected: $($_.Exception.Message)" -Status OK
        return
    }
    throw
}

# The exit code is not sufficient: OSOT returns 0 even when it rejects the command line and does
# nothing at all. Echo what it actually said, and fail on the rejection message.
if (Test-Path $consoleLog) {
    $console = Get-Content -LiteralPath $consoleLog -Raw -ErrorAction SilentlyContinue
    if ($console) {
        foreach ($line in ($console -split "`r?`n" | Where-Object { $_.Trim() })) {
            Write-Step "  $line" -Status Info
        }
        if ($console -match 'Invalid arguments') {
            throw "OSOT rejected the command line for $Action and did nothing. It exits 0 regardless, so this is detected from its output. Console: $consoleLog"
        }
    }
}

switch ($code) {
    0     { Write-Step "$Action complete." -Status OK }
    3010  { Write-Step "$Action complete; reboot required (3010)." -Status OK }
    default {
        if ($Action -eq 'Generalize') {
            Write-Step "Generalize returned $code; the guest is shutting down." -Status WARN
            return
        }
        throw "OSOT $Action exited with code $code. Report: $report"
    }
}
