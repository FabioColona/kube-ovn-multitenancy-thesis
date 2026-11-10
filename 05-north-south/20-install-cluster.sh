#!/bin/bash
# 20-install-cluster.sh — installs a multi-node K3s cluster with Kube-OVN on the machines of CLUSTER_NODES.
#
# What it does : copies the repository to machine 1, runs there 02-kube-ovn-setup/10-install-kube-ovn.sh (K3s server +
#                Kube-OVN), then joins every other cluster machine as a K3s agent (kernel modules, sysctl and the OVS
#                directory prepared as in the single-node script). Checks that all nodes are Ready, that every node runs
#                kube-ovn-cni and ovs-ovn, and that two pods on different nodes reach each other with full-size packets
#                (the pod MTU is read from the pod).
# Environment  : the machines of config.env; Internet access; phase 00 without FAIL
# Changes      : CHANGES THE MACHINES (installs K3s, adds a /24 copy of a /32 NIC address, loads kernel modules, writes sysctl and modules-load files, turns swap
#                off until reboot; refuses to run if K3s is already there)
# Requires     : bash >= 3.2, ssh, scp; passwordless sudo on the machines
# Usage        : ./20-install-cluster.sh [--yes]
# Variables    : NODES, NODE_USER, SSH_JUMP, CLUSTER_NODES, NIC_PREFIX_FIX, K3S_VERSION, KUBEOVN_VERSION, POD_CIDR, SVC_CIDR, JOIN_CIDR,
#                CHECK_IMAGE, REMOTE_DIR (from config.env)
# Duration     : about 8 minutes (5 for the server, 2 per agent)
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing or installation failed
# In the thesis: Chapter 6 (north-south test bed)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
. "$HERE/lib-ns.sh"
set -uo pipefail
ns_setup
require_vars K3S_VERSION KUBEOVN_VERSION POD_CIDR SVC_CIDR JOIN_CIDR CHECK_IMAGE REMOTE_DIR

NC=0; for i in $CLUSTER_NODES; do NC=$((NC+1)); done
sec "1. Before installing"
if [ "${RESUME:-}" != yes ]; then
for i in $CLUSTER_NODES; do
  nssh "$i" '[ -x /usr/local/bin/k3s ]' && die "K3s is already on machine $i: run ./90-reset.sh first"
done
fi
echo "  K3s $K3S_VERSION, Kube-OVN $KUBEOVN_VERSION; server: machine $SERVER; machines in the cluster: $CLUSTER_NODES"
confirm "This installs K3s and Kube-OVN on the machines above. Continue?"

sec "1b. NIC address of every cluster machine"
for i in $CLUSTER_NODES; do
  fix_nic_prefix "$i" || die "cannot prepare the NIC address of machine $i"
  info "machine $i: $(nssh "$i" "ip -4 -o addr show dev $(node_iface "$i") | awk '{print \$4}'" | tr '\n' ' ')"
done

sec "2. Server (machine $SERVER)"
push_repo "$SERVER" || die "cannot copy the repository to machine $SERVER"
SIP=$(node_ip "$SERVER"); SIF=$(node_iface "$SERVER")
[ -n "$SIP" ] && [ -n "$SIF" ] || die "cannot read the address or interface of machine $SERVER"
if [ "${RESUME:-}" = yes ]; then info "RESUME=yes: server already installed on machine $SERVER, skipping its installation"; else
if run_spin "installing K3s and Kube-OVN on machine $SERVER" "about 5 minutes" \
     nssh "$SERVER" "cd \"\$HOME/$REMOTE_DIR/02-kube-ovn-setup\" && POD_CIDR=$POD_CIDR SVC_CIDR=$SVC_CIDR JOIN_CIDR=$JOIN_CIDR NODE_IFACE=$SIF NODE_IP=$SIP ALLOW_STOP_HOST_OVS=yes K3S_VERSION=$K3S_VERSION KUBEOVN_VERSION=$KUBEOVN_VERSION CHECK_IMAGE=$CHECK_IMAGE NO_PROGRESS=1 ./10-install-kube-ovn.sh --yes"; then
  tail -22 "$RUN_LOG"
else
  tail -30 "$RUN_LOG"; die "the installation on machine $SERVER failed (last lines above)"
fi
fi

# Script run on every agent (stdin; TOKEN is the first line, the other variables are in the environment).
JOIN_SH=$(cat <<'EOS'
set -e
for m in openvswitch geneve ip_tables iptable_nat br_netfilter overlay; do modprobe "$m" 2>/dev/null || true; done
printf "openvswitch\ngeneve\nip_tables\niptable_nat\nbr_netfilter\noverlay\n" > /etc/modules-load.d/kube-ovn.conf
grep -q '^openvswitch ' /proc/modules || { echo "kernel module openvswitch missing"; exit 3; }
printf "net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n" > /etc/sysctl.d/99-kube-ovn.conf
sysctl --system >/dev/null
swapoff -a
mkdir -p /run/openvswitch /var/run/openvswitch; chmod 755 /run/openvswitch
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_URL="https://$SERVER_IP:6443" K3S_TOKEN="$TOKEN" \
  INSTALL_K3S_EXEC="agent --node-ip=$NODE_IP" sh - >/dev/null 2>&1
systemctl is-active k3s-agent
EOS
)
_join() { nroot "$1" K3S_VERSION="$K3S_VERSION" SERVER_IP="$SIP" NODE_IP="$2" <<<"TOKEN='$TOKEN'"$'\n'"$JOIN_SH"; }

