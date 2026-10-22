#!/usr/bin/env bash
# jfn-diagnose.sh - READ-ONLY diagnostics for the JFN lab deployment.
# It changes nothing on the VMs. (Only if you set RUN_CATALOG_TEST=1 it also starts one
# temporary --rm container on worker 0, to capture the catalog's raw startup error.)
#
# Usage:   cd <the jfn-lab folder>  &&  ./jfn-diagnose.sh
# Output:  ./diag-<timestamp>.tar.gz   (also the unpacked folder diag-<timestamp>/)
#
# Optional environment: MGR (manager IP), JFN_SSH_KEY, LAB (tofu project folder),
#                       FLAP_SAMPLES (how many 3-second samples of the service state, default 15)
set -u
MGR=${MGR:-192.168.130.10}
KEY=${JFN_SSH_KEY:-$HOME/.ssh/jfn_lab}
export LAB=${LAB:-$PWD}
OUT=${OUT:-diag-$(date +%Y%m%d-%H%M%S)}
FLAP_SAMPLES=${FLAP_SAMPLES:-15}
mkdir -p "$OUT"
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# local_run <section> <command>        run on this machine
local_run() { { echo; echo "### [local] $2"; timeout 60 bash -c "$2" 2>&1; echo "(exit $?)"; } >>"$OUT/$1.txt"; }
# remote <section> <host> <command>    run one command on a VM
remote()    { { echo; echo "### [$2] $3"; timeout 90 "${SSH[@]}" "debian@$2" "$3" 2>&1; echo "(exit $?)"; } >>"$OUT/$1.txt"; }
# rscript <section> <host> <title> <script text>   run a multi-line script on a VM (stdin)
rscript()   { { echo; echo "### [$2] $3"; printf '%s\n' "$4" | timeout 150 "${SSH[@]}" "debian@$2" bash -s 2>&1; echo "(exit $?)"; } >>"$OUT/$1.txt"; }

finish() {
  grep -R -n -i -E 'SEVERE|exit=[1-9]|exitCode=[1-9]|oom=true|refused|denied|no such|not found|invalid|fatal|panic|SYNTAX-ERROR|failed|rejected' "$OUT" 2>/dev/null \
    | head -200 > "$OUT/00-quick-grep.txt"
  tar czf "$OUT.tar.gz" "$OUT" && echo "done: $PWD/$OUT.tar.gz"
}

# ---------------------------------------------------------------- 01 host (Fedora)
local_run 01-host 'date -u; uname -r; uptime; free -m'
local_run 01-host 'virsh -c qemu:///system list --all; virsh -c qemu:///system net-list --all; virsh -c qemu:///system vol-list default'
local_run 01-host 'docker images --digests 2>&1 | grep -E "jfn|etcd|jocker|nginx|docker " '
local_run 01-host 'cd "$LAB" && tofu output 2>&1'
local_run 01-host 'cd "$LAB" && cat worker.auto.tfvars 2>&1; grep -n -E "etcd_image|golden_image_path|base_volume_name" -A2 variables.tf'
local_run 01-host 'cat "$LAB/swarm/generated/cluster.env"; echo ---; cat "$LAB/swarm/generated/etcd-stack.yaml"'
local_run 01-host 'cd "$LAB/swarm" && sha256sum *.yml *.yaml *.sh *.tpl generated/* 2>&1'

# ---------------------------------------------------------------- reachability + discovery
if ! "${SSH[@]}" "debian@$MGR" true 2>/dev/null; then
  echo "Cannot ssh to the manager ($MGR) with key $KEY. Is the lab up? (see 01-host.txt)" | tee "$OUT/00-FATAL.txt"
  finish; exit 1
