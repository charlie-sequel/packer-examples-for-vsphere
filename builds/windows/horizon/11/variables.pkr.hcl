# © Broadcom. All Rights Reserved.
# The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-2-Clause

/*
    DESCRIPTION:
    Microsoft Windows 11 input variables.
    Packer Plugin for VMware vSphere: 'vsphere-iso' builder.
*/

//  BLOCK: variable
//  Defines the input variables.

// vSphere Credentials

variable "vsphere_endpoint" {
  type        = string
  description = "The fully qualified domain name or IP address of the vCenter Server instance."
}

variable "vsphere_username" {
  type        = string
  description = "The username to login to the vCenter Server instance."
  sensitive   = true
}

variable "vsphere_password" {
  type        = string
  description = "The password for the login to the vCenter Server instance."
  sensitive   = true
}

variable "vsphere_insecure_connection" {
  type        = bool
  description = "Do not validate vCenter Server TLS certificate."
}

// vSphere Settings

variable "vsphere_datacenter" {
  type        = string
  description = "The name of the target vSphere datacenter."
  default     = ""
}

variable "vsphere_cluster" {
  type        = string
  description = "The name of the target vSphere cluster."
  default     = ""
}

variable "vsphere_host" {
  type        = string
  description = "The name of the target ESXi host."
  default     = ""
}

variable "vsphere_datastore" {
  type        = string
  description = "The name of the target vSphere datastore."
}

variable "vsphere_network" {
  type        = string
  description = "The name of the target vSphere network segment."
}

variable "vsphere_folder" {
  type        = string
  description = "The name of the target vSphere folder."
  default     = ""
}

variable "vsphere_resource_pool" {
  type        = string
  description = "The name of the target vSphere resource pool."
  default     = ""
}

variable "vsphere_set_host_for_datastore_uploads" {
  type        = bool
  description = "Set this to true if packer should use the host for uploading files to the datastore."
  default     = false
}

// Installer Settings

variable "vm_inst_os_language" {
  type        = string
  description = "The installation operating system language."
  default     = "en-US"
}

variable "vm_inst_os_keyboard" {
  type        = string
  description = "The installation operating system keyboard input."
  default     = "en-US"
}

variable "vm_inst_os_eval" {
  type        = bool
  description = "Build using the operating system evaluation"
  default     = true
}

variable "vm_inst_os_image_pro" {
  type        = string
  description = "The installation operating system image input.\nDoes not support evaluation."
  default     = "Windows 11 Pro"
}

variable "vm_inst_os_key_pro" {
  type        = string
  description = "The installation operating system key input."
}

// Virtual Machine Settings

variable "vm_guest_os_language" {
  type        = string
  description = "The guest operating system language."
  default     = "en-US"
}

variable "vm_guest_os_keyboard" {
  type        = string
  description = "The guest operating system keyboard input."
  default     = "en-US"
}

variable "vm_guest_os_timezone" {
  type        = string
  description = "The guest operating system timezone."
  default     = "UTC"
}

variable "vm_guest_os_family" {
  type        = string
  description = "The guest operating system family. Used for naming and VMware Tools."
  default     = "windows"
}

variable "vm_guest_os_name" {
  type        = string
  description = "The guest operating system name. Used for naming."
  default     = "desktop"
}

variable "vm_guest_os_version" {
  type        = string
  description = "The guest operating system version. Used for naming."
  default     = "11"
}

variable "vm_guest_os_type" {
  type        = string
  description = "The guest operating system type, also know as guestid."
}

variable "vm_firmware" {
  type        = string
  description = "The virtual machine firmware."
  default     = "efi-secure"
}

variable "vm_cdrom_type" {
  type        = string
  description = "The virtual machine CD-ROM type."
  default     = "sata"
}

variable "vm_cdrom_count" {
  type        = string
  description = "The number of virtual CD-ROMs remaining after the build."
  default     = 1
}

