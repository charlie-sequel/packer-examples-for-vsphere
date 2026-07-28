# © Broadcom. All Rights Reserved.
# The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-2-Clause

/*
    DESCRIPTION:
    Microsoft Windows 11 golden image build definition for Omnissa Horizon.
    Packer Plugin for VMware vSphere: 'vsphere-iso' builder.

    Produces two artifacts from the same provisioning chain:

      windows-horizon-instant   Snapshot-ready golden image for instant clones. Optimized, agents
                                installed, powered off, and snapshotted. Deliberately NOT
                                generalized: Horizon assigns identity per clone via ClonePrep, and
                                a sysprepped image is not what that expects.

      windows-horizon-template  vSphere template for full clones. Identical provisioning, plus
                                OSOT Generalize as the final step. Guest customization syspreps
                                each clone.

    Provisioner order is load bearing:

      source check -> ansible -> [NFS client + restart] -> stage OSOT -> agents -> OSOT Optimize
      -> AppX cleanup -> OSOT Finalize -> OSOT Generalize

    Agents before optimization is Omnissa's documented order: Horizon Agent first, then Dynamic
    Environment Manager, FSLogix, and App Volumes last, and only then OSOT. Optimizing first lets
    the agent installers re-enable services OSOT has just disabled.

    Generalize is sysprep. It wipes the autologon, resets Windows Remote Management, and returns
    the guest to OOBE, so Packer cannot reconnect afterwards. Anything that must run on the image
    has to run before it, which is why Finalize and the AppX cleanup sit ahead of Generalize here
    rather than after it as they would in an interactive, reboot-driven workflow.
*/

//  BLOCK: packer
//  The Packer configuration.

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    vsphere = {
      source  = "github.com/vmware/vsphere"
      version = ">= 1.3.0"
    }
    git = {
      source  = "github.com/ethanmdavidson/git"
      version = ">= 0.6.5"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = ">= 1.1.4"
    }
  }
}

//  BLOCK: data
//  Defines the data sources.

data "git-repository" "cwd" {}

//  BLOCK: locals
//  Defines the local variables.

