# jfn-lab: OpenTofu + Docker Swarm deployment (etcd flavour)

Layout: 1 manager VM, N worker VMs (isolated JFN nodes), a FIXED etcd tier (etcd_count VMs).

    ./scale.sh 3         # create/scale to 3 JFN nodes (applies, syncs swarm/, deploys)
    tofu destroy         # tear everything down (manager must be running)

Files
- variables.tf / locals.tf / main.tf / outputs.tf   infrastructure (libvirt) + generated swarm files
- templates/                                         cloud-init for the manager and for workers/etcd VMs
- scale.sh                                           scale workers, then deploy
- swarm/swarm-stack.yaml                             JFN bootstrapper (workers only) + nginx
- swarm/docker-compose.node.yml                      one JFN node  
- swarm/deploy.sh                                    runs on the manager: labels, nginx.conf, etcd stack, JFN stack
- swarm/generated/                                   written by tofu apply (etcd stack, cluster.env)
