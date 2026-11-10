#!/bin/bash
# 57-diag-node-pods.sh — read-only: why do the system pods of one machine not start (events and logs of the init containers).
# Usage: ./57-diag-node-pods.sh <machine number>
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -o pipefail
ns_setup
M="${ARGS[0]:?usage: ./57-diag-node-pods.sh <machine number>}"
HN="$(nssh "$M" hostname | tr -d '\r')"
F() { grep -v -E "WARNING|post-quantum|openssh|vulnerable|upgraded"; }
rks "$SERVER" <<EOS 2>&1 | F
for pat in kube-multus-ds kube-ovn-pinger; do
  P=\$(kubectl -n kube-system get pod --field-selector spec.nodeName=$HN -o name | grep "/\$pat" | head -1)
  echo "=============== \$P"
  kubectl -n kube-system describe \$P | sed -n '/Init Containers:/,/Containers:/p' | grep -E "^  [a-z]|State:|Reason:|Exit Code|Message" | head -20
  kubectl -n kube-system describe \$P | sed -n '/^Events:/,\$p' | tail -8
  for c in \$(kubectl -n kube-system get \$P -o jsonpath='{.spec.initContainers[*].name}'); do
    echo "--- log of init container \$c"; kubectl -n kube-system logs \$P -c \$c --tail=12 2>&1
  done
done
EOS
echo "=== disk and kubelet on machine $M"
nssh "$M" 'df -h / /var/lib 2>/dev/null | head -4; sudo -n journalctl -u k3s-agent --since "-10min" --no-pager 2>/dev/null | grep -i -E "error|fail" | tail -8' 2>&1 | F
