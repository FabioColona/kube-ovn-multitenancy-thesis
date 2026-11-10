#!/bin/bash
# 90-reset.sh — removes everything the north-south scripts created: the cluster and the simulated customer network.
#
# What it does : on every machine of NODES removes K3s (server and agent), the Kube-OVN state, the interface EXT_NIC, the
#                VXLAN interfaces, the bridge br-priv and the namespaces "fabric" and "cust"; then checks they are gone.
# Environment  : the machines of config.env
# Changes      : DESTRUCTIVE (the whole cluster is deleted)
# Requires     : bash >= 3.2, ssh, scp; passwordless sudo on the machines
# Usage        : ./90-reset.sh [--yes]
# Variables    : NODES, NODE_USER, SSH_JUMP, REMOTE_DIR (from config.env)
# Duration     : about 2 minutes
# Exit code    : 0 = machines clean; 1 = something left; 2 = prerequisite missing
# In the thesis: not cited (support script)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars REMOTE_DIR

N=$(node_n)
confirm "This DELETES the cluster and the simulated customer network on all $N machines. Continue?"

CLEAN_SH=$(cat <<'EOS'
ip netns del fabric 2>/dev/null; ip netns del cust 2>/dev/null
for l in $(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^(vxg[0-9]+|br-priv|ext0p?|fab-br)$'); do ip link del "$l" 2>/dev/null; done
[ -x /usr/local/bin/k3s-agent-uninstall.sh ] && /usr/local/bin/k3s-agent-uninstall.sh >/dev/null 2>&1
echo done
EOS
)
for ((i=1;i<=N;i++)); do
  sec "Machine $i ($(node_host "$i"))"
  nroot "$i" <<<"$CLEAN_SH" >/dev/null 2>&1
  unfix_nic_prefix "$i"
  if nssh "$i" '[ -x /usr/local/bin/k3s-uninstall.sh ]' 2>/dev/null; then
    push_repo "$i" && nssh "$i" "cd \"\$HOME/$REMOTE_DIR/02-kube-ovn-setup\" && NO_PROGRESS=1 ./90-reset.sh --yes" | tail -14
  fi
  K=$(nssh "$i" '[ -x /usr/local/bin/k3s ] || [ -x /usr/local/bin/k3s-uninstall.sh ] && echo yes || echo no')
  NSL=$(nssh "$i" 'sudo -n ip netns list | grep -cE "^(fabric|cust)"')
  LK=$(nssh "$i" 'ip -o link show | awk -F": " "{print \$2}" | sed "s/@.*//" | grep -cE "^(vxg[0-9]+|br-priv|ext0p?|fab-br)$"')
  expect "machine $i: K3s removed" no "$K"
  expect "machine $i: namespaces fabric/cust removed" 0 "${NSL:-0}"
  expect "machine $i: bridge and VXLAN/veth interfaces removed" 0 "${LK:-0}"
done
ns_close
table
