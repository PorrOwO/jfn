locals {
  gateway = cidrhost(var.network_cidr, 1)
  prefix  = split("/", var.network_cidr)[1]

  manager = {
    name = "jfn-manager"
    ip   = cidrhost(var.network_cidr, 10)
    mac  = "52:54:00:6a:00:0a"
  }

  # worker i -> .(20+i), etcd i -> .(30+i). Highest index is always removed first on scale-in.
  workers = {
    for i in range(var.worker_count) : tostring(i) => {
      name = "jfn-worker-${i}"
      ip   = cidrhost(var.network_cidr, 20 + i)
      mac  = format("52:54:00:6a:01:%02x", i)
    }
  }
  etcd_nodes = {
    for i in range(var.etcd_count) : tostring(i) => {
      name = "jfn-etcd-${i}"
      ip   = cidrhost(var.network_cidr, 30 + i)
      mac  = format("52:54:00:6a:02:%02x", i)
    }
  }

  # every VM except the manager, in one map so one set of resources builds them all
  nodes = merge(
    { for k, w in local.workers : "worker-${k}" => merge(w, { role = "worker", memory = var.worker_memory_mb, vcpu = var.worker_vcpus }) },
    { for k, e in local.etcd_nodes : "etcd-${k}" => merge(e, { role = "etcd", memory = var.etcd_memory_mb, vcpu = var.etcd_vcpus }) },
  )

  ssh_keys = [for p in var.ssh_public_key_paths : trimspace(file(pathexpand(p)))]

  etcd_endpoints       = [for k, n in local.etcd_nodes : "${n.ip}:2379"]
  etcd_initial_cluster = join(",", [for k, n in local.etcd_nodes : "${n.name}=http://${n.ip}:2380"])

  # Stack that runs the fixed etcd tier: one service per member, pinned by hostname,
  # peer/client URLs use the VM IPs (known in advance), ports published in host mode.
  etcd_stack_yaml = yamlencode({
    services = {
      for k, n in local.etcd_nodes : "etcd-${k}" => {
        image = var.etcd_image
        command = [
          "/usr/local/bin/etcd",
          "--name=${n.name}",
          "--data-dir=/etcd-data",
          "--listen-client-urls=http://0.0.0.0:2379",
          "--advertise-client-urls=http://${n.ip}:2379",
          "--listen-peer-urls=http://0.0.0.0:2380",
          "--initial-advertise-peer-urls=http://${n.ip}:2380",
          "--initial-cluster=${local.etcd_initial_cluster}",
          "--initial-cluster-token=jfn-etcd",
          "--initial-cluster-state=new",
          "--heartbeat-interval=${var.etcd_heartbeat_ms}",
          "--election-timeout=${var.etcd_election_ms}",
        ]
        ports = [
          { target = 2379, published = 2379, protocol = "tcp", mode = "host" },
          { target = 2380, published = 2380, protocol = "tcp", mode = "host" },
        ]
        volumes = ["etcd-data-${k}:/etcd-data"]
        deploy = {
          replicas  = 1
          placement = { constraints = ["node.hostname == ${n.name}"] }
        }
      }
    }
    volumes = { for k, n in local.etcd_nodes : "etcd-data-${k}" => {} }
  })

  cluster_env = <<-EOT
    ETCD_ENDPOINTS="${join(" ", local.etcd_endpoints)}"
    WORKER_COUNT=${var.worker_count}
    ETCD_COUNT=${var.etcd_count}
  EOT
}
