#!/bin/bash
# 62-persist-gateway-machine.sh — makes the external interface of gateway machines survive a reboot (boot service gw-ext).
#
# What it does : on each given machine installs /usr/local/sbin/gw-ext-boot.sh and the systemd unit gw-ext.service, which runs
#                at boot BEFORE K3s and rebuilds what 10-external-network.sh and 31-ovn-gateway.sh created by hand and a reboot
#                removes: the address with prefix NIC_PREFIX_FIX on the NIC (when the NIC address is a /32), the VXLAN interface
#                EXT_NIC towards the fabric machine (same VNI, addresses and MTU as 10-external-network.sh) and the network
#                namespace ovnext (ECMP+BFD mode). A crashed machine then comes back as a real server would, without
#                ./52-recover-gateway-machine.sh, and ./50-gateway-failure.sh ovngw crash can run several repetitions.
#                The values are those of NOW: if CrownLabs gives the machine a new address (power-off), run it again.
# Environment  : the cluster and the external network of this folder (10-external-network.sh done)
# Changes      : CHANGES THE MACHINES (a script in /usr/local/sbin and a systemd unit); --remove takes them away
# Usage        : ./62-persist-gateway-machine.sh <machine> [<machine> ...] [--remove] [--yes]
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 6 (failures: reboot of a gateway machine)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
REMOVE=no; MS=""
for a in "${ARGS[@]:-}"; do case "$a" in --remove) REMOVE=yes ;; "") ;; *) MS="$MS $a" ;; esac; done
MS="${MS# }"; [ -n "$MS" ] || die "usage: ./62-persist-gateway-machine.sh <machine> [<machine> ...] [--remove]"
F="$FABRIC_NODE"
FIP=$(node_ip "$F"); NICMTU=$(node_mtu "$F"); MTU="${EXT_MTU:-$((NICMTU-50))}"
[ -n "$FIP" ] && [ -n "$NICMTU" ] || die "cannot read the address or the MTU of the fabric machine"

for M in $MS; do
  sec "Machine $M"
  if [ "$REMOVE" = yes ]; then
    nroot "$M" <<'EOS' >/dev/null 2>&1
systemctl disable gw-ext.service; rm -f /etc/systemd/system/gw-ext.service /usr/local/sbin/gw-ext-boot.sh; systemctl daemon-reload
EOS
    expect "machine $M: gw-ext.service removed" absent "$(nssh "$M" 'systemctl is-enabled gw-ext.service 2>/dev/null || echo absent' | tr -d '\r' | tail -1)"
    continue
  fi
  NIP=$(node_ip "$M"); NIF=$(node_iface "$M")
  [ -n "$NIP" ] && [ -n "$NIF" ] || die "cannot read the address or the interface of machine $M"
  nroot "$M" NIP="$NIP" NIF="$NIF" PFX="${NIC_PREFIX_FIX:-}" EXT_NIC="$EXT_NIC" VNI="$((EXT_VNI+M))" FIP="$FIP" MTU="$MTU" <<'EOS' >/dev/null 2>&1
cat > /usr/local/sbin/gw-ext-boot.sh <<EOF
#!/bin/sh
# written by 62-persist-gateway-machine.sh: rebuilds the external interface of this gateway machine at boot
for i in \$(seq 1 30); do ip -4 -o addr show dev $NIF | grep -q "inet $NIP/" && break; sleep 1; done
if [ -n "$PFX" ] && ip -4 -o addr show dev $NIF | grep -q "inet $NIP/32 "; then
  ip addr show dev $NIF | grep -q "inet $NIP/$PFX " || ip addr add $NIP/$PFX dev $NIF noprefixroute
fi
ip link show $EXT_NIC >/dev/null 2>&1 || ip link add $EXT_NIC type vxlan id $VNI local $NIP remote $FIP dstport 4789 dev $NIF
ip link set $EXT_NIC mtu $MTU up
ip netns list | grep -q '^ovnext' || ip netns add ovnext
exit 0
EOF
chmod 755 /usr/local/sbin/gw-ext-boot.sh
cat > /etc/systemd/system/gw-ext.service <<EOF
[Unit]
Description=External VXLAN interface of the gateway (thesis lab)
After=network-online.target
Wants=network-online.target
Before=k3s.service k3s-agent.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gw-ext-boot.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable gw-ext.service
EOS
  expect "machine $M: gw-ext.service enabled" enabled "$(nssh "$M" 'systemctl is-enabled gw-ext.service 2>/dev/null' | tr -d '\r' | tail -1)"
  expect "machine $M: boot script for $EXT_NIC (VNI $((EXT_VNI+M)), remote fabric)" yes "$(nssh "$M" "grep -q 'id $((EXT_VNI+M)) local $NIP remote $FIP' /usr/local/sbin/gw-ext-boot.sh && echo yes || echo no" | tr -d '\r')"
done
table
