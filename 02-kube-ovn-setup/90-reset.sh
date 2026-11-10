#!/bin/bash
# 90-reset.sh — removes K3s and everything Kube-OVN leaves on the node.
#
# What it does : runs the K3s uninstaller, then removes the Kube-OVN/OVN/OVS state on the host
#                (/etc/origin/ovn, /etc/origin/openvswitch, /var/run/ovn, /var/run/openvswitch, logs)
#                and the interface genev_sys_6081; ovn0 cannot be deleted (it goes away at reboot), so it loses its
#                addresses and is brought down; then checks the machine is clean.
# Environment  : the machine used for 10-install-kube-ovn.sh
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
confirm "This DELETES the K3s cluster and the Kube-OVN state on $(hostname). Continue?"

sec "Removing K3s and Kube-OVN state"
uninstall_k3s
for l in ovn0 genev_sys_6081 br-int ovs-system; do as_root ip link delete "$l" 2>/dev/null; done
# ovn0 is an internal port of the kernel Open vSwitch datapath: it cannot be deleted ("Operation not supported")
# and disappears only at reboot. Remove its addresses and bring it down, so it does not collide with the next install.
if ip link show ovn0 >/dev/null 2>&1; then
  as_root ip addr flush dev ovn0 2>/dev/null; as_root ip link set ovn0 down 2>/dev/null
fi
as_root rm -rf /etc/origin/ovn /etc/origin/openvswitch /var/run/ovn /var/run/openvswitch /run/openvswitch \
               /var/log/ovn /var/log/openvswitch /var/log/kube-ovn /etc/cni/net.d 2>/dev/null

sec "Checks"
k3s_installed && record "K3s uninstalled" yes no FAIL || record "K3s uninstalled" yes yes PASS
for d in /etc/rancher /etc/origin/ovn /etc/origin/openvswitch /var/run/ovn; do
  [ -e "$d" ] && record "$d removed" yes no FAIL || record "$d removed" yes yes PASS
done
ip link show genev_sys_6081 >/dev/null 2>&1 && record "interface genev_sys_6081 removed" yes no FAIL || record "interface genev_sys_6081 removed" yes yes PASS
# ovn0 may still exist (see above): what matters is that it has no address and is down.
expect "ovn0 without addresses" 0 "$(ip -o addr show dev ovn0 2>/dev/null | wc -l)"
table
