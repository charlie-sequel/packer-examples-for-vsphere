# © Broadcom. All Rights Reserved.
# The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-2-Clause

/*
    DESCRIPTION:
    Microsoft Windows 11 client connector image for SDS.
    Packer Plugin for VMware vSphere: 'vsphere-iso' builder.

    A deliberately barebones image: the operating system, the tools needed to reach customer
    environments, and nothing else. No Horizon agents. The OS Optimization Tool still runs, and
    the result is a sysprepped vSphere template deployed with guest customization.

    Provisioner order is load bearing:

      source check -> ansible -> [NFS client + restart] -> stage OSOT -> OSOT Optimize
      -> applications -> desktop and operator account -> AppX cleanup -> OSOT Finalize
      -> OSOT Generalize

    OSOT Generalize is Sysprep. It wipes the autologon, resets Windows Remote Management, and
    returns the guest to OOBE, so Packer cannot reconnect afterwards -- it has to be last, which is
    why the AppX cleanup and Finalize sit ahead of it rather than after it.

    The NFS client install sits AFTER the patching pass on purpose. Enabling an optional feature is
    a servicing operation, and doing it beforehand leaves the reboot at the end of Windows Update
    unable to restore Windows Remote Management.
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
  build_date_short  = formatdate("YYYY-MM-DD", timestamp())
  build_version     = data.git-repository.cwd.head
  build_description = "SDS client connector image\nVersion: ${local.build_version}\nBuilt on: ${local.build_date}\n${local.build_by}"
  iso_paths = {
    content_library = "${var.common_iso_content_library}/${var.iso_content_library_item}/${var.iso_file}",
    datastore       = "[${var.common_iso_datastore}] ${var.iso_datastore_path}/${var.iso_file}"
    tools           = "[] /vmimages/tools-isoimages/${var.vm_guest_os_family}.iso"
  }
  manifest_date   = formatdate("YYYY-MM-DD hh:mm:ss", timestamp())
  manifest_path   = "${path.cwd}/manifests/"
  manifest_output = "${local.manifest_path}${local.manifest_date}.json"
  ovf_export_path = "${path.cwd}/artifacts/"
  // No build_version suffix. That value is the git HEAD, so the artifact took the name of whatever
  // branch happened to be checked out -- "windows-sds-11-horizon-golden-image" for an SDS image,
  // which says the wrong thing entirely. The build still records the git version in the manifest
  // and the notes; the name just does not carry it. Rebuilds replace the previous artifact, which
  // is what -force already assumes.
  vm_name            = "${var.vm_guest_os_family}-sds-${var.vm_guest_os_version}-${local.build_date_short}"
  bucket_name        = replace("${var.vm_guest_os_family}-sds-${var.vm_guest_os_version}", ".", "")
  bucket_description = "SDS client connector: ${var.vm_guest_os_family} ${var.vm_guest_os_name} ${var.vm_guest_os_version}"

  // Configuration handed to the guest scripts as environment variables.
  //
  // Every provisioner that overrides execute_command must keep {{.Vars}} in it. Packer injects
  // environment_vars only at that placeholder, so an execute_command without it runs the script
  // with none of the configuration below and the script silently falls back to its defaults.
  osot_env = [
    "HORIZON_OSOT_PATH=${var.sds_osot_path}",
    "HORIZON_OSOT_TEMPLATE=${var.sds_osot_template}",
    "HORIZON_OSOT_LEVEL=${var.sds_osot_optimization_level}",
    "HORIZON_OSOT_FINALIZE_STEPS=${var.sds_osot_finalize_steps}",
    "HORIZON_OSOT_WRAPPER=${var.sds_osot_wrapper_script}",
    "HORIZON_OSOT_PATTERN=${var.sds_osot_pattern}",
  ]

  // The application list travels as JSON so applications stay data rather than code: adding one
  // is an edit to config/sds.pkrvars.hcl, never to the PowerShell.
  app_env = [
    "SDS_SOURCE_TYPE=${var.sds_source_type}",
    "SDS_SOURCE_PATH=${var.sds_source_path}",
    "SDS_SOURCE_USERNAME=${var.sds_source_username}",
    "SDS_SOURCE_PASSWORD=${var.sds_source_password}",
    "SDS_SOURCE_ANON_UID=${var.sds_source_anon_uid}",
    "SDS_SOURCE_ANON_GID=${var.sds_source_anon_gid}",
    "SDS_APPLICATIONS=${jsonencode(var.sds_applications)}",
    "SDS_OSOT_PATH=${var.sds_osot_path}",
    "SDS_OSOT_PATTERN=${var.sds_osot_pattern}",
  ]

  desktop_env = [
    "SDS_OPERATOR_USERNAME=${var.sds_operator_username}",
    "SDS_OPERATOR_PASSWORD=${var.sds_operator_password}",
    "SDS_OPERATOR_FULLNAME=${var.sds_operator_fullname}",
    "SDS_DARK_MODE=${var.sds_dark_mode ? "1" : "0"}",
    "SDS_BLACK_BACKGROUND=${var.sds_black_background ? "1" : "0"}",
    "SDS_TASKBAR_PINS=${join(",", var.sds_taskbar_pins)}",
  ]

  // The Windows NFS client installs a redirector driver that is not usable until the guest
  // restarts, so when the source is NFS the feature is enabled and the guest restarted before
  // anything attempts a mount. SMB and Datastore sources need none of this.
  nfs_targets = var.sds_source_type == "Nfs" ? ["vsphere-iso.windows-sds"] : ["vsphere-iso.__disabled__"]
}

//  BLOCK: source
//  Defines the builder configuration blocks.

source "vsphere-iso" "windows-sds" {

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
  vm_name              = local.vm_name
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
  // Console copy and paste. VMware Tools disables both by default; these are the documented
  // advanced settings that re-enable them for the VM console. Applied to the SDS image because it
  // is an operator workstation -- deliberately NOT applied to the Horizon golden image, where
  // clones inherit it and hardening guidance is to leave console copy/paste disabled.
  configuration_parameters = {
    "isolation.tools.copy.disable"  = "FALSE"
    "isolation.tools.paste.disable" = "FALSE"
  }

  // Applied to everything this environment builds, so backup policy picks up new templates and
  // golden images automatically rather than by someone remembering. The category and tag must
  // already exist in vCenter -- Packer attaches them, it does not create them.
  tag {
    category = "Backup"
    name     = "weekly"
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
      vm_inst_os_image     = var.vm_inst_os_image_pro
      vm_inst_os_key       = var.vm_inst_os_key_pro
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

  // Deployed with guest customization, so the image is sysprepped and converted to a template.
  convert_to_template = true

  // OVF Export Settings
  dynamic "export" {
    for_each = var.common_ovf_export_enabled ? [1] : []
    content {
      name        = local.vm_name
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
    "source.vsphere-iso.windows-sds",
  ]

  //  Fail fast on an unreachable installer source. Deliberately a pure connectivity test: no
  //  optional feature, no restart, nothing that touches servicing. A misconfigured share is then
  //  cheap to diagnose instead of surfacing forty minutes later.
  provisioner "powershell" {
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "$path = $env:SDS_SOURCE_PATH",
      "if (-not $path) { Write-Host 'No installer source configured; skipping the reachability check.'; exit 0 }",
      "$server = if ($path -match '^([^:\\\\]+):') { $Matches[1] } elseif ($path -match '^\\\\\\\\([^\\\\]+)') { $Matches[1] } else { $null }",
      "if (-not $server) { Write-Host \"Could not parse a server out of '$path'; skipping.\"; exit 0 }",
      "$ports = if ($env:SDS_SOURCE_TYPE -eq 'Nfs') { @(111, 2049) } elseif ($env:SDS_SOURCE_TYPE -eq 'Smb') { @(445) } else { @() }",
      "$failed = @()",
      "foreach ($port in $ports) {",
      "  $ok = (Test-NetConnection -ComputerName $server -Port $port -WarningAction SilentlyContinue).TcpTestSucceeded",
      "  Write-Host \"  $${server}:$${port} reachable = $ok\"",
      "  if (-not $ok) { $failed += $port }",
      "}",
      "if ($failed) { throw \"Installer source $server is unreachable on port(s): $($failed -join ', '). NFS needs 111 (portmapper) and 2049; SMB needs 445.\" }"
    ]
    environment_vars = local.app_env
    valid_exit_codes = [0]
  }

  //  Base operating system configuration and patching.
  provisioner "ansible" {
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
      // The Packer Ansible plugin writes ansible_shell_type=powershell into the inventory
      // it generates for WinRM hosts. ansible-core 2.19 changed the winrm connection to
      // require the cmd shell, and with powershell the command is no longer valid base64
      // by the time it reaches -EncodedCommand, so every task fails on send_input.
      // --extra-vars outranks inventory vars, so this wins.
      "--extra-vars", "ansible_shell_type=cmd",
      "--extra-vars", "ansible_user='${var.build_username}'",
      "--extra-vars", "ansible_password='${var.build_password}'",
      "--extra-vars", "ansible_port='${var.communicator_port}'",
      "--extra-vars", "build_username='${var.build_username}'",
    ]
  }

  //  Enable the Windows NFS client, then restart so its redirector is usable. Only for the Nfs
  //  source type, and only after patching -- enabling an optional feature beforehand leaves the
  //  post-update reboot unable to restore Windows Remote Management.
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
      "$key = 'HKLM:\\\\SOFTWARE\\\\Microsoft\\\\ClientForNFS\\\\CurrentVersion\\\\Default'",
      "if ($env:SDS_SOURCE_ANON_UID -or $env:SDS_SOURCE_ANON_GID) {",
      "  if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }",
      "  if ($env:SDS_SOURCE_ANON_UID) { Set-ItemProperty -Path $key -Name AnonymousUid -Value ([int]$env:SDS_SOURCE_ANON_UID) -Type DWord -Force }",
      "  if ($env:SDS_SOURCE_ANON_GID) { Set-ItemProperty -Path $key -Name AnonymousGid -Value ([int]$env:SDS_SOURCE_ANON_GID) -Type DWord -Force }",
      "  Write-Host \"NFS anonymous identity set to uid=$env:SDS_SOURCE_ANON_UID gid=$env:SDS_SOURCE_ANON_GID; the restart below applies it.\"",
      "}"
    ]
    environment_vars = local.app_env
    valid_exit_codes = [0, 3010]
    only             = local.nfs_targets
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
    only            = local.nfs_targets
  }

  //  Stage the OS Optimization Tool from the installer source.
  provisioner "powershell" {
    script           = "${path.cwd}/scripts/windows/sds-apps.ps1"
    environment_vars = concat(local.app_env, local.osot_env)
    execute_command  = "powershell -ExecutionPolicy Bypass -NoProfile -Command \"& { . {{.Vars}}; & '{{.Path}}' -StageOsotOnly; exit $LastExitCode }\""
    valid_exit_codes = [0]
    only             = var.sds_osot_enabled && var.sds_osot_stage_from_source && var.sds_osot_wrapper_script == "" ? ["vsphere-iso.windows-sds"] : ["vsphere-iso.__disabled__"]
  }

  //  OSOT Optimize. Runs before the applications so they install onto an already optimized image.
  provisioner "powershell" {
    script           = "${path.cwd}/scripts/windows/horizon-osot.ps1"
    environment_vars = local.osot_env
    execute_command  = "powershell -ExecutionPolicy Bypass -NoProfile -Command \"& { . {{.Vars}}; & '{{.Path}}' -Action Optimize; exit $LastExitCode }\""
    valid_exit_codes = [0, 3010]
    only             = var.sds_osot_enabled ? ["vsphere-iso.windows-sds"] : ["vsphere-iso.__disabled__"]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  //  Applications, in the order given in config/sds.pkrvars.hcl.
  provisioner "powershell" {
    script           = "${path.cwd}/scripts/windows/sds-apps.ps1"
    environment_vars = local.app_env
    valid_exit_codes = [0]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  //  Operator account, dark mode, and the taskbar. Runs after the applications because the pins
  //  are resolved by finding each application's Start Menu shortcut -- nothing to find until they
  //  are installed. Per-user settings are written to the DEFAULT profile, so the operator account
  //  and anything created after deployment inherit them; settings written to the build account's
  //  profile would vanish with it.
  provisioner "powershell" {
    script           = "${path.cwd}/scripts/windows/sds-desktop.ps1"
    environment_vars = local.desktop_env
    valid_exit_codes = [0]
  }

  //  Remove the packages that Windows reprovisions and that block Sysprep. Done here rather than
  //  after Generalize, because there is no "after Generalize" from Packer's point of view.
  provisioner "powershell" {
    inline = [
      "$ErrorActionPreference = 'Continue'",
      "foreach ($pkg in @('Microsoft.Copilot', 'Microsoft.BingSearch', 'Microsoft.OutlookForWindows')) {",
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
    only             = var.sds_osot_enabled ? ["vsphere-iso.windows-sds"] : ["vsphere-iso.__disabled__"]
  }

  //  OSOT Generalize. Always last: this syspreps the guest, so Windows Remote Management does not
  //  come back and no further provisioner can run.
  provisioner "powershell" {
    script           = "${path.cwd}/scripts/windows/horizon-osot.ps1"
    environment_vars = local.osot_env
    execute_command  = "powershell -ExecutionPolicy Bypass -NoProfile -Command \"& { . {{.Vars}}; & '{{.Path}}' -Action Generalize -Shutdown; exit $LastExitCode }\""
    valid_exit_codes = [0, 3010, 1, 259]
    only             = var.sds_osot_enabled && var.sds_osot_generalize ? ["vsphere-iso.windows-sds"] : ["vsphere-iso.__disabled__"]
  }

  post-processor "manifest" {
    output     = local.manifest_output
    strip_path = true
    strip_time = true
    custom_data = {
      build_date         = local.build_date
      build_username     = var.build_username
      build_version      = local.build_version
      common_data_source = var.common_data_source
      common_vm_version  = var.common_vm_version
      sds_applications   = join(", ", [for a in var.sds_applications : a.name])
      sds_osot_enabled   = var.sds_osot_enabled
      sds_osot_finalize  = var.sds_osot_finalize_steps
      sds_osot_level     = var.sds_osot_optimization_level
      sds_source_type    = var.sds_source_type
      vm_cpu_cores       = var.vm_cpu_cores
      vm_cpu_count       = var.vm_cpu_count
      vm_disk_size       = var.vm_disk_size
      vm_firmware        = var.vm_firmware
      vm_guest_os_type   = var.vm_guest_os_type
      vm_mem_size        = var.vm_mem_size
      vm_network_card    = var.vm_network_card
      vm_vtpm            = var.vm_vtpm
      vsphere_cluster    = var.vsphere_cluster
      vsphere_datacenter = var.vsphere_datacenter
      vsphere_datastore  = var.vsphere_datastore
      vsphere_endpoint   = var.vsphere_endpoint
      vsphere_folder     = var.vsphere_folder
      vsphere_network    = var.vsphere_network
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
        "platform" : "sds-client-connector",
      }
      build_labels = {
        "build_version" : local.build_version,
        "packer_version" : packer.version,
      }
    }
  }
}
