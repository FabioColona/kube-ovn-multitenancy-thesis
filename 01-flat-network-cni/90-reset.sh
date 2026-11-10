#!/bin/bash
# 90-reset.sh — removes K3s and everything the CNIs leave on the node.
#
# What it does : runs the K3s uninstaller, deletes /etc/rancher, /var/lib/rancher, /var/lib/kubelet,
#                /etc/cni/net.d, Calico data and the vxlan.calico interface, removes the Calico, Cilium
#                and KUBE iptables rules, then checks the machine is clean.
# Environment  : the machine used for phases 10-13
# Changes      : DESTRUCTIVE (the whole cluster is deleted)
# Requires     : bash >= 4, root or sudo (the password is asked once)
# Usage        : ./90-reset.sh [--yes]
# Duration     : about 1 minute
# Exit code    : 0 = machine clean; 1 = something left; 2 = prerequisite missing
# In the thesis: not cited (support script)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
set -uo pipefail

need_sudo
confirm "This DELETES the K3s cluster and the CNI state on $(hostname). Continue?"

sec "Removing K3s and CNI state"
uninstall_k3s

sec "Checks"
k3s_installed && record "K3s uninstalled" "yes" "no" FAIL || record "K3s uninstalled" "yes" "yes" PASS
for p in 'KUBE-NWPLCY' 'cali-' 'CILIUM'; do expect "no '$p' rules left" 0 "$(count_rules "$p")"; done
[ -d /etc/rancher ] && record "/etc/rancher removed" "yes" "no" FAIL || record "/etc/rancher removed" "yes" "yes" PASS
table
