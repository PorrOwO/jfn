terraform {
  required_version = ">= 1.6"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.3" # pinned: the 0.9 schema is different
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}

# ─── Network: dedicated NAT network, static addressing (no DHCP) ────
resource "libvirt_network" "jfn" {
  name      = "jfn-lab"
  mode      = "nat"
  domain    = "jfn.lab"
  addresses = [var.network_cidr]
  autostart = true

  dhcp {
    enabled = false
  }
  dns {
    enabled = true
  }
}

# ─── Base disk + manager ────────────────────────────────────────────
resource "libvirt_volume" "base" {
  name   = var.base_volume_name
  pool   = var.storage_pool
  source = var.golden_image_path
  format = "qcow2"
}

resource "libvirt_volume" "manager" {
  name           = "${local.manager.name}.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.base.id
  size           = var.disk_size_bytes
}

resource "libvirt_cloudinit_disk" "manager" {
  name = "${local.manager.name}-init.iso"
  pool = var.storage_pool

  user_data = templatefile("${path.module}/templates/manager-user-data.yaml.tpl", {
    hostname   = local.manager.name
    ssh_keys   = jsonencode(local.ssh_keys)
    manager_ip = local.manager.ip
  })
  meta_data = "instance-id: ${local.manager.name}\nlocal-hostname: ${local.manager.name}\n"
  network_config = templatefile("${path.module}/templates/network-config.yaml.tpl", {
    mac     = local.manager.mac
    ip      = local.manager.ip
    prefix  = local.prefix
    gateway = local.gateway
  })
}

resource "libvirt_domain" "manager" {
  name       = local.manager.name
  memory     = var.manager_memory_mb
  vcpu       = var.manager_vcpus
  qemu_agent = true
  cloudinit  = libvirt_cloudinit_disk.manager.id

  cpu {
    mode = "host-passthrough"
  }
  disk {
    volume_id = libvirt_volume.manager.id
  }
  network_interface {
    network_id     = libvirt_network.jfn.id
    mac            = local.manager.mac
    wait_for_lease = false
  }
}

# Wait until the manager finished cloud-init and `docker swarm init`
resource "terraform_data" "manager_ready" {
  triggers_replace = libvirt_domain.manager.id

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = local.manager.ip
      user        = "debian"
      private_key = file(pathexpand(var.ssh_private_key_path))
      timeout     = "5m"
    }
    inline = [
      "cloud-init status --wait || true",
      "until sudo docker info --format '{{.Swarm.LocalNodeState}}' | grep -q '^active$'; do sleep 2; done",
    ]
  }
}

data "external" "join_token" {
  depends_on = [terraform_data.manager_ready]
  program    = ["bash", "${path.module}/scripts/join_token.sh"]
  query = {
    ip  = local.manager.ip
    key = pathexpand(var.ssh_private_key_path)
  }
}

# ─── Workers and etcd VMs (same recipe, different size/role) ────────
resource "libvirt_volume" "node" {
  for_each       = local.nodes
  name           = "${each.value.name}.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.base.id
  size           = var.disk_size_bytes
}

resource "libvirt_cloudinit_disk" "node" {
  for_each = local.nodes
  name     = "${each.value.name}-init.iso"
  pool     = var.storage_pool

  user_data = templatefile("${path.module}/templates/node-user-data.yaml.tpl", {
    hostname   = each.value.name
    ssh_keys   = jsonencode(local.ssh_keys)
    manager_ip = local.manager.ip
    token      = data.external.join_token.result.token
  })
  meta_data = "instance-id: ${each.value.name}\nlocal-hostname: ${each.value.name}\n"
  network_config = templatefile("${path.module}/templates/network-config.yaml.tpl", {
    mac     = each.value.mac
    ip      = each.value.ip
    prefix  = local.prefix
    gateway = local.gateway
  })
}

resource "libvirt_domain" "node" {
  for_each   = local.nodes
  name       = each.value.name
  memory     = each.value.memory
  vcpu       = each.value.vcpu
  qemu_agent = true
  cloudinit  = libvirt_cloudinit_disk.node[each.key].id

  cpu {
    mode = "host-passthrough"
  }
  disk {
    volume_id = libvirt_volume.node[each.key].id
  }
  network_interface {
    network_id     = libvirt_network.jfn.id
    mac            = each.value.mac
    wait_for_lease = false
  }
}

# ─── Files the manager needs (single source of truth = this config) ─
resource "local_file" "etcd_stack" {
  filename = "${path.module}/swarm/generated/etcd-stack.yaml"
  content  = local.etcd_stack_yaml
}

resource "local_file" "cluster_env" {
  filename = "${path.module}/swarm/generated/cluster.env"
  content  = local.cluster_env
}