locals {
  build_by          = "Built by: HashiCorp Packer ${packer.version}"
  build_date        = formatdate("YYYY-MM-DD hh:mm ZZZ", timestamp())
  build_version     = data.git-repository.cwd.head
  build_description = "Omnissa Horizon golden image\nVersion: ${local.build_version}\nBuilt on: ${local.build_date}\n${local.build_by}"
  iso_paths = {
    content_library = "${var.common_iso_content_library}/${var.iso_content_library_item}/${var.iso_file}",
    datastore       = "[${var.common_iso_datastore}] ${var.iso_datastore_path}/${var.iso_file}"
    tools           = "[] /vmimages/tools-isoimages/${var.vm_guest_os_family}.iso"
  }
  manifest_date      = formatdate("YYYY-MM-DD hh:mm:ss", timestamp())
  manifest_path      = "${path.cwd}/manifests/"
  manifest_output    = "${local.manifest_path}${local.manifest_date}.json"
  ovf_export_path    = "${path.cwd}/artifacts/"
  vm_name_instant    = "${var.vm_guest_os_family}-horizon-${var.vm_guest_os_version}-instant-${local.build_version}"
  vm_name_template   = "${var.vm_guest_os_family}-horizon-${var.vm_guest_os_version}-template-${local.build_version}"
  bucket_name        = replace("${var.vm_guest_os_family}-horizon-${var.vm_guest_os_version}", ".", "")
  bucket_description = "Omnissa Horizon golden image: ${var.vm_guest_os_family} ${var.vm_guest_os_name} ${var.vm_guest_os_version}"

  // Configuration handed to the guest scripts as environment variables. Several of these values
  // contain embedded quotes that would not survive a round trip through a PowerShell
  // execute_command, and the share password must stay out of the guest process list.
  //
  // Every provisioner that overrides execute_command must keep {{.Vars}} in it. Packer injects
  // environment_vars only at that placeholder, so an execute_command without it runs the script
  // with none of the configuration below and the script silently falls back to its defaults.
  osot_env = [
    "HORIZON_OSOT_PATH=${var.horizon_osot_path}",
    "HORIZON_OSOT_TEMPLATE=${var.horizon_osot_template}",
    "HORIZON_OSOT_LEVEL=${var.horizon_osot_optimization_level}",
    "HORIZON_OSOT_FINALIZE_STEPS=${var.horizon_osot_finalize_steps}",
    "HORIZON_OSOT_WRAPPER=${var.horizon_osot_wrapper_script}",
    "HORIZON_OSOT_PATTERN=${var.horizon_osot_pattern}",
  ]
  // Agents to install, assembled from the individual toggles so there is one obvious place to
  // turn each one on or off. Order here is irrelevant; the guest script enforces the real order.
  horizon_include = join(",", compact([
    var.horizon_install_agent ? "HorizonAgent" : "",
    var.horizon_install_dem ? "Dem" : "",
    var.horizon_install_fslogix ? "Fslogix" : "",
    var.horizon_install_appvolumes ? "AppVolumes" : "",
  ]))

  // The Windows NFS client is an optional feature that installs a redirector driver, and that
  // driver is not usable until the guest restarts. Enabling it inline and mounting in the same
  // session fails with "Network Error - 53", which reads like an unreachable server. So when the
  // installer source is NFS, enable the feature and restart before anything tries to mount.
  // SMB and Datastore sources need none of this.
  // Both sources, and a sentinel that matches no source.
  //
  // `only = []` does NOT disable a provisioner: Packer reads an empty list as "no restriction" and
  // runs it for every source, which is the opposite of the intent. A list naming a source that
  // does not exist is what actually skips it. Verified against a null builder: `only = []` ran,
  // `only = ["null.__disabled__"]` did not.
  all_targets = ["vsphere-iso.windows-horizon-instant", "vsphere-iso.windows-horizon-template"]
  no_targets  = ["vsphere-iso.__disabled__"]

  nfs_targets = var.horizon_agent_source_type == "Nfs" ? ["vsphere-iso.windows-horizon-instant", "vsphere-iso.windows-horizon-template"] : ["vsphere-iso.__disabled__"]

  agent_env = [
    "HORIZON_SOURCE_TYPE=${var.horizon_agent_source_type}",
    "HORIZON_SOURCE_PATH=${var.horizon_agent_source_path}",
    "HORIZON_SOURCE_USERNAME=${var.horizon_agent_source_username}",
    "HORIZON_VCENTER_SERVER=${var.horizon_datastore_vcenter == "" ? var.vsphere_endpoint : var.horizon_datastore_vcenter}",
    "HORIZON_VCENTER_USERNAME=${var.horizon_datastore_username}",
    "HORIZON_VCENTER_PASSWORD=${var.horizon_datastore_password}",
    "HORIZON_VCENTER_DATACENTER=${var.vsphere_datacenter}",
    "HORIZON_DATASTORE_NAME=${var.horizon_datastore_name}",
    "HORIZON_DATASTORE_PATH=${var.horizon_datastore_path}",
    "HORIZON_DATASTORE_INSECURE=${var.vsphere_insecure_connection ? "1" : "0"}",
    "HORIZON_SOURCE_ANON_UID=${var.horizon_agent_source_anon_uid}",
    "HORIZON_SOURCE_ANON_GID=${var.horizon_agent_source_anon_gid}",
    "HORIZON_SOURCE_PASSWORD=${var.horizon_agent_source_password}",
    "HORIZON_INCLUDE=${local.horizon_include}",
    "HORIZON_AGENT_PATTERN=${var.horizon_agent_pattern}",
    "HORIZON_AGENT_FEATURES=${var.horizon_agent_features}",
    "HORIZON_AGENT_VC_MANAGED=${var.horizon_agent_vc_managed ? "1" : "0"}",
    "HORIZON_CONNECTION_SERVER=${var.horizon_connection_server}",
    "HORIZON_CONNECTION_SERVER_USERNAME=${var.horizon_connection_server_username}",
    "HORIZON_CONNECTION_SERVER_PASSWORD=${var.horizon_connection_server_password}",
    "HORIZON_DEM_PATTERN=${var.horizon_dem_pattern}",
    "HORIZON_DEM_FEATURES=${var.horizon_dem_features}",
    "HORIZON_DEM_CONFIG_SHARE=${var.horizon_dem_config_share}",
    "HORIZON_DEM_LICENSE_FILE=${var.horizon_dem_license_file}",
    "HORIZON_DEM_ARGS=${var.horizon_dem_args}",
    "HORIZON_FSLOGIX_PATTERN=${var.horizon_fslogix_pattern}",
    "HORIZON_FSLOGIX_ARGS=${var.horizon_fslogix_args}",
    "HORIZON_FSLOGIX_PROFILE_PATH=${var.horizon_fslogix_profile_path}",
    "HORIZON_APPVOLUMES_PATTERN=${var.horizon_appvolumes_pattern}",
    "HORIZON_APPVOLUMES_MANAGER=${var.horizon_appvolumes_manager}",
    "HORIZON_APPVOLUMES_PORT=${var.horizon_appvolumes_port}",
  ]
}

