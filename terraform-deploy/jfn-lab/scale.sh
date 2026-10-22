#!/usr/bin/env bash
# Usage: ./scale.sh <worker_count>
# Scale-out: apply, then sync ./swarm to the manager and (re)deploy.
# Scale-in:  drain the doomed workers first, apply, remove dead workers from the swarm, redeploy.
# The etcd tier is NOT touched (fixed size, set with etcd_count; change it only on a fresh cluster).
# SKIP_DEPLOY=1 ./scale.sh N  -> infrastructure only.
set -euo pipefail
cd "$(dirname "$0")"

N=${1:?usage: ./scale.sh <worker_count>}
TF=${TF:-tofu}
command -v "$TF" >/dev/null || { echo "OpenTofu (tofu) not found in PATH"; exit 1; }
KEY=${JFN_SSH_KEY:-$HOME/.ssh/jfn_lab}
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

MGR=$("$TF" output -raw manager_ip 2>/dev/null || true)
CUR=$("$TF" output -json worker_ips 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
mgr() { ssh "${SSH_OPTS[@]}" "debian@$MGR" "$@"; }

if [[ -n "$MGR" ]] && (( N < CUR )); then
  echo ">> draining workers $N..$((CUR-1))"
  for ((i=N; i<CUR; i++)); do
    mgr sudo docker node update --availability drain "jfn-worker-$i" || true
  done
  echo ">> waiting ${DRAIN_WAIT:-30}s for the drained nodes to stop"
  sleep "${DRAIN_WAIT:-30}"
fi

echo "worker_count = $N" > worker.auto.tfvars   # persists the choice
"$TF" apply -auto-approve
MGR=$("$TF" output -raw manager_ip)

if (( N < CUR )); then
  echo ">> removing dead workers from the swarm"
  sleep 15
  mgr "sudo docker node ls --format '{{.Hostname}} {{.Status}}'" \
    | awk '$1 ~ /^jfn-worker-/ && $2=="Down" {print $1}' \
    | while read -r node; do mgr sudo docker node rm --force "$node"; done
fi

if [[ "${SKIP_DEPLOY:-0}" != 1 ]]; then
  echo ">> syncing ./swarm to the manager and deploying"
  mgr 'rm -rf /tmp/jfn-swarm'
  scp "${SSH_OPTS[@]}" -q -r swarm "debian@$MGR:/tmp/jfn-swarm"
  mgr "sudo mkdir -p /opt/jfn && sudo cp -r /tmp/jfn-swarm/. /opt/jfn/ && sudo chmod +x /opt/jfn/*.sh && sudo /opt/jfn/deploy.sh"
fi
mgr sudo docker node ls
