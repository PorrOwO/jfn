output "manager_ip" {
  value = local.manager.ip
}

output "worker_ips" {
  value = { for k, w in local.workers : w.name => w.ip }
}

output "etcd_ips" {
  value = { for k, e in local.etcd_nodes : e.name => e.ip }
}

output "etcd_endpoints" {
  value = local.etcd_endpoints
}

output "ssh_manager" {
  value = "ssh -i ${var.ssh_private_key_path} debian@${local.manager.ip}"
}