variable "vm_cpu_count" {
  type        = number
  description = "The number of virtual CPUs."
  default     = 2
}

variable "vm_cpu_cores" {
  type        = number
  description = "The number of virtual CPUs cores per socket."
  default     = 2
}

variable "vm_cpu_hot_add" {
  type        = bool
  description = "Enable hot add CPU."
  default     = false
}

variable "vm_mem_size" {
  type        = number
  description = "The size for the virtual memory in MB."
  default     = 4096
}

variable "vm_mem_hot_add" {
  type        = bool
  description = "Enable hot add memory."
  default     = false
}

variable "vm_vtpm" {
  type        = bool
  description = "Enable virtual trusted platform module (vTPM)."
  default     = true
}

variable "vm_disk_size" {
  type        = number
  description = "The size for the virtual disk in MB."
  default     = 102400
}

variable "vm_disk_controller_type" {
  type        = list(string)
  description = "The virtual disk controller types in sequence."
  default     = ["pvscsi"]
}

variable "vm_disk_thin_provisioned" {
  type        = bool
  description = "Thin provision the virtual disk."
  default     = true
}

variable "vm_network_card" {
  type        = string
  description = "The virtual network card type."
  default     = "vmxnet3"
}

variable "vm_video_ram" {
  type        = number
  description = "The size for the video memory in KB."
  default     = 4096
}

variable "vm_video_displays" {
  type        = number
  description = "The number of video displays."
  default     = 1
}

variable "common_vm_version" {
  type        = number
  description = "The vSphere virtual hardware version."
}

variable "common_tools_upgrade_policy" {
  type        = bool
  description = "Upgrade VMware Tools on reboot."
  default     = true
}

variable "common_remove_cdrom" {
  type        = bool
  description = "Remove the virtual CD-ROM(s)."
  default     = true
}

// Template and Content Library Settings

variable "common_template_conversion" {
  type        = bool
  description = "Convert the virtual machine to template. Must be 'false' for content library."
  default     = false
}

variable "common_content_library_enabled" {
  type        = bool
  description = "Import the virtual machine into the vSphere content library."
  default     = true
}

variable "common_content_library" {
  type        = string
  description = "The name of the target vSphere content library, if enabled."
  default     = null
}

variable "common_content_library_ovf" {
  type        = bool
  description = "Export to content library as an OVF template."
  default     = true
}

variable "common_content_library_destroy" {
  type        = bool
  description = "Delete the virtual machine after exporting to the content library."
  default     = true
}

variable "common_content_library_skip_export" {
  type        = bool
  description = "Skip exporting the virtual machine to the content library. Option allows for testing/debugging without saving the machine image."
  default     = false
}

// OVF Export Settings

variable "common_ovf_export_enabled" {
  type        = bool
  description = "Enable OVF artifact export."
  default     = false
}

variable "common_ovf_export_overwrite" {
  type        = bool
  description = "Overwrite existing OVF artifact."
  default     = true
}

variable "common_ovf_export_image_files" {
  type        = bool
  description = "Export image files in the OVF artifact."
  default     = true
}

// Removable Media Settings

variable "common_iso_content_library_enabled" {
  type        = bool
  description = "Import the guest operating system ISO into the vSphere content library."
  default     = false
}

variable "common_iso_content_library" {
  type        = string
  description = "The name of the target vSphere content library for the guest operating system ISO."
}

variable "common_iso_datastore" {
  type        = string
  description = "The name of the target vSphere datastore for the guest operating system ISO."
}

variable "iso_datastore_path" {
  type        = string
  description = "The path on the source vSphere datastore for the guest operating system ISO."
}

variable "iso_file" {
  type        = string
  description = "The file name of the guest operating system ISO."
}

variable "iso_content_library_item" {
  type        = string
  description = "The vSphere content library item name for the guest operating system ISO."
}

// Boot Settings

variable "common_data_source" {
  type        = string
  description = "The provisioning data source. One of `http` or `disk`."
}

