---
icon: octicons/stack-24
---

# Omnissa Horizon Golden Images

Builds a Windows 11 golden image for Omnissa Horizon: optimized with the OS Optimization Tool
(OSOT), with the Horizon agent stack installed, ready to hand to a desktop pool.

## What Gets Built

The `Horizon Desktop` distribution produces two artifacts from one provisioning chain. Pick the
edition that matches how your pools consume the image.

| Edition | Artifact | Generalized | Use for |
|---|---|---|---|
| `Instant Clone` | Powered-off VM with a snapshot | **No** | Instant-clone pools |
| `Full Clone` | vSphere template | Yes (OSOT Generalize) | Full-clone pools, guest customization |
| `Both` | Both of the above | — | Environments running both pool types |

!!! important "Instant-clone images are not sysprepped"

    Horizon assigns identity to instant clones with ClonePrep, from a snapshot of a
    **non-generalized** virtual machine. Generalizing that image breaks it. The `Instant Clone`
    edition therefore runs OSOT Optimize and Finalize but never Generalize. Only the `Full Clone`
    edition is sysprepped.

## Build

```shell
./build.sh --os "Windows" --dist "Horizon Desktop" --version "11" --edition "Both" --auto-continue
```

Or select `Horizon Desktop` from the interactive menu.

## Provisioning Order

The order is load bearing and not the same as the order you would follow by hand:

```
source check → ansible → [NFS client + restart] → stage OSOT → agents → OSOT Optimize →
AppX cleanup → OSOT Finalize → OSOT Generalize
```

The NFS client steps run only when `horizon_agent_source_type = "Nfs"`.

Agents install **before** optimization, which is Omnissa's documented order: Horizon Agent first,
then Dynamic Environment Manager, FSLogix, and App Volumes last, and only then OSOT. Optimizing
first lets the agent installers re-enable services OSOT has just disabled, and denies OSOT sight
of the agents it carries optimizations for.

!!! warning "Do not move the NFS client install ahead of the patching pass"

    Enabling an optional Windows feature is a servicing operation. Doing it before Windows Update
    runs left the guest unable to restore Windows Remote Management across the post-update reboot,
    and the build died with the host `UNREACHABLE` at the same point on two consecutive runs.

    The source check that runs first is deliberately a pure TCP reachability test — 111 and 2049
    for NFS, 445 for SMB. It catches a misconfigured share in the first minutes without touching
    servicing.

OSOT Generalize is Sysprep. It wipes the autologon, resets Windows Remote Management, and returns
the guest to OOBE, so **Packer cannot reconnect after it runs**. Anything that must touch the image
has to happen first. The interactive workflow's order — Generalize, then AppX cleanup, then
Finalize — cannot be reproduced inside a single Packer run, so Finalize and the AppX cleanup are
moved ahead of Generalize.

## Configuration

Everything about how the template is built lives in **one file**:

```
config/horizon.pkrvars.hcl
```

Which agents to install, where their installers come from, how each is configured, and how OSOT
runs. The per-build file (`config/windows-horizon-11.pkrvars.hcl`) covers only the operating
system, its media, and the virtual hardware.

```hcl
horizon_install_agent      = true
horizon_install_dem        = true
horizon_install_fslogix    = true
horizon_install_appvolumes = true

horizon_osot_enabled   = true   # false for an agents-only image
horizon_agents_enabled = true   # false for an optimization-only image
```

## Agent Installation

Agents install in a fixed order regardless of which toggles are set:

1. Horizon Agent
2. Dynamic Environment Manager (FlexEngine)
3. FSLogix
4. App Volumes Agent — **always last**

Each install is skipped if the corresponding service already exists, so a re-run against a
partially built image is safe.

### Installer Discovery

Installers are located by **pattern, not by version**. Where several candidates match, the highest
file version wins. Dropping a newer agent build onto the share is picked up with no configuration
change.