TOKEN=$(nssh "$SERVER" "sudo -n cat /var/lib/rancher/k3s/server/node-token")
[ -n "$TOKEN" ] || die "cannot read the K3s token on machine $SERVER"
for i in $CLUSTER_NODES; do
  [ "$i" = "$SERVER" ] && continue
  sec "3. Agent (machine $i)"
  if run_spin "joining machine $i" "about 2 minutes" _join "$i" "$(node_ip "$i")"; then info "k3s-agent: $(tail -1 "$RUN_LOG")"
  else tail -10 "$RUN_LOG"; die "machine $i could not join (last lines above)"; fi
done

sec "4. Checks"
_ready() { [ "$(rk "$SERVER" 'kubectl get nodes --no-headers' | awk '$2=="Ready"{c++} END{print c+0}')" -ge "$NC" ]; }
WAIT_MSG="waiting for $NC nodes Ready" waitf 60 5 _ready
READY=$(rk "$SERVER" 'kubectl get nodes --no-headers' | awk '$2=="Ready"{c++} END{print c+0}')
expect "nodes Ready" "$NC" "$READY"
_pods() { rk "$SERVER" 'kubectl -n kube-system get pods --no-headers' | grep -E "^$1-" | awk '{split($2,a,"/")} a[1]==a[2] && $3=="Running"{c++} END{print c+0}'; }
_cni_ready() { [ "$(_pods kube-ovn-cni)" -ge "$NC" ] && [ "$(_pods ovs-ovn)" -ge "$NC" ]; }
WAIT_MSG="waiting for kube-ovn-cni and ovs-ovn on every node" waitf 40 5 _cni_ready
expect "kube-ovn-cni pods Running" "$NC" "$(_pods kube-ovn-cni)"
expect "ovs-ovn pods Running" "$NC" "$(_pods ovs-ovn)"

if [ "$NC" -ge 2 ]; then
  set -- $CLUSTER_NODES; A=$1; B=$2
  NA=$(nssh "$A" hostname | tr -d '\r'); NB=$(nssh "$B" hostname | tr -d '\r')
  rks "$SERVER" >/dev/null 2>&1 <<EOS
kubectl delete namespace ns-check --ignore-not-found --wait=true
kubectl create namespace ns-check
kubectl -n ns-check run p1 --image=$CHECK_IMAGE --restart=Never --overrides='{"spec":{"nodeName":"$NA"}}' -- sleep 3600
kubectl -n ns-check run p2 --image=$CHECK_IMAGE --restart=Never --overrides='{"spec":{"nodeName":"$NB"}}' -- sleep 3600
EOS
  if run_spin "waiting for the test pods (one on $NA, one on $NB)" "image download, up to 3 minutes" rk "$SERVER" 'kubectl -n ns-check wait --for=condition=Ready pod/p1 pod/p2 --timeout=180s'; then
    P2=$(rk "$SERVER" "kubectl -n ns-check get pod p2 -o jsonpath='{.status.podIP}'")
    PM=$(rk "$SERVER" "kubectl -n ns-check exec p1 -- cat /sys/class/net/eth0/mtu" | tr -d '\r')
    NM=$(node_mtu "$A")
    echo "  pod MTU on eth0: $PM (NIC MTU $NM)"
    expect "pod on $NA -> pod on $NB (ping)" ok "$(rk "$SERVER" "kubectl -n ns-check exec p1 -- ping -c 3 -W 2 $P2 >/dev/null 2>&1 && echo ok || echo fail")"
    # The BusyBox ping of the check image has no -M (do not fragment): the test with the DF flag is in 30-nat-gateway.sh.
    expect "cross-node packets of pod MTU size ($PM bytes)" ok "$(rk "$SERVER" "kubectl -n ns-check exec p1 -- ping -c 3 -W 2 -s $((PM-28)) $P2 >/dev/null 2>&1 && echo ok || echo fail")"
    record "pod MTU (informational)" "any" "$PM" PASS
  else
    record "test pods ready" yes no FAIL
  fi
  rk "$SERVER" 'kubectl delete namespace ns-check --wait=false' >/dev/null 2>&1
fi
echo "K3s: $(rk "$SERVER" 'k3s --version | head -1')   Kube-OVN: $(rk "$SERVER" "kubectl -n kube-system get deploy kube-ovn-controller -o jsonpath='{.spec.template.spec.containers[0].image}'")"
table
