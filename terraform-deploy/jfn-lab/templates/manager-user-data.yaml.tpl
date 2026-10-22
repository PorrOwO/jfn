#cloud-config
hostname: ${hostname}
manage_etc_hosts: true
ssh_authorized_keys: ${ssh_keys}
runcmd:
  - |
    until docker info >/dev/null 2>&1; do sleep 2; done
    docker swarm init --advertise-addr ${manager_ip}