//  BLOCK: source
//  Defines the builder configuration blocks.

source "vsphere-iso" "windows-horizon-instant" {

  // vCenter Server Endpoint Settings and Credentials
  vcenter_server      = var.vsphere_endpoint
  username            = var.vsphere_username
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  // vSphere Settings
  datacenter                     = var.vsphere_datacenter
  cluster                        = var.vsphere_cluster
  host                           = var.vsphere_host
  datastore                      = var.vsphere_datastore
  folder                         = var.vsphere_folder
  resource_pool                  = var.vsphere_resource_pool
  set_host_for_datastore_uploads = var.vsphere_set_host_for_datastore_uploads

  // Virtual Machine Settings
  vm_name              = local.vm_name_instant
  guest_os_type        = var.vm_guest_os_type
  firmware             = var.vm_firmware
  CPUs                 = var.vm_cpu_count
  cpu_cores            = var.vm_cpu_cores
  CPU_hot_plug         = var.vm_cpu_hot_add
  RAM                  = var.vm_mem_size
  RAM_hot_plug         = var.vm_mem_hot_add
  video_ram            = var.vm_video_ram
  displays             = var.vm_video_displays
  vTPM                 = var.vm_vtpm
  cdrom_type           = var.vm_cdrom_type
  disk_controller_type = var.vm_disk_controller_type
  storage {
    disk_size             = var.vm_disk_size
    disk_thin_provisioned = var.vm_disk_thin_provisioned
  }
  network_adapters {
    network      = var.vsphere_network
    network_card = var.vm_network_card
  }
  vm_version           = var.common_vm_version
  remove_cdrom         = var.common_remove_cdrom
  reattach_cdroms      = var.vm_cdrom_count
  tools_upgrade_policy = var.common_tools_upgrade_policy
  notes                = local.build_description

  // Removable Media Settings
  iso_paths = var.common_iso_content_library_enabled ? [local.iso_paths.content_library, local.iso_paths.tools] : [local.iso_paths.datastore, local.iso_paths.tools]
  cd_files = [
    "${path.cwd}/scripts/${var.vm_guest_os_family}/"
  ]
  cd_content = {
    "autounattend.xml" = templatefile("${abspath(path.root)}/data/autounattend.pkrtpl.hcl", {
      build_username       = var.build_username
      build_password       = var.build_password
      vm_inst_os_eval      = var.vm_inst_os_eval
      vm_inst_os_language  = var.vm_inst_os_language
      vm_inst_os_keyboard  = var.vm_inst_os_keyboard
      vm_inst_os_image     = var.vm_inst_os_image
      vm_inst_os_key       = var.vm_inst_os_key
      vm_guest_os_language = var.vm_guest_os_language
      vm_guest_os_keyboard = var.vm_guest_os_keyboard
      vm_guest_os_timezone = var.vm_guest_os_timezone
    })
  }

  // Boot and Provisioning Settings
  http_port_min     = var.common_http_port_min
  http_port_max     = var.common_http_port_max
  boot_order        = var.vm_boot_order
  boot_wait         = var.vm_boot_wait
  boot_command      = var.vm_boot_command
  ip_wait_timeout   = var.common_ip_wait_timeout
  ip_settle_timeout = var.common_ip_settle_timeout
  shutdown_command  = var.vm_shutdown_command
  shutdown_timeout  = var.common_shutdown_timeout

  // Communicator Settings and Credentials
  communicator   = "winrm"
  winrm_username = var.build_username
  winrm_password = var.build_password
  winrm_port     = var.communicator_port
  winrm_timeout  = var.communicator_timeout

  // Instant-clone golden images are consumed as a snapshot of a powered-off virtual machine, not
  // as a template, so this source snapshots instead of converting.
  convert_to_template = false
  create_snapshot     = true
  snapshot_name       = var.horizon_snapshot_name

  // OVF Export Settings
  dynamic "export" {
    for_each = var.common_ovf_export_enabled ? [1] : []
    content {
      name        = local.vm_name_instant
      force       = var.common_ovf_export_overwrite
      image_files = var.common_ovf_export_image_files
      options = [
        "extraconfig"
      ]
      output_directory = local.ovf_export_path
    }
  }
}