variable "common_http_ip" {
  type        = string
  description = "Define an IP address on the host to use for the HTTP server."
  default     = null
}

variable "common_http_port_min" {
  type        = number
  description = "The start of the HTTP port range."
}

variable "common_http_port_max" {
  type        = number
  description = "The end of the HTTP port range."
}

variable "vm_boot_order" {
  type        = string
  description = "The boot order for virtual machines devices."
  default     = "disk,cdrom"
}

variable "vm_boot_wait" {
  type        = string
  description = "The time to wait before boot."
  default     = "3s"
}

variable "vm_boot_command" {
  type        = list(string)
  description = "The virtual machine boot command."
  default     = ["<spacebar><spacebar>"]
}

variable "vm_shutdown_command" {
  type        = string
  description = "Command(s) for guest operating system shutdown."
  default     = "shutdown /s /t 10 /f /d p:4:1 /c \"Shutdown by Packer\""
}

variable "common_ip_wait_timeout" {
  type        = string
  description = "Time to wait for guest operating system IP address response."
}

variable "common_ip_settle_timeout" {
  type        = string
  description = "Time to wait for guest operating system IP to settle down."
  default     = "5s"
}

variable "common_shutdown_timeout" {
  type        = string
  description = "Time to wait for guest operating system shutdown."
}

// Communicator Settings and Credentials

variable "build_username" {
  type        = string
  description = "The username to login to the guest operating system."
  sensitive   = true
}

variable "build_password" {
  type        = string
  description = "The password to login to the guest operating system."
  sensitive   = true
}

variable "build_password_encrypted" {
  type        = string
  description = "The SHA-512 encrypted password to login to the guest operating system."
  sensitive   = true
  default     = ""
}

variable "build_key" {
  type        = string
  description = "The public key to login to the guest operating system."
  sensitive   = true
  default     = ""
}

// Communicator Credentials

variable "communicator_port" {
  type        = number
  description = "The port for the communicator protocol."
  default     = 5985
}

variable "communicator_timeout" {
  type        = string
  description = "The timeout for the communicator protocol."
  default     = "12h"
}

// Ansible Credentials

variable "ansible_username" {
  type        = string
  description = "The username for Ansible to login to the guest operating system."
  sensitive   = true
}

variable "ansible_key" {
  type        = string
  description = "The public key for Ansible to login to the guest operating system."
  sensitive   = true
}

// Provisioner Settings

variable "scripts" {
  type        = list(string)
  description = "A list of scripts and their relative paths to transfer and run."
  default     = []
}

variable "inline" {
  type        = list(string)
  description = "A list of commands to run."
  default     = []
}

// HCP Packer Settings

variable "common_hcp_packer_registry_enabled" {
  type        = bool
  description = "Enable the HCP Packer registry."
  default     = false
}

// Omnissa Horizon: Image Type Settings

variable "horizon_snapshot_name" {
  type        = string
  description = "Name of the snapshot taken on the instant-clone golden image. Horizon pools point at this snapshot."
  default     = "horizon-golden-image"
}

// Omnissa Horizon: OS Optimization Tool (OSOT) Settings

variable "horizon_osot_enabled" {
  type        = bool
  description = "Run the Omnissa OS Optimization Tool during the build. Disable to build an agents-only image."
  default     = true
}

variable "horizon_osot_path" {
  type        = string
  description = "Directory on the guest containing the OSOT executable."
  default     = "C:\\Tools\\OSOT"
}

variable "horizon_osot_stage_from_source" {
  type        = bool
  description = "Copy the OSOT executable from the installer source to horizon_osot_path before optimizing. Disable when OSOT is already present in the image or a wrapper script stages it."
  default     = true
}

variable "horizon_osot_pattern" {
  type        = string
  description = "Filename pattern used to locate the OSOT executable on the installer source. The highest file version wins."
  default     = "*OSOptimizationTool*.exe"
}

variable "horizon_osot_template" {
  type        = string
  description = "OSOT optimization template passed as -t. Leave empty to use the tool's default for the detected operating system."
  default     = ""
}