fi
NODES=$("${SSH[@]}" "debian@$MGR" 'sudo docker node ls -q | xargs -r sudo docker node inspect --format "{{.Description.Hostname}} {{.Status.Addr}} {{.Status.State}}"' 2>/dev/null)
printf '%s\n' "$NODES" > "$OUT/02-nodes-discovered.txt"
mapfile -t WORKERS < <(awk '$1 ~ /^jfn-worker-/ {print $2}' <<<"$NODES" | sort -V)
mapfile -t ETCDS   < <(awk '$1 ~ /^jfn-etcd-/ {print $2}'   <<<"$NODES" | sort -V)
((${#WORKERS[@]})) || WORKERS=(192.168.130.20 192.168.130.21 192.168.130.22)
((${#ETCDS[@]}))   || ETCDS=(192.168.130.30 192.168.130.31 192.168.130.32)

# ---------------------------------------------------------------- 10 manager / swarm
M=10-manager
remote $M "$MGR" 'date -u; uptime; free -m; df -h /'
remote $M "$MGR" 'sudo docker node ls'
remote $M "$MGR" 'for n in $(sudo docker node ls -q); do sudo docker node inspect $n --format "{{.Description.Hostname}} state={{.Status.State}} avail={{.Spec.Availability}} labels={{.Spec.Labels}} addr={{.Status.Addr}}"; done'
remote $M "$MGR" 'sudo docker stack ls; sudo docker stack services jfn; sudo docker stack services jfn-etcd'
remote $M "$MGR" 'sudo docker service ps jfn_node-bootstrapper --no-trunc'
remote $M "$MGR" 'sudo docker service ps jfn_nginx --no-trunc'
remote $M "$MGR" 'sudo docker stack ps jfn-etcd --no-trunc'
remote $M "$MGR" 'sudo docker service inspect jfn_node-bootstrapper --pretty'
remote $M "$MGR" 'sudo docker service inspect jfn_node-bootstrapper --format "{{json .Spec.TaskTemplate.ContainerSpec}}"'
remote $M "$MGR" 'sudo docker service inspect jfn_node-bootstrapper --format "{{index .Spec.TaskTemplate.ContainerSpec.Args 2}}"'
remote $M "$MGR" 'sudo docker service inspect jfn_node-bootstrapper --format "{{index .Spec.TaskTemplate.ContainerSpec.Args 2}}" | sh -n && echo SYNTAX-OK || echo SYNTAX-ERROR'
remote $M "$MGR" 'sudo docker service logs --timestamps --tail 150 jfn_node-bootstrapper'
remote $M "$MGR" 'sudo docker service logs --timestamps --tail 60 jfn_nginx'
remote $M "$MGR" 'for s in etcd-0 etcd-1 etcd-2; do echo "--- $s"; sudo docker service logs --timestamps --tail 30 jfn-etcd_$s 2>&1; done'
remote $M "$MGR" 'sudo docker config ls; for c in $(sudo docker config ls -q); do echo "--- config $c"; sudo docker config inspect --pretty $c; done'
remote $M "$MGR" 'ls -la /opt/jfn /opt/jfn/generated; cat /opt/jfn/generated/cluster.env; echo ---; cat /opt/jfn/nginx.conf; echo ---; cd /opt/jfn && sha256sum *.yml *.yaml *.sh *.tpl generated/*'
remote $M "$MGR" "sudo docker run --rm -v /opt/jfn:/jfn:ro -v /var/run/docker.sock:/var/run/docker.sock -e ETCD_ENDPOINT=${ETCDS[0]}:2379 docker:25-cli docker compose -p jfn -f /jfn/docker-compose.node.yml config 2>&1 | head -100"
remote $M "$MGR" 'sudo docker images --digests'
remote $M "$MGR" 'sudo docker events --since 40m --until "$(date -Iseconds)" --filter event=die --format "{{.Time}} {{.Actor.Attributes.name}} exitCode={{.Actor.Attributes.exitCode}}" | tail -40'
remote $M "$MGR" 'sudo journalctl -u docker --since "40 min ago" --no-pager | tail -60'

# ---------------------------------------------------------------- 20 workers
WSCRIPT=$(cat <<'EOS'
echo "== time/resources"; date -u; uptime; free -m; df -h /
echo "== containers (all)"; docker ps -a --no-trunc --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.CreatedAt}}'
echo "== images"; docker images --digests
echo "== networks"; docker network ls; docker network inspect jfn --format '{{json .IPAM.Config}}' 2>&1
echo "== compose projects"; docker compose ls -a 2>&1
echo "== state and last logs of the 12 newest containers"
for c in $(docker ps -aq | head -12); do
  echo "--- $c"
  docker inspect -f '{{.Name}} image={{.Config.Image}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err={{.State.Error}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' "$c"
  docker logs --tail 40 --timestamps "$c" 2>&1
done
echo "== die events, last 40 min"
docker events --since 40m --until "$(date -Iseconds)" --filter event=die --format '{{.Time}} {{.Actor.Attributes.name}} exitCode={{.Actor.Attributes.exitCode}}' 2>&1 | tail -60
echo "== docker daemon log"; sudo journalctl -u docker --since '40 min ago' --no-pager 2>&1 | tail -60
echo "== kernel OOM / kills"; sudo dmesg 2>&1 | grep -i -E 'oom|out of memory|killed process' | tail -10
echo "== listening ports"; ss -ltn | grep -E ':(8000|8001|8002|2379|2380)\b'
EOS
)
ECHECK="echo '== etcd health as seen from this VM'"
for ip in "${ETCDS[@]}"; do ECHECK+=$'\n'"echo -n '$ip: '; curl -s -m 5 http://$ip:2379/health; echo"; done
for ip in "${WORKERS[@]}"; do
  rscript "20-worker-$ip" "$ip" "worker state" "$WSCRIPT"$'\n'"$ECHECK"
done

# ---------------------------------------------------------------- 30 etcd VMs
ESCRIPT=$(cat <<'EOS'
echo "== time/resources"; date -u; uptime; free -m; df -h /
echo "== containers"; docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
echo "== etcd logs"; c=$(docker ps -aqf name=etcd | head -1); docker logs --tail 40 --timestamps "$c" 2>&1
echo "== etcdctl"; c=$(docker ps -qf name=etcd | head -1)
docker exec "$c" etcdctl --endpoints=http://127.0.0.1:2379 member list -w table 2>&1
docker exec "$c" etcdctl --endpoints=http://127.0.0.1:2379 endpoint status --cluster -w table 2>&1
docker exec "$c" etcdctl --endpoints=http://127.0.0.1:2379 endpoint health --cluster 2>&1
echo "== listening"; ss -ltn | grep -E ':(2379|2380)\b'
echo "== die events"; docker events --since 40m --until "$(date -Iseconds)" --filter event=die --format '{{.Time}} {{.Actor.Attributes.name}} exitCode={{.Actor.Attributes.exitCode}}' 2>&1 | tail -30
EOS
)
for ip in "${ETCDS[@]}"; do rscript "30-etcd-$ip" "$ip" "etcd node state" "$ESCRIPT"; done

# ---------------------------------------------------------------- 40 service state over time (shows flapping)
FLAP=$(cat <<EOS
for i in \$(seq 1 $FLAP_SAMPLES); do
  echo "--- \$(date -u +%T)"
  sudo docker stack services jfn --format '{{.Name}} {{.Replicas}}'
  sudo docker service ps jfn_node-bootstrapper --no-trunc --format '{{.Node}} {{.CurrentState}} | {{.Error}}' | head -9
  sleep 3
done
EOS
)
rscript 40-flapping "$MGR" "service state sampled every 3 s" "$FLAP"

# ---------------------------------------------------------------- 60 optional catalog test
if [[ "${RUN_CATALOG_TEST:-0}" == 1 ]]; then
  W0=${WORKERS[0]}; E0=${ETCDS[0]}
  for tag in etcd latest; do
    rscript 60-catalog-test "$W0" "catalog image :$tag, temporary container (removed on exit)" "
docker image inspect jfn/function_catalog:$tag >/dev/null 2>&1 || { echo 'image tag not present on this VM'; exit 0; }
timeout 25 docker run --rm --name jfn-diag-catalog-$tag --network jfn -e FUNCTION_CATALOG_LOCATION=socket://0.0.0.0:8002 -e ETCD_LOCATION=socket://$E0:2379 -e VERBOSE=true jfn/function_catalog:$tag 2>&1 | head -40"
  done
fi

finish
