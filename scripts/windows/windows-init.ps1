# © Broadcom. All Rights Reserved.
# The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-2-Clause

<#
    .DESCRIPTION
    Enables Windows Remote Management on Windows builds.
#>

$ErrorActionPreference = 'Stop'

# Prevent and remove BitLocker automatic device encryption.
# Windows 11 24H2 and later enable device encryption during the out-of-box experience on machines with a
# TPM and Secure Boot. Sysprep refuses to generalize an encrypted OS volume and fails with 0x80310039 when
# the template is cloned and customized. This runs before Windows Remote Management is configured so that
# the volume is fully decrypted before Packer connects and shuts the machine down.
# Keep the guest awake for the entire build.
#
# A sleeping guest drops off the network, and every symptom of that looks like a broken build:
# Packer fails with "no route to host", VMware Tools stops reporting, the console goes black, and
# CPU falls to idle -- while the operating system is perfectly healthy and wakes on a keypress.
# Long silent stretches (Windows Update, a 250 MB agent install, a provisioner pause) are exactly
# when it happens. Timeouts of 0 mean never.
Write-Output 'Disabling sleep, hibernation, and display timeouts...'
foreach ($setting in @('standby-timeout-ac', 'standby-timeout-dc', 'hibernate-timeout-ac', 'hibernate-timeout-dc',
                       'monitor-timeout-ac', 'monitor-timeout-dc', 'disk-timeout-ac', 'disk-timeout-dc')) {
    & powercfg.exe /change $setting 0 2>&1 | Out-Null
}
& powercfg.exe /hibernate off 2>&1 | Out-Null
# Modern Standby ignores the classic timeouts; this opts the platform out of it.
#
# No New-Item here. On an existing key, New-Item -Force DELETES AND RECREATES it -- run against a
# live system key such as Control\Power that leaves the key marked for deletion, breaks the power
# subsystem, and aborts the rest of this script (ErrorActionPreference is Stop above), so Windows
# Remote Management never gets configured and the build hangs waiting to connect. Control\Power
# always exists; just set the value.
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'PlatformAoAcOverride' -Value 0 -Type DWord -Force

Write-Output 'Preventing BitLocker automatic device encryption...'
try {
    # Create only when absent, never -Force over an existing key. See the note above.
    if (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker')) {
        New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' -Force | Out-Null
    }
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' -Name PreventDeviceEncryption -Value 1 -Type DWord

    if (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction SilentlyContinue
        if ($volume -and $volume.VolumeStatus -ne 'FullyDecrypted') {
            Write-Output "Decrypting $env:SystemDrive. This may take several minutes..."
            Disable-BitLocker -MountPoint $env:SystemDrive | Out-Null
            $timeout = (Get-Date).AddMinutes(60)
            do {
                Start-Sleep -Seconds 15
                $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive
                Write-Output "Encryption remaining: $($volume.EncryptionPercentage)%"
            } while ($volume.VolumeStatus -ne 'FullyDecrypted' -and (Get-Date) -lt $timeout)

            if ($volume.VolumeStatus -ne 'FullyDecrypted') {
                Write-Warning "$env:SystemDrive did not finish decrypting within 60 minutes. Sysprep may fail when the template is cloned."
            } else {
                Write-Output "$env:SystemDrive is fully decrypted."
            }
        }
    }
} catch {
    # Never block the remainder of this script. Windows Remote Management must come up or the build will
    # stall at the Packer connection timeout with no indication of why.
    Write-Warning "Unable to disable BitLocker: $($_.Exception.Message)"
}

# Set network connections provile to Private mode.
Write-Output 'Setting the network connection profiles to Private...'
$connectionProfile = Get-NetConnectionProfile
While ($connectionProfile.Name -eq 'Identifying...') {
    Start-Sleep -Seconds 10
    $connectionProfile = Get-NetConnectionProfile
}
Set-NetConnectionProfile -Name $connectionProfile.Name -NetworkCategory Private

# Set the Windows Remote Management configuration.
Write-Output 'Setting the Windows Remote Management configuration...'
winrm quickconfig -quiet
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'

# Allow Windows Remote Management in the Windows Firewall.
Write-Output 'Allowing Windows Remote Management in the Windows Firewall...'
netsh advfirewall firewall set rule group="Windows Remote Administration" new enable=yes
netsh advfirewall firewall set rule name="Windows Remote Management (HTTP-In)" new enable=yes action=allow

# Reset the autologon count.
# Reference: https://docs.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon-logoncount#logoncount-known-issue
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoLogonCount -Value 0