```hcl
horizon_agent_pattern      = "*Horizon-Agent*.exe"
horizon_dem_pattern        = "*Dynamic*Environment*Manager*.msi"
horizon_fslogix_pattern    = "FSLogixAppsSetup.exe"
horizon_appvolumes_pattern = "*App*Volumes*Agent*.msi"
```

### Installer Source

Set `horizon_agent_source_type` to one of:

| Value | Behavior |
|---|---|
| `Auto` | Tries `Datastore` first (no credentials required), then `Smb`, then `Nfs` |
| `Smb` | Mounts `horizon_agent_source_path` as a UNC path |
| `Nfs` | Mounts an NFS export. Enables the Windows NFS client and restarts the guest first |
| `Datastore` | Scans attached CD/DVD drives for an ISO containing the installers |

```hcl
# SMB
horizon_agent_source_type = "Smb"
horizon_agent_source_path = "\\\\nas.example.com\\software\\omnissa"

# NFS — costs an extra Windows feature install and a restart that SMB does not
horizon_agent_source_type = "Nfs"
horizon_agent_source_path = "nas.example.com:/volume1/software/omnissa"
```

#### NFS Prerequisites

The `Nfs` source type has requirements that are easy to miss and produce failures that read like
something else. Confirm all of these before a build:

| Requirement | Why |
|---|---|
| Export permits the **build VM's subnet** | Not the subnet of the machine running Packer. The two are usually different |
| Export permits **anonymous** access | The guest mounts with `mount.exe -o anon`. Note the Windows anonymous UID is `-2` (4294967294), *not* the Linux `nobody` (65534) — an export mapped for one may reject the other |
| TCP **and** UDP **111** open | Portmapper. The Windows client speaks NFSv3, which cannot locate mountd without it |
| mountd's port **pinned and open** | mountd binds a random port on every NFS service restart. Pin it (`mountd(8) bind port`) or the build breaks the next time storage reboots |
| TCP **2049** open | NFS itself |

Verify from a host on the build VM's subnet, not from the Packer host:

```shell
rpcinfo -p <nas>                     # confirm mountd is on the pinned port
showmount -e <nas>                   # confirm the export is visible
```

!!! note "The NFS client needs a restart before it works"

    Enabling `ServicesForNFS-ClientOnly` installs a redirector driver that is not usable until the
    guest restarts. Mounting in the same session fails with `Network Error - 53`, which reads like
    an unreachable server rather than a pending restart. The build therefore enables the feature
    and restarts before anything attempts a mount — two provisioners that run only for the `Nfs`
    source type.

    The guest mounts with `mount.exe -o anon`, with no credentials, so the export must permit the
    build subnet and allow anonymous read. `Smb` avoids the feature install, the restart, and the
    anonymous-access requirement.

!!! warning "Do not assign the password in the configuration file at all"

    Packer ranks var-files **above** `PKR_VAR_` environment variables, so
    `horizon_agent_source_password = ""` in `horizon.pkrvars.hcl` silently overrides the
    environment and the SMB mount fails with *"Cannot bind argument to parameter 'String' because
    it is an empty string"*. Leave the assignment out entirely — the variable defaults to `""` —
    and export it:

    ```shell
    export PKR_VAR_horizon_agent_source_password='...'
    ```

    The value reaches the guest as an environment variable, never on a command line, so it does
    not appear in the guest process list or the Packer log.

## Per-Agent Settings

### Horizon Agent

`horizon_agent_vc_managed` maps to `VDM_VC_MANAGED_AGENT` and decides whether the Connection
Server settings are used at all:

```hcl
# Automated pools managed by vCenter Server. No registration at install time.
horizon_agent_vc_managed = true

# Unmanaged or manual pools. Registers with the Connection Server during installation.
horizon_agent_vc_managed           = false
horizon_connection_server          = "cs01.example.com"
horizon_connection_server_username = "administrator@example.com"

horizon_agent_features = "Core,USB,ClientDriveRedirection,PrintRedir,NGVC"
```

