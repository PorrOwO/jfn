variable "libvirt_uri" {
  type    = string
  default = "qemu:///system"
}

variable "storage_pool" {
  type    = string
  default = "default"
}

variable "golden_image_path" {
  description = "Frozen golden image (never booted directly; every VM is a copy-on-write clone of it)"
  type        = string
  default     = "/var/lib/libvirt/images/jfn-golden.qcow2"
}

variable "base_volume_name" {
  description = "Name of the base volume copied into the pool. Bump the suffix when you rebuild the golden image."
  type        = string
  default     = "jfn-base-v1.qcow2"
}

# ---- cluster shape --------------------------------------------------------
variable "worker_count" {
  description = "Number of JFN nodes (each is an isolated JFN instance)"
  type        = number
  default     = 3
  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 9
    error_message = "worker_count must be between 0 and 9 (IPs .20-.29)."
  }
}

variable "etcd_count" {
  description = "Size of the fixed etcd tier. Keep it odd; change it only on a fresh cluster."
  type        = number
  default     = 3
  validation {
    condition     = contains([1, 3, 5], var.etcd_count)
    error_message = "etcd_count must be 1, 3 or 5."
  }
}

variable "network_cidr" {
  description = "Dedicated lab network (must not overlap your other libvirt networks)"
  type        = string
  default     = "192.168.130.0/24"
}

# ---- sizes -----------------------------------------------------------------
variable "manager_vcpus" {
  type    = number
  default = 1
}
variable "manager_memory_mb" {
  type    = number
  default = 1024
}
variable "worker_vcpus" {
  type    = number
  default = 2
}
variable "worker_memory_mb" {
  type    = number
  default = 2048
}
variable "etcd_vcpus" {
  type    = number
  default = 1
}
variable "etcd_memory_mb" {
  type    = number
  default = 1024
}

variable "disk_size_bytes" {
  description = "Virtual disk size per VM (must be >= the golden image size)"
  type        = number
  default     = 21474836480 # 20 GiB
}

# ---- etcd ------------------------------------------------------------------
variable "etcd_image" {
  description = "etcd image, exactly as tagged in the golden image (docker images)"
  type        = string
  default     = "quay.io/coreos/etcd:v3.5.9"
}

variable "etcd_heartbeat_ms" {
  description = "Raft heartbeat. Raise to ~max emulated RTT when you add Kollaps latency."
  type        = number
  default     = 100
}

variable "etcd_election_ms" {
  description = "Raft election timeout. Keep >= 10x heartbeat."
  type        = number
  default     = 1000
}

# ---- access ----------------------------------------------------------------
variable "ssh_private_key_path" {
  type    = string
  default = "~/.ssh/jfn_lab"
}

variable "ssh_public_key_paths" {
  type    = list(string)
  default = ["~/.ssh/jfn_lab.pub"]
}