variable "horizon_osot_optimization_level" {
  type        = string
  description = "OSOT optimization level passed as -o: default, all, recommended, mandatory, or none."
  default     = "recommended"

  validation {
    condition     = contains(["default", "all", "recommended", "mandatory", "none"], var.horizon_osot_optimization_level)
    error_message = "The horizon_osot_optimization_level must be one of: default, all, recommended, mandatory, none."
  }
}

variable "horizon_osot_finalize_steps" {
  type        = string
  description = <<-EOT
    Comma-separated OSOT finalize step numbers.

    Do not set this to "all". The OSOT finalize set includes a step that releases the IP address;
    running it mid-build severs Windows Remote Management and the build stalls at the connection
    timeout with no output explaining why. The default covers the two steps whose numbering is
    publicly documented: 0 (NGEN .NET precompile) and 1 (DISM side-by-side component cleanup).
    Add further steps only after confirming what they do in your OSOT build.
  EOT
  default     = "0,1"
}

variable "horizon_osot_wrapper_script" {
  type        = string
  description = <<-EOT
    Optional path to a site-supplied OSOT wrapper script, for example Invoke-HorizonOSOT.ps1.

    When set, horizon-osot.ps1 delegates to it instead of invoking the OSOT executable directly,
    so an existing wrapper that already encodes the OSOT download, template handling, and finalize
    step mapping remains authoritative.
  EOT
  default     = ""
}

// Omnissa Horizon: Agent Installer Source Settings

variable "horizon_agents_enabled" {
  type        = bool
  description = "Install the Horizon agent stack during the build."
  default     = true
}

variable "horizon_agent_source_type" {
  type        = string
  description = "Where the agent installers live: Auto, Smb, Nfs, or Datastore."
  default     = "Auto"

  validation {
    condition     = contains(["Auto", "Smb", "Nfs", "Datastore"], var.horizon_agent_source_type)
    error_message = "The horizon_agent_source_type must be one of: Auto, Smb, Nfs, Datastore."
  }
}

variable "horizon_agent_source_path" {
  type        = string
  description = "UNC path for Smb (\\\\host\\share\\path) or export path for Nfs (host:/export/path). Unused for Datastore."
  default     = ""
}

variable "horizon_agent_source_username" {
  type        = string
  description = "Username for the SMB installer share. Unused for NFS and Datastore."
  default     = ""
}

variable "horizon_agent_source_password" {
  type        = string
  description = "Password for the SMB installer share. Passed to the guest as an environment variable so it does not appear in the guest process list."
  default     = ""
  sensitive   = true
}

variable "horizon_install_agent" {
  type        = bool
  description = "Install the Omnissa Horizon Agent."
  default     = true
}

variable "horizon_install_dem" {
  type        = bool
  description = "Install Omnissa Dynamic Environment Manager (FlexEngine)."
  default     = true
}

variable "horizon_install_fslogix" {
  type        = bool
  description = "Install Microsoft FSLogix."
  default     = true
}

variable "horizon_install_appvolumes" {
  type        = bool
  description = "Install the Omnissa App Volumes Agent. Requires horizon_appvolumes_manager."
  default     = true
}

// Omnissa Horizon: Connection Server Registration

variable "horizon_agent_vc_managed" {
  type        = bool
  description = <<-EOT
    Whether the agent is managed by vCenter Server, mapped to VDM_VC_MANAGED_AGENT.

    Set true for images consumed by automated desktop pools; no Connection Server registration
    happens at install time and the Connection Server settings below are unused. Set false for
    unmanaged or manual pools, which registers the machine with horizon_connection_server during
    installation and therefore requires the credentials below.
  EOT
  default     = true
}

variable "horizon_connection_server" {
  type        = string
  description = "Connection Server FQDN to register with, mapped to VDM_SERVER_NAME. Used only when horizon_agent_vc_managed is false."
  default     = ""
}

