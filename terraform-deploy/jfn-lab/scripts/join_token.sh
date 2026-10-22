#!/usr/bin/env bash
# Called by the OpenTofu "external" data source: reads {"ip","key"} on stdin,
# prints {"token": "..."} on stdout. Requires jq.
set -euo pipefail
eval "$(jq -r '@sh "IP=\(.ip) KEY=\(.key)"')"
TOKEN=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "debian@$IP" sudo docker swarm join-token -q worker)
jq -n --arg token "$TOKEN" '{token: $token}'
