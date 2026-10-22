#cloud-config
hostname: ${hostname}
manage_etc_hosts: true
ssh_authorized_keys: ${ssh_keys}
runcmd:
  - |
    until docker info >/dev/null 2>&1; do sleep 2; done
    for i in $(seq 1 60); do
      docker swarm join --token ${token} ${manager_ip}:2377 && break
      sleep 5
    done