variable "horizon_connection_server_username" {
  type        = string
  description = "Connection Server administrator account, mapped to VDM_SERVER_USERNAME. Used only when horizon_agent_vc_managed is false."
  default     = ""
}

variable "horizon_connection_server_password" {
  type        = string
  description = "Connection Server administrator password, mapped to VDM_SERVER_PASSWORD. Passed to the guest as an environment variable and only assembled onto the installer command line inside the guest."
  default     = ""
  sensitive   = true
}

variable "horizon_agent_features" {
  type        = string
  description = "Horizon Agent feature list, mapped to ADDLOCAL."
  default     = "Core,USB,ClientDriveRedirection,PrintRedir,NGVC"
}

// Omnissa Horizon: Agent Installer Patterns and Arguments

variable "horizon_agent_source_anon_uid" {
  type        = string
  description = "UID the Windows NFS client presents when mounting with -o anon. Its default is -2, which an export owned by a specific UID will reject. Leave empty to use the client default."
  default     = ""
}

variable "horizon_agent_source_anon_gid" {
  type        = string
  description = "GID the Windows NFS client presents when mounting with -o anon. Leave empty to use the client default."
  default     = ""
}

variable "horizon_agent_pattern" {
  type        = string
  description = "Filename pattern used to locate the Horizon Agent installer."
  default     = "*Horizon-Agent*.exe"
}

variable "horizon_dem_pattern" {
  type        = string
  description = "Filename pattern used to locate the Dynamic Environment Manager installer."
  default     = "*Dynamic*Environment*Manager*.msi"
}

variable "horizon_dem_features" {
  type        = string
  description = "Dynamic Environment Manager feature list, mapped to ADDLOCAL."
  default     = "FlexEngine"
}

variable "horizon_dem_config_share" {
  type        = string
  description = <<-EOT
    UNC path to the Dynamic Environment Manager configuration share, mapped to
    COMPENVCONFIGFILEPATH.

    Setting this enables computer environment settings support, which is what applies computer
    based policies. Requires DEM Agent 2103 or later; on earlier agents the equivalent is set
    through registry values instead. Leave empty to install FlexEngine without computer
    environment settings.

    Example: "\\\\fileserver.example.com\\DEMConfig\\general"
  EOT
  default     = ""
}

variable "horizon_dem_license_file" {
  type        = string
  description = "UNC path to the Dynamic Environment Manager license file, mapped to LICENSEFILE. Leave empty if licensing is handled another way."
  default     = ""
}

variable "horizon_dem_args" {
  type        = string
  description = "Additional msiexec properties appended verbatim to the Dynamic Environment Manager installer command line."
  default     = ""
}

variable "horizon_fslogix_pattern" {
  type        = string
  description = "Filename pattern used to locate the FSLogix installer."
  default     = "FSLogixAppsSetup.exe"
}

variable "horizon_fslogix_args" {
  type        = string
  description = "Arguments passed to the FSLogix installer."
  default     = "/install /quiet /norestart"
}

variable "horizon_fslogix_profile_path" {
  type        = string
  description = <<-EOT
    UNC path for FSLogix profile containers. When set, the image is configured with
    Profiles\Enabled = 1 and Profiles\VHDLocations after the agent installs.

    Leave empty to install FSLogix without configuring profile containers, for example when
    Group Policy supplies these settings instead.

    Example: "\\\\fileserver.example.com\\Profiles"
  EOT
  default     = ""
}

variable "horizon_appvolumes_pattern" {
  type        = string
  description = "Filename pattern used to locate the App Volumes Agent installer."
  default     = "*App*Volumes*Agent*.msi"
}

variable "horizon_appvolumes_manager" {
  type        = string
  description = "App Volumes Manager hostname or IP address. Required when AppVolumes is included; the agent is skipped when empty."
  default     = ""
}

variable "horizon_appvolumes_port" {
  type        = number
  description = "App Volumes Manager port."
  default     = 443
}