#### ADDLOCAL Feature Reference

Read directly from the Feature table of `Omnissa-Horizon-Agent-x86_64-2603-8.18.0`. Names are case
sensitive, and an unrecognized name aborts the installation. `Core` is mandatory whenever
`ADDLOCAL` is used. Naming any feature replaces the installer's default selection, so list
everything you want rather than only the extras.

"Default" is relative to the installer's `INSTALLLEVEL` of 100 — a feature installs without being
named when its MSI level is 100 or lower.

| Feature | Description | Level | Default |
|---|---|---|---|
| `Core` | Horizon Agent core. Always required | 1 | on |
| `ClientDriveRedirection` | Client Drive Redirection | 1 | on |
| `HznVaudio` | Horizon Audio | 1 | on |
| `NGVC` | Instant Clone Agent | 1 | on |
| `RDP` | Enable RDP (hidden in the interactive installer) | 1 | on |
| `HelpDesk` | Help Desk Plugin for Horizon Agent | 100 | on |
| `PrintRedir` | Horizon Integrated Printing | 100 | on |
| `RTAV` | Real-Time Audio-Video | 100 | on |
| `StorageDriveRedir` | Storage Drive Redirection | 100 | on |
| `TSMMR` | Windows Media multimedia redirection | 100 | on |
| `USB` | USB Redirection | 1000 | **off** |
| `SmartCard` | Smartcard Redirection | 1000 | **off** |
| `GEOREDIR` | Geolocation Redirection | 32001 | **off** |
| `HybridLogon` | Hybrid Logon | 32001 | **off** |
| `PerfTracker` | Horizon Performance Tracker | 32001 | **off** |
| `RDSH3D` | 3D RDSH | 32001 | **off** |
| `ScannerRedirection` | Scanner Redirection | 32001 | **off** |
| `SdoSensor` | SDO Sensor Redirection | 32001 | **off** |
| `SerialPortRedirection` | Serial Port Redirection | 32001 | **off** |

Ten further features are children of `Core` and come with it rather than being selected
individually: `BellsoftJDK`, `BlastUDP`, `FIDO2Redirection`, `HznVdisplay`, `HznVidd`, `HznVidd2`,
`PSG`, `SmartCardSingleUserTS`, `UNCRedirection`, `URLRedirection`.

`ADDLOCAL=ALL` installs every feature above, including the off-by-default ones.

!!! warning "There is no feature named `InstantCloneAgent`"

    The Instant Clone Agent is `NGVC` (Next-Generation View Composer). Naming a feature that is
    not in the Feature table fails the installation rather than being ignored.

!!! note "Verify against your own agent build"

    This table is specific to 8.18.0. Feature names have changed across releases — confirm before
    upgrading the agent on the share.

!!! warning "Connection Server password"

    Export it rather than writing it to the file:

    ```shell
    export PKR_VAR_horizon_connection_server_password='...'
    ```

    The Horizon Agent installer cannot read passwords from a configuration file, so the value
    necessarily reaches the installer on its command line inside the guest. Supplying it as an
    environment variable at least keeps it out of the Packer log.

    Setting `horizon_agent_vc_managed = false` without a Connection Server, username, and password
    fails immediately with a clear message rather than letting the installer fail obscurely later.

### Dynamic Environment Manager

Computer based policies require `COMPENVCONFIGFILEPATH`, which is what
`horizon_dem_config_share` sets. Without it, FlexEngine installs but computer environment settings
are not applied — the build warns when this is left empty.

```hcl
horizon_dem_features     = "FlexEngine"          # add FlexProfilesSelfSupport if needed
horizon_dem_config_share = "\\\\fileserver.example.com\\DEMConfig\\general"
horizon_dem_license_file = "\\\\fileserver.example.com\\DEMConfig\\Omnissa DEM.lic"
horizon_dem_args         = ""                    # appended verbatim
```