source "vsphere-iso" "windows-horizon-template" {

  // vCenter Server Endpoint Settings and Credentials
  vcenter_server      = var.vsphere_endpoint
  username            = var.vsphere_username
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  // vSphere Settings
  datacenter                     = var.vsphere_datacenter
  cluster                        = var.vsphere_cluster
  host                           = var.vsphere_host
  datastore                      = var.vsphere_datastore
  folder                         = var.vsphere_folder
  resource_pool                  = var.vsphere_resource_pool
  set_host_for_datastore_uploads = var.vsphere_set_host_for_datastore_uploads

  // Virtual Machine Settings
  vm_name              = local.vm_name_template
  guest_os_type        = var.vm_guest_os_type
  firmware             = var.vm_firmware
  CPUs                 = var.vm_cpu_count
  cpu_cores            = var.vm_cpu_cores
  CPU_hot_plug         = var.vm_cpu_hot_add
  RAM                  = var.vm_mem_size
  RAM_hot_plug         = var.vm_mem_hot_add
  video_ram            = var.vm_video_ram
  displays             = var.vm_video_displays
  vTPM                 = var.vm_vtpm
  cdrom_type           = var.vm_cdrom_type
  disk_controller_type = var.vm_disk_controller_type
  storage {
    disk_size             = var.vm_disk_size
    disk_thin_provisioned = var.vm_disk_thin_provisioned
  }
  network_adapters {
    network      = var.vsphere_network
    network_card = var.vm_network_card
  }
  vm_version           = var.common_vm_version
  remove_cdrom         = var.common_remove_cdrom
  reattach_cdroms      = var.vm_cdrom_count
  tools_upgrade_policy = var.common_tools_upgrade_policy
  notes                = local.build_description

  // Removable Media Settings
  iso_paths = var.common_iso_content_library_enabled ? [local.iso_paths.content_library, local.iso_paths.tools] : [local.iso_paths.datastore, local.iso_paths.tools]
  cd_files = [
    "${path.cwd}/scripts/${var.vm_guest_os_family}/"
  ]
  cd_content = {
    "autounattend.xml" = templatefile("${abspath(path.root)}/data/autounattend.pkrtpl.hcl", {
      build_username       = var.build_username
      build_password       = var.build_password
      vm_inst_os_eval      = var.vm_inst_os_eval
      vm_inst_os_language  = var.vm_inst_os_language
      vm_inst_os_keyboard  = var.vm_inst_os_keyboard
      vm_inst_os_image     = var.vm_inst_os_image
      vm_inst_os_key       = var.vm_inst_os_key
      vm_guest_os_language = var.vm_guest_os_language
      vm_guest_os_keyboard = var.vm_guest_os_keyboard
      vm_guest_os_timezone = var.vm_guest_os_timezone
    })
  }

  // Boot and Provisioning Settings
  http_port_min     = var.common_http_port_min
  http_port_max     = var.common_http_port_max
  boot_order        = var.vm_boot_order
  boot_wait         = var.vm_boot_wait
  boot_command      = var.vm_boot_command
  ip_wait_timeout   = var.common_ip_wait_timeout
  ip_settle_timeout = var.common_ip_settle_timeout
  shutdown_command  = var.vm_shutdown_command
  shutdown_timeout  = var.common_shutdown_timeout

  // Communicator Settings and Credentials
  communicator   = "winrm"
  winrm_username = var.build_username
  winrm_password = var.build_password
  winrm_port     = var.communicator_port
  winrm_timeout  = var.communicator_timeout

  // Template and Content Library Settings
  convert_to_template = true

  // OVF Export Settings
  dynamic "export" {
    for_each = var.common_ovf_export_enabled ? [1] : []
    content {
      name        = local.vm_name_template
      force       = var.common_ovf_export_overwrite
      image_files = var.common_ovf_export_image_files
      options = [
        "extraconfig"
      ]
      output_directory = local.ovf_export_path
    }
  }
}

