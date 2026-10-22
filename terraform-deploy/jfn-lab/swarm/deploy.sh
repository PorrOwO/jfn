#!/usr/bin/env bash
# Runs ON THE MANAGER as root (scale.sh calls it). Idempotent.
#  1. waits for the expected workers and etcd VMs to be Ready in the swarm
#  2. labels them (jfn-role=worker|etcd)
#  3. regenerates nginx.conf from the live worker list
#  4. deploys the etcd stack and waits until every member is healthy
#  5. deploys the JFN stack (one JFN node per worker + nginx)
set -euo pipefail
cd "$(dirname "$0")"
source generated/cluster.env        # ETCD_ENDPOINTS, WORKER_COUNT, ETCD_COUNT
export ETCD_ENDPOINTS

# "<hostname> <ip>" of READY swarm nodes whose hostname starts with $1
ready_nodes() {
  docker node ls --format '{{.ID}} {{.Hostname}}' \
    | awk -v p="$1" 'index($2,p)==1 {print $1}' \
    | xargs -r docker node inspect --format '{{.Description.Hostname}} {{.Status.Addr}} {{.Status.State}}' \
    | awk '$3=="ready" {print $1, $2}' | sort -V
}

echo ">> waiting for $WORKER_COUNT workers and $ETCD_COUNT etcd VMs"
for _ in $(seq 1 120); do
  w=$(ready_nodes jfn-worker- | wc -l); e=$(ready_nodes jfn-etcd- | wc -l)
  (( w >= WORKER_COUNT && e >= ETCD_COUNT )) && break
  sleep 3
done
if (( w < WORKER_COUNT || e < ETCD_COUNT )); then
  echo "!! timeout: $w/$WORKER_COUNT workers, $e/$ETCD_COUNT etcd VMs ready"; docker node ls; exit 1
fi

ready_nodes jfn-worker- | while read -r h _; do docker node update --label-add jfn-role=worker "$h" >/dev/null; done
ready_nodes jfn-etcd-   | while read -r h _; do docker node update --label-add jfn-role=etcd   "$h" >/dev/null; done

SERVERS=$(ready_nodes jfn-worker- | awk '{print "        server " $2 ":8000 max_fails=2 fail_timeout=5s;"}')
[[ -n "$SERVERS" ]] || SERVERS="    server 127.0.0.1:1 down;"
tpl=$(<nginx.conf.tpl)
printf '%s\n' "${tpl/@@SERVERS@@/$SERVERS}" > nginx.conf   # replaces the FIRST marker only; '>' keeps the inode
# validate the generated config before anything uses it
if ! docker run --rm -v "$PWD/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:alpine nginx -t >/tmp/nginx-test.log 2>&1; then
  echo "!! generated nginx.conf is invalid:"; cat /tmp/nginx-test.log; exit 1
fi

echo ">> deploying etcd"
docker stack deploy --prune --resolve-image never -c generated/etcd-stack.yaml jfn-etcd
ok=0
for _ in $(seq 1 60); do
  ok=1
  for ep in $ETCD_ENDPOINTS; do
    curl -fsS --max-time 3 "http://$ep/health" 2>/dev/null | grep -q '"health":"true"' || ok=0
  done
  (( ok )) && break
  sleep 3
done
if (( ! ok )); then echo "!! etcd is not healthy"; docker stack ps jfn-etcd --no-trunc; exit 1; fi
echo ">> etcd healthy on: $ETCD_ENDPOINTS"

echo ">> deploying JFN"
export NODE_COMPOSE_HASH=$(sha256sum docker-compose.node.yml | cut -c1-12)
docker stack deploy --prune --resolve-image never -c swarm-stack.yaml jfn

cid=$(docker ps -q --filter name=jfn_nginx | head -n1 || true)
if [[ -n "$cid" ]]; then docker kill -s HUP "$cid" >/dev/null && echo ">> nginx reloaded"; fi
docker stack services jfn; docker stack services jfn-etcd
