---
icon: octicons/package-24
---

# Installer Sources

Both the Horizon and SDS distributions fetch their installers at build time rather than baking
them into the repository. Three transports are supported. They differ only in how the guest
reaches the files — everything after that (pattern matching, copying locally, installing, cleanup)
is identical.

Pick the one your **build network** can reach. That is the single most common cause of a failed
build, and it is worth stating plainly: the machine running Packer and the guest being built are
usually on different subnets with different firewall rules. Verify from the guest's network, not
from the Packer host.

| | SMB | NFS | vSphere Datastore |
|---|---|---|---|
| Guest needs | TCP 445 | TCP/UDP 111, mountd, TCP 2049 | TCP 443 to vCenter |
| Credentials | Share account | None (anonymous) | vCenter account |
| Extra Windows feature | No | **Yes** — NFS client + reboot | No |
| Build time cost | none | ~2 min for the feature install and restart | none |
| Fragility | low | highest — most moving parts | low |

## SMB

```hcl
horizon_agent_source_type     = "Smb"
horizon_agent_source_path     = "\\\\10.0.0.201\\software\\Omnissa"
horizon_agent_source_username = "image"
```

```shell
export PKR_VAR_horizon_agent_source_password='...'
```

Note the escaping: HCL needs `\\\\` for each literal backslash, so a UNC path starts with four.

!!! danger "Never assign the password in the var file"

    Not even to `""`. Packer ranks var-files **above** `PKR_VAR_` environment variables, so an
    empty assignment silently beats the environment and the mount fails with *"Cannot bind
    argument to parameter 'String' because it is an empty string"*. Leave the line commented out.

## NFS

```hcl
horizon_agent_source_type     = "Nfs"
horizon_agent_source_path     = "10.0.0.201:/mnt/tank/software/Omnissa"
horizon_agent_source_anon_uid = "3000"
horizon_agent_source_anon_gid = "0"
```

The most demanding option. All of the following must be true:

- **The export permits the build VM's subnet.** Not the subnet of the machine running Packer.
- **The export permits anonymous access.** The guest mounts with `mount.exe -o anon`.
- **The anonymous UID can read the files.** Windows presents UID `-2` (4294967294), *not* the
  Linux `nobody` (65534). An export owned by a specific UID rejects it, and the symptom is
  misleading: the mount succeeds and the tree then reads as `Access to the path 'Z:\' is denied`
  with zero files enumerated. Set `horizon_agent_source_anon_uid` to a UID that can read — `ls -ln`
  on the share shows the owner.
- **TCP and UDP 111 are open**, plus **mountd's port**, plus **2049**. NFSv3 cannot locate mountd
  without the portmapper; 2049 alone is not enough and fails with `Network Error - 53`, which
  reads like an unreachable server.
- **mountd's port is pinned.** It binds a random port on every NFS service restart, so a firewall
  rule written against today's number breaks the next time storage reboots. Pin it
  (`mountd(8) bind port`) and open that.

The build enables `ServicesForNFS-ClientOnly` and **restarts the guest** before mounting, because
the client's redirector is not usable until it does. Those two provisioners run only for this
source type.

Verify from a host on the build VM's subnet:

```shell
rpcinfo -p <nas>          # confirm mountd is on the pinned port
showmount -e <nas>        # confirm the export is visible
```

## vSphere Datastore

```hcl
horizon_agent_source_type  = "Datastore"
horizon_datastore_vcenter  = ""                    # blank = reuse vsphere_endpoint
horizon_datastore_username = "svc-packer-ds@vsphere.local"
horizon_datastore_name     = "nautilus-software"
horizon_datastore_path     = "Omnissa"
```

```shell
export PKR_VAR_horizon_datastore_password='...'
```

Installers are downloaded from vCenter's datastore file endpoint over HTTPS:

```
https://<vcenter>/folder/<path>/<file>?dcPath=<datacenter>&dsName=<datastore>
```

The guest needs **only TCP 443 to vCenter** — no share, no NFS client, no optional Windows
feature, no mounted media, no anonymous UID mapping. Only the files a given build needs are
downloaded, not the whole tree.

!!! note "The account reaches the guest"

    Grant only **Datastore → Browse datastore** and **Datastore → Low level file operations** on
    the datastore, plus **Read-only** on the datacenter so `dcPath` resolves. Do not use an
    administrator: this credential is handed to the image being built.

!!! tip "Often the same files you already share"

    An NFS datastore is frequently the same dataset exported over SMB or NFS. If so, there is
    nothing to synchronise — drop an installer on the share and every source type sees it.

Downloads use `curl.exe` (shipped in Windows 11) rather than `Invoke-WebRequest`, because .NET's
certificate handling proved unreliable against a self-signed vCenter certificate: the legacy
`CertificatePolicy` hung, and `ServerCertificateValidationCallback` closed every connection —
even when the working policy was also set. `vsphere_insecure_connection` drives curl's `-k`.

## Auto

```hcl
horizon_agent_source_type = "Auto"
```

Tries Datastore, then SMB, then NFS, using whichever settings are present. Convenient for a lab,
but it makes a misconfiguration look like a different failure — a wrong SMB password becomes "no
installers found" after it silently falls through. Prefer naming the source type explicitly so a
failure names its real cause.

## Failing fast

Whichever transport you choose, the first provisioner is a pure TCP reachability check — 445 for
SMB, 111 and 2049 for NFS, 443 for Datastore — that runs before the operating system is patched.
A source the guest cannot reach fails in minutes with the port named, instead of stalling at a
mount forty minutes later.

## SDS

The SDS distribution takes the same three transports with `sds_`-prefixed variables:

```hcl
sds_source_type     = "Smb"
sds_source_path     = "\\\\10.0.0.201\\software"
sds_source_username = "image"
```

```shell
export PKR_VAR_sds_source_password='...'
```

Its source path points at the root containing every application in `sds_applications`, since
patterns are matched recursively.

!!! warning "SDS builds on its own network"

    `config/windows-sds-11.pkrvars.hcl` sets `vsphere_network = "SDS - VLAN 100"`, so SDS guests
    do not inherit the Horizon build network. Firewall rules opened for one do not apply to the
    other.