#### DEM ADDLOCAL Features

From the Feature table of DEM Enterprise 2603 10.19 (`10.19.0.2389`). The MSI defines no
`INSTALLLEVEL`, so it defaults to 1 — level 1 features install by default, the Management Console
does not. Naming any feature replaces the default selection, and child features are not pulled in
by naming the parent.

| Feature | Description | Level | Default |
|---|---|---|---|
| `FlexEngine` | Agent. What a golden image needs | 1 | on |
| `FlexMigrate` | Application Migration (child of `FlexEngine`) | 1 | on |
| `FlexProfilesSelfSupport` | Self-Support (child of `FlexEngine`) | 1 | on |
| `FlexManagementConsole` | Management Console — admin workstations, not images | 100 | **off** |

#### DEM Command-Line Properties

The properties DEM 10.19 captures from the command line, per its `CustomAction` table:

| Property | Purpose |
|---|---|
| `COMPENVCONFIGFILEPATH` | Computer environment configuration path — set via `horizon_dem_config_share` |
| `COMPENVMAXCONFIGFILEPATHWAIT` | Seconds to wait for that path at boot |
| `NOADCONFIGFILEPATH` | Suppress the Active Directory based configuration path |
| `INTEGRATION_ENABLED` | Workspace ONE integration |
| `WSONE_UEM_PE_MODE` | Workspace ONE UEM profile engine mode |

!!! warning "`LICENSEFILE` no longer exists in DEM 10.19"

    It appears nowhere in that MSI's Property, CustomAction, or Registry tables. `msiexec` accepts
    it and silently ignores it. 10.19 reads its license from the configuration share instead
    (`HKLM\SOFTWARE\Immidio` → `License File` →
    `FlexRepository\AgentConfiguration\License.xml`). `horizon_dem_license_file` is kept because
    older agents honored it — on 10.19, put the `.lic` on the configuration share.

!!! note "Requires DEM Agent 2103 or later"

    `COMPENVCONFIGFILEPATH` is an installer switch introduced in DEM Agent 2103. On earlier agents
    the equivalent is configured through registry values instead.

### FSLogix

```hcl
horizon_fslogix_args         = "/install /quiet /norestart"
horizon_fslogix_profile_path = "\\\\fileserver.example.com\\Profiles"
```

FSLogix ships as a bundle rather than an MSI, so there is no `ADDLOCAL` and there are no
properties — only these switches:

| Switch | Description |
|---|---|
| `/install` | Default product installation |
| `/repair` | Repair a previous installation |
| `/uninstall` | Uninstall a previous installation |
| `/layout` | Create a local copy of the install bundle |
| `/passive` | Minimal UI, no prompts |
| `/quiet` | No UI, no prompts |
| `/norestart` | Suppress restart attempts |
| `/log <file>` | Log to a specific path. Defaults to `%TEMP%` |

Everything else is configured through the registry or Group Policy, which is why
`horizon_fslogix_profile_path` writes the profile settings directly.

When `horizon_fslogix_profile_path` is set, the image gets `Profiles\Enabled = 1` and
`Profiles\VHDLocations`. Leave it empty when Group Policy supplies those settings.

### App Volumes

```hcl
horizon_appvolumes_manager = "av01.example.com"
horizon_appvolumes_port    = 443
```

The agent is skipped when the manager is empty, even with `horizon_install_appvolumes = true`.

App Volumes Agent 4.21.2 (`4.21.2.6126`) has exactly one feature, `Agent`, so there is no
`ADDLOCAL` decision to make — it is configured entirely through MSI properties. The build sets
`MANAGER_ADDR`, `MANAGER_PORT`, and `ENFORCESSLCERTIFICATEVALIDATION=0`.

