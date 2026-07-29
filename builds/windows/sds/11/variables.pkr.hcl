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

// Omnissa Horizon: OS Optimization Tool (OSOT) Settings

// Omnissa Horizon: Agent Installer Source Settings

// Omnissa Horizon: Connection Server Registration

// Omnissa Horizon: Agent Installer Patterns and Arguments

// SDS Client Connector Settings

variable "sds_source_type" {
  type        = string
  description = "Where the application installers live: Auto, Smb, Nfs, or Datastore."
  default     = "Auto"

  validation {
    condition     = contains(["Auto", "Smb", "Nfs", "Datastore"], var.sds_source_type)
    error_message = "The sds_source_type must be one of: Auto, Smb, Nfs, Datastore."
  }
}

variable "sds_source_path" {
  type        = string
  description = "UNC path (Smb) or host:/export path (Nfs) holding the application installers."
  default     = ""
}

variable "sds_source_username" {
  type        = string
  description = "Username for the SMB installer share."
  default     = ""
}

variable "sds_source_password" {
  type        = string
  description = "Password for the SMB installer share. Prefer PKR_VAR_sds_source_password."
  default     = ""
  sensitive   = true
}

variable "sds_source_anon_uid" {
  type        = string
  description = "UID the Windows NFS client presents when mounting with -o anon. Its default is -2, which an export owned by a specific UID will reject."
  default     = ""
}

variable "sds_source_anon_gid" {
  type        = string
  description = "GID the Windows NFS client presents when mounting with -o anon."
  default     = ""
}

variable "sds_operator_username" {
  type        = string
  description = "Local operator account created on the image. Leave empty to create none."
  default     = ""
}

variable "sds_operator_password" {
  type        = string
  description = "Password for the operator account. Do not assign it in a var-file: var-files outrank PKR_VAR_ environment variables. Export PKR_VAR_sds_operator_password instead."
  default     = ""
  sensitive   = true
}

variable "sds_operator_fullname" {
  type        = string
  description = "Full name shown for the operator account."
  default     = "SDS Operator"
}

variable "sds_dark_mode" {
  type        = bool
  description = "Set the default profile, and so every account created afterwards, to dark mode."
  default     = true
}

variable "sds_taskbar_pins" {
  type        = list(string)
  description = "Applications to pin to the taskbar, in order. Matched against Start Menu shortcut names, so a pin follows the application wherever it installed itself. Pinning anything replaces the Windows defaults, which is how Store and Copilot leave the taskbar."
  default     = ["Notepad++", "Remote Desktop Manager", "1Password", "FortiClient", "GlobalProtect", "Cisco Secure Client"]
}

variable "sds_applications" {
  type = list(object({
    name     = string
    pattern  = string
    type     = string
    args     = string
    detect   = string
    required = bool
  }))
  description = "Applications to install, in order. Located by filename pattern rather than exact version. Every field is required: Packer's HCL2 has no optional() modifier, so give detect \"\" and required false when they do not apply."
  default     = []
}

variable "sds_osot_enabled" {
  type        = bool
  description = "Run the Omnissa OS Optimization Tool during the build."
  default     = true
}

variable "sds_osot_stage_from_source" {
  type        = bool
  description = "Copy the OSOT executable from the installer source before optimizing."
  default     = true
}

variable "sds_osot_path" {
  type        = string
  description = "Directory on the guest containing the OSOT executable."
  default     = "C:\\Tools\\OSOT"
}

variable "sds_osot_pattern" {
  type        = string
  description = "Filename pattern used to locate the OSOT executable on the installer source."
  default     = "*OSOptimizationTool*.exe"
}

variable "sds_osot_template" {
  type        = string
  description = "OSOT optimization template passed as -t. Leave empty for the tool's default."
  default     = ""
}

variable "sds_osot_optimization_level" {
  type        = string
  description = "Value for OSOT's -optimize argument. 'all-item' selects every item in the template; 'no-item' selects none. These are the only values OSOT accepts -- severity names like \"recommended\" are item categories inside a template, not command-line values."
  default     = "all-item"

  validation {
    condition     = contains(["all-item", "no-item"], var.sds_osot_optimization_level)
    error_message = "The sds_osot_optimization_level must be all-item or no-item. OSOT rejects anything else -- and still exits 0, so a wrong value silently optimizes nothing."
  }
}

variable "sds_osot_finalize_steps" {
  type        = string
  description = "Comma-separated OSOT finalize step numbers. Never 'all': the full set releases the IP address and severs WinRM mid-build."
  default     = "0,1"
}

variable "sds_osot_wrapper_script" {
  type        = string
  description = "Optional site-supplied OSOT wrapper. When set it takes over from the built-in OSOT invocation."
  default     = ""
}