//  BLOCK: build
//  Defines the builders to run, provisioners, and post-processors.

build {
  sources = [
    "source.vsphere-iso.windows-horizon-instant",
    "source.vsphere-iso.windows-horizon-template",
  ]

  //  Fail fast on an unreachable installer source. Deliberately a pure connectivity test: no
  //  optional feature, no restart, nothing that touches servicing. That keeps a misconfigured
  //  share cheap to diagnose without perturbing the operating system before it is patched.
  provisioner "powershell" {
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "$path = $env:HORIZON_SOURCE_PATH",
      "if (-not $path) { Write-Host 'No installer source configured; skipping the reachability check.'; exit 0 }",
      "$server = if ($path -match '^([^:\\\\]+):') { $Matches[1] } elseif ($path -match '^\\\\\\\\([^\\\\]+)') { $Matches[1] } else { $null }",
      "if (-not $server) { Write-Host \"Could not parse a server out of '$path'; skipping.\"; exit 0 }",
      "$ports = if ($env:HORIZON_SOURCE_TYPE -eq 'Nfs') { @(111, 2049) } elseif ($env:HORIZON_SOURCE_TYPE -eq 'Smb') { @(445) } else { @() }",
      "$failed = @()",
      "foreach ($port in $ports) {",
      "  $ok = (Test-NetConnection -ComputerName $server -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded",
      "  Write-Host \"  $${server}:$${port} reachable = $ok\"",
      "  if (-not $ok) { $failed += $port }",
      "}",
      "if ($failed) { throw \"Installer source $server is unreachable on port(s): $($failed -join ', '). NFS needs 111 (portmapper) and 2049; SMB needs 445.\" }"
    ]
    environment_vars = local.agent_env
    valid_exit_codes = [0]
    only             = var.horizon_agents_enabled || var.horizon_osot_stage_from_source ? local.all_targets : local.no_targets
  }

  //  Base operating system configuration and patching.
  //
  //  Retried because the guest can outlast Ansible's patience across the reboot at the end of
  //  Windows Update: the play aborts with the host UNREACHABLE while the guest is merely slow to
  //  bring Windows Remote Management back, and comes back healthy minutes later. `until`/`retries`
  //  inside the role cannot help -- those retry a failed task, whereas an unreachable host ends
  //  the play outright. The playbook is idempotent, so a re-run resumes rather than repeats.
  provisioner "ansible" {
    max_retries            = 2
    user                   = var.build_username
    galaxy_file            = "${path.cwd}/ansible/windows-requirements.yml"
    galaxy_force_with_deps = true
    use_proxy              = false
    playbook_file          = "${path.cwd}/ansible/windows-playbook.yml"
    roles_path             = "${path.cwd}/ansible/roles"
    ansible_env_vars = [
      "ANSIBLE_CONFIG=${path.cwd}/ansible/ansible.cfg"
    ]
    extra_arguments = [
      "--extra-vars", "use_proxy=false",
      "--extra-vars", "ansible_connection=winrm",
      "--extra-vars", "ansible_user='${var.build_username}'",
      "--extra-vars", "ansible_password='${var.build_password}'",
      "--extra-vars", "ansible_port='${var.communicator_port}'",
      "--extra-vars", "build_username='${var.build_username}'",
    ]
  }

  //  Enable the Windows NFS client, then restart so its redirector is actually usable. Only for
  //  the Nfs source type; see the nfs_targets local above for why this cannot be done inline.
  //
  //  This sits AFTER the patching pass on purpose. Enabling an optional feature is a servicing
  //  operation, and doing it beforehand made the reboot at the end of Windows Update fail to
  //  restore Windows Remote Management -- the build died with the host UNREACHABLE at the same
  //  point on two consecutive runs. Cheap source validation happens earlier instead, in the
  //  reachability check above, which touches nothing.
  provisioner "powershell" {
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "$feature = Get-WindowsOptionalFeature -Online -FeatureName 'ServicesForNFS-ClientOnly'",
      "if ($feature.State -ne 'Enabled') {",
      "  Write-Host 'Enabling ServicesForNFS-ClientOnly...'",
      "  Enable-WindowsOptionalFeature -Online -FeatureName 'ServicesForNFS-ClientOnly' -All -NoRestart | Out-Null",
      "  Enable-WindowsOptionalFeature -Online -FeatureName 'ClientForNFS-Infrastructure' -All -NoRestart -ErrorAction SilentlyContinue | Out-Null",
      "  Write-Host 'Enabled. A restart follows before any mount is attempted.'",
      "} else {",
      "  Write-Host 'NFS client already enabled.'",
      "}",
      "$key = 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default'",
      "if ($env:HORIZON_SOURCE_ANON_UID -or $env:HORIZON_SOURCE_ANON_GID) {",
      "  if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }",
      "  if ($env:HORIZON_SOURCE_ANON_UID) { Set-ItemProperty -Path $key -Name AnonymousUid -Value ([int]$env:HORIZON_SOURCE_ANON_UID) -Type DWord -Force }",
      "  if ($env:HORIZON_SOURCE_ANON_GID) { Set-ItemProperty -Path $key -Name AnonymousGid -Value ([int]$env:HORIZON_SOURCE_ANON_GID) -Type DWord -Force }",
      "  Write-Host \"NFS anonymous identity set to uid=$env:HORIZON_SOURCE_ANON_UID gid=$env:HORIZON_SOURCE_ANON_GID; the restart below applies it.\"",
      "}"
    ]
    environment_vars = local.agent_env
    valid_exit_codes = [0, 3010]
    only             = local.nfs_targets
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
    only            = local.nfs_targets
  }

  //  Stage the OS Optimization Tool from the installer source. OSOT lives alongside the agent
  //  installers, so this reuses the same source-resolution code rather than duplicating the mount
  //  logic. Deliberately the FIRST provisioner: it is the earliest point at which the installer
  //  share is touched, so a share that is unreachable, unexported to this subnet, or missing OSOT
  //  fails here in minutes instead of after the full operating system patching pass.
  provisioner "powershell" {
    script           = "${path.cwd}/scripts/windows/horizon-agents.ps1"
    environment_vars = concat(local.agent_env, local.osot_env)
    execute_command  = "powershell -ExecutionPolicy Bypass -NoProfile -Command \"& { . {{.Vars}}; & '{{.Path}}' -StageOsotOnly; exit $LastExitCode }\""
    valid_exit_codes = [0]
    only             = var.horizon_osot_enabled && var.horizon_osot_stage_from_source && var.horizon_osot_wrapper_script == "" ? local.all_targets : local.no_targets
  }

  //  Agent stack: Horizon Agent, Dynamic Environment Manager, FSLogix, then App Volumes last.
  //
  //  Launched as a scheduled task rather than run inline. The Horizon Agent installs network
  //  drivers and the guest can drop off the network while it does; an inline install dies with the
  //  connection, failing the build with "no route to host" and leaving a half-installed agent.
  //  Detached, the install belongs to the task scheduler and survives the outage.
  provisioner "powershell" {
    script           = "${path.cwd}/scripts/windows/horizon-agents.ps1"
    environment_vars = local.agent_env
    execute_command  = "powershell -ExecutionPolicy Bypass -NoProfile -Command \"& { . {{.Vars}}; & '{{.Path}}' -Detached; exit $LastExitCode }\""
    valid_exit_codes = [0]
    only             = var.horizon_agents_enabled ? local.all_targets : local.no_targets
  }

  //  The detached install reboots the guest itself once it is finished, so there is nothing for a
  //  windows-restart provisioner to do here -- and nothing for it to issue the restart over, since
  //  the connection is gone by then. Instead the verification below retries until the guest is
  //  back: pause_before covers the install, max_retries covers the reboot.

  //  Report what the detached install actually did. Without this the build would sail past a
  //  failed agent install, because the provisioner that launched it only reports the launch.
  provisioner "powershell" {
    pause_before = "5m"
    max_retries  = 40
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "$log = 'C:\\Windows\\Temp\\horizon-agents'",
      "$marker = Join-Path $log 'agent-stack.done'",
      "if (-not (Test-Path $marker)) { throw \"The agent stack never completed: $marker is missing. See $log for per-installer logs.\" }",
      "$code = (Get-Content $marker -Raw).Trim()",
      "if (Test-Path (Join-Path $log 'agent-stack.log')) { Get-Content (Join-Path $log 'agent-stack.log') | Select-Object -Last 40 | ForEach-Object { Write-Host $_ } }",
      "if ($code -ne '0') { throw \"The agent stack exited with code $code. See $log for per-installer logs.\" }",
      "foreach ($svc in @('WSNM')) {",
      "  if (Get-Service -Name $svc -ErrorAction SilentlyContinue) { Write-Host \"  service $svc present\" } else { throw \"Agent stack reported success but the $svc service is missing.\" }",
      "}",
      "Write-Host '  Agent stack verified.'"
    ]
    valid_exit_codes = [0]
    only             = var.horizon_agents_enabled ? local.all_targets : local.no_targets
  }

  //  OSOT Optimize. Runs AFTER the agent stack, per Omnissa's documented order:
  //  install the Horizon Agent first, then DEM, FSLogix and App Volumes, and only then
  //  optimize. Optimizing first lets the agent installers re-enable services OSOT had just
  //  disabled, and denies OSOT sight of the agents it has optimizations for.
  provisioner "powershell" {
    script           = "${path.cwd}/scripts/windows/horizon-osot.ps1"
    environment_vars = local.osot_env
    execute_command  = "powershell -ExecutionPolicy Bypass -NoProfile -Command \"& { . {{.Vars}}; & '{{.Path}}' -Action Optimize; exit $LastExitCode }\""
    valid_exit_codes = [0, 3010]
    only             = var.horizon_osot_enabled ? local.all_targets : local.no_targets
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  //  Re-assert the power settings after OSOT.
  //
  //  OSOT selects its own active power plan and prevents sleep through Machine Policy, which does
  //  not take effect until policy refreshes -- but it only issues immediate powercfg commands for
  //  the monitor and disk timeouts, not for standby. That gap let the guest sleep mid-build, which
  //  presents as "no route to host" with a healthy operating system that wakes on a keypress.
  provisioner "powershell" {
    inline = [
      "$ErrorActionPreference = 'Continue'",
      "foreach ($s in @('standby-timeout-ac','standby-timeout-dc','hibernate-timeout-ac','hibernate-timeout-dc','monitor-timeout-ac','monitor-timeout-dc','disk-timeout-ac','disk-timeout-dc')) { powercfg.exe /change $s 0 | Out-Null }",
      "powercfg.exe /hibernate off | Out-Null",
      "Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power' -Name 'PlatformAoAcOverride' -Value 0 -Type DWord -Force",
      "Write-Host '  sleep, hibernation, and display timeouts disabled after OSOT'",
      "powercfg.exe /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>&1 | Select-String 'Power Setting Index' | ForEach-Object { Write-Host \"  standby idle: $_\" }",
      "# OSOT with -optimize all-item selects every item in its template, including ones that are",
      "# off by default -- among them 'Disable Power - Service'. powercfg then fails with 0x6ba,",
      "# 'The RPC server is unavailable'. Do not let that end the build: the settings above are a",
      "# safeguard, not the point of the image, and they were already applied at specialize time.",
      "$global:LASTEXITCODE = 0",
      "exit 0"
    ]
    valid_exit_codes = [0]
  }

  //  Remove the packages that Windows reprovisions and that block Sysprep. Done here rather than
  //  after Generalize, because there is no "after Generalize" from Packer's point of view.
  provisioner "powershell" {
    inline = [
      "$ErrorActionPreference = 'Continue'",
      "foreach ($pkg in @('Microsoft.Copilot', 'Microsoft.BingSearch')) {",
      "  Get-AppxPackage -Name $pkg -ErrorAction SilentlyContinue | Remove-AppxPackage -ErrorAction SilentlyContinue",
      "  $provisioned = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $pkg }",
      "  if ($provisioned) { Remove-AppxProvisionedPackage -Online -PackageName $provisioned.PackageName -ErrorAction SilentlyContinue | Out-Null }",
      "  Write-Output \"Processed $pkg\"",
      "}"
    ]
  }

  //  OSOT Finalize. Selective steps only: the full finalize set releases the IP address, which
  //  would sever Windows Remote Management and strand the build.
  provisioner "powershell" {
    script           = "${path.cwd}/scripts/windows/horizon-osot.ps1"
    environment_vars = local.osot_env
    execute_command  = "powershell -ExecutionPolicy Bypass -NoProfile -Command \"& { . {{.Vars}}; & '{{.Path}}' -Action Finalize; exit $LastExitCode }\""
    valid_exit_codes = [0, 3010]
    only             = var.horizon_osot_enabled ? local.all_targets : local.no_targets
  }

  //  OSOT Generalize. Full-clone template only, and always last: this syspreps the guest, so
  //  Windows Remote Management does not come back and no further provisioner can run.
  provisioner "powershell" {
    script           = "${path.cwd}/scripts/windows/horizon-osot.ps1"
    environment_vars = local.osot_env
    execute_command  = "powershell -ExecutionPolicy Bypass -NoProfile -Command \"& { . {{.Vars}}; & '{{.Path}}' -Action Generalize -Shutdown; exit $LastExitCode }\""
    valid_exit_codes = [0, 3010, 1, 259]
    only             = var.horizon_osot_enabled ? ["vsphere-iso.windows-horizon-template"] : local.no_targets
  }

  post-processor "manifest" {
    output     = local.manifest_output
    strip_path = true
    strip_time = true
    custom_data = {
      build_date                 = local.build_date
      build_username             = var.build_username
      build_version              = local.build_version
      common_data_source         = var.common_data_source
      common_vm_version          = var.common_vm_version
      horizon_agent_include      = local.horizon_include
      horizon_agent_source_type  = var.horizon_agent_source_type
      horizon_appvolumes_manager = var.horizon_appvolumes_manager
      horizon_osot_enabled       = var.horizon_osot_enabled
      horizon_osot_finalize      = var.horizon_osot_finalize_steps
      horizon_osot_level         = var.horizon_osot_optimization_level
      horizon_snapshot_name      = var.horizon_snapshot_name
      vm_cpu_cores               = var.vm_cpu_cores
      vm_cpu_count               = var.vm_cpu_count
      vm_disk_size               = var.vm_disk_size
      vm_firmware                = var.vm_firmware
      vm_guest_os_type           = var.vm_guest_os_type
      vm_mem_size                = var.vm_mem_size
      vm_network_card            = var.vm_network_card
      vm_vtpm                    = var.vm_vtpm
      vsphere_cluster            = var.vsphere_cluster
      vsphere_datacenter         = var.vsphere_datacenter
      vsphere_datastore          = var.vsphere_datastore
      vsphere_endpoint           = var.vsphere_endpoint
      vsphere_folder             = var.vsphere_folder
    }
  }

  dynamic "hcp_packer_registry" {
    for_each = var.common_hcp_packer_registry_enabled ? [1] : []
    content {
      bucket_name = local.bucket_name
      description = local.bucket_description
      bucket_labels = {
        "os_family" : var.vm_guest_os_family,
        "os_name" : var.vm_guest_os_name,
        "os_version" : var.vm_guest_os_version,
        "platform" : "omnissa-horizon",
      }
      build_labels = {
        "build_version" : local.build_version,
        "packer_version" : packer.version,
      }
    }
  }
}