Others the agent accepts, from its `AdminProperties` list: `COMMUNICATIONTYPE`, `DIRECT` /
`DIRECTMODE`, `NONPERSISTENT`, `PACKAGEMODELOCAL`, `LICENSEKEY`, `REGISTRYLOGLEVEL`,
`REGISTRYENABLEPIILOGGING`, `AGENTDIR`, `INSTALLDIR`.

!!! warning "`ENFORCESSLCERTIFICATEVALIDATION`, not `EnforceSSLCertificateValidation`"

    The registry value the installer writes is mixed case, but the MSI property that feeds it is
    uppercase. Only uppercase properties are public, so the mixed-case spelling on a command line
    is silently ignored and certificate validation stays enabled.

## Multi-Monitor Video Settings

```hcl
vm_video_displays = 4
vm_video_ram      = 131072   # KB, not MB — this is 128 MB
```

!!! warning "`vm_video_ram` is in kilobytes"

    The project default of `4096` is **4 MB**, not 4 GB. 128 MB is `131072`.

These are the generic `vm_*` variables rather than `horizon_*` ones. They live in
`horizon.pkrvars.hcl` because that file is only loaded for Horizon builds — but `build.sh` loads
`windows-horizon-11.pkrvars.hcl` *after* it, so a value set there takes precedence.

!!! note "Whether the SVGA framebuffer still matters"

    Since Horizon 2111 the **Indirect Display Driver (IDD)** is the default graphics driver and the
    VMware SVGA driver is no longer bundled with the Horizon Agent. The IDD provides the
    framebuffer for remote sessions, so the vSphere SVGA video memory setting carries less weight
    than it did when SVGA was the only path. It still governs console access and pre-session
    display, and the SVGA driver is still required to disable Blast screen blanking or to enable
    PCoIP console access.

    Size these values against your own display count and resolution requirements rather than
    treating them as a fixed rule.

## OS Optimization Tool

OSOT is copied from the same installer source as the agents to `horizon_osot_path` (default
`C:\Tools\OSOT`) before anything else runs. The executable is found by pattern, since the binary
name is not stable across VMware- and Omnissa-branded releases.

```hcl
horizon_osot_stage_from_source = true
horizon_osot_pattern           = "*OSOptimizationTool*.exe"
```

Set `horizon_osot_stage_from_source = false` when OSOT is already baked into the image. Staging is
also skipped automatically when `horizon_osot_wrapper_script` is set, on the assumption the wrapper
stages the tool itself.

### Optimization Level

```hcl
horizon_osot_optimization_level = "all-item"
```

!!! danger "`all-item` and `no-item` are the only accepted values"

    `-o` is the **abbreviation for `-optimize`**, not a separate "level" flag, and it takes
    `all-item` (select every item in the template) or `no-item` (select none). Severity names like
    `recommended` are item *categories inside a template*, not command-line values.

    This matters more than it looks: given anything else, OSOT prints `Invalid arguments` and then
    **exits 0**. A wrong value therefore optimizes nothing while the build reports success. The
    build guards against this by reading OSOT's console output and failing on that message rather
    than trusting the exit code.

    To apply a subset of items, supply a template with `horizon_osot_template` (`-t`).

!!! note "OSOT writes no report for `-optimize`"

    `-r` is for analysis output; an optimize run leaves no report file behind. Do not treat a
    missing report as a failure. OSOT performs the work through short-lived elevated scheduled
    tasks (`Omnissa\OptimizationToolTask\ElevatedTask*`), which is what you see in its console
    output.

### Finalize Steps

```hcl
horizon_osot_finalize_steps = "0,1"
```

!!! danger "Do not set this to `all`"

    The OSOT finalize set includes a step that **releases the IP address**. Under Packer that
    severs Windows Remote Management, and the build stalls at the connection timeout with no
    output explaining why. The default covers the two steps whose numbering is publicly
    documented:

    | Step | Action |
    |---|---|
    | `0` | Native Image Generator (NGEN) .NET precompile |
    | `1` | DISM side-by-side component cleanup |

    Add further steps only after confirming what they do in your OSOT build.

### Using Your Own OSOT Wrapper

If you already maintain a wrapper that knows your OSOT version, template, and finalize step
numbering, point at it and it takes over:

```hcl
horizon_osot_wrapper_script = "C:\\Windows\\Temp\\Invoke-HorizonOSOT.ps1"
```

It is invoked as `-Action <Optimize|Finalize|Generalize> -OSOTPath <path> -NonInteractive`.

### Skipping OSOT

```hcl
horizon_osot_enabled = false   # agents only
horizon_agents_enabled = false # optimization only
```

## After the Build

**Instant clone.** Point the desktop pool at the snapshot named by `horizon_snapshot_name`
(default `horizon-golden-image`).

**Full clone.** The template is sysprepped; apply a customization specification when deploying.

!!! note "vTPM on the golden image"

    Windows 11 requires TPM 2.0 to install, so the build VM has a vTPM. Horizon adds an individual
    vTPM per clone, so review whether the golden image should retain its own before creating pools.
    This build does not remove it for you.

## Troubleshooting

**The build stalls with no output.** Most often something severed WinRM. Check that
`horizon_osot_finalize_steps` is not `all`, and remember `packer build` runs with `-on-error=ask`,
which waits at a prompt for input rather than exiting on failure. Run with
`PACKER_LOG=1 PACKER_LOG_PATH=./packer.log` and tail the log.

**Sysprep fails with `0x80310039`.** BitLocker is on for the OS volume. Windows 11 24H2 and later
enable device encryption during OOBE on machines with a TPM and Secure Boot. The answer file sets
`PreventDeviceEncryption`, and `windows-init.ps1` decrypts as a fallback — confirm both ran.

**NFS mount fails with `Network Error - 53`.** Not an unreachable server, and not a name
resolution problem. The Windows NFS client speaks NFSv3 only, which uses the **portmapper on port
111** to locate mountd — port 2049 alone is not enough. A firewall that permits 2049 but blocks
111 produces exactly this error for every mount syntax. The build reports the reachability of
111, 2049, and 445 from inside the guest when a mount fails, along with `showmount -e` output.

If 111 is blocked, the options are:

| Option | What it needs |
|---|---|
| Open the portmapper | TCP and UDP 111 from the build subnet, **plus** mountd's port. On Linux servers mountd binds a dynamic port unless pinned, so pin it and open that too |
| Use `Smb` instead | Port 445 and a service account. No optional feature, no restart, no anonymous access |
| Use `Datastore` | No network path to the file server at all — the installers ride on an ISO |
| Build on a permitted subnet | Point `vsphere_network` at a portgroup the export already allows |

**An installer was not found on a share that definitely contains it.** `Get-ChildItem -Filter`
hands the pattern to the underlying filesystem driver, and the NFS redirector ignores it — a
mounted NFS drive returns no matches for a pattern matching files that are plainly there. The
scripts enumerate and match with `-like` in PowerShell instead, which behaves identically across
SMB, NFS, and datastore sources. When a pattern matches nothing, the build prints the file count
and the first twenty paths it can actually see, which distinguishes a naming mismatch from a tree
that reads as empty because of anonymous-access mapping.

**An agent was skipped.** A missing installer warns and continues rather than failing the build.
Check the summary at the end of the agent provisioner output, and the per-installer logs in
`C:\Windows\Temp\horizon-agents`. The App Volumes Agent is skipped outright when
`horizon_appvolumes_manager` is empty.

## References

- [Manually creating optimized Windows images for Horizon VMs](https://techzone.omnissa.com/resource/manually-creating-optimized-windows-images-horizon-vms)
- [Using automation to create optimized Windows images for Horizon VMs](https://techzone.omnissa.com/resource/using-automation-create-optimized-windows-images-horizon-vms)
