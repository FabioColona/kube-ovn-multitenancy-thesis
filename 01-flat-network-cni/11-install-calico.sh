#!/bin/bash
# 11-install-calico.sh — installs a single-node K3s with Calico, in iptables or eBPF mode.
#
# What it does : installs K3s without Flannel and without its policy controller, then Calico (Tigera operator,
#                pod CIDR from config.env) and waits for it.
#                iptables = classic dataplane, kube-proxy is kept;
#                ebpf     = BPF dataplane with VXLAN (IPIP is not supported in eBPF), K3s starts WITHOUT kube-proxy
#                           and the operator is told where the API server is (the service IP 10.43.0.1 is
#                           unreachable at start without kube-proxy).
#                Checks node, Calico status, dataplane, and the iptables rules / eBPF state.
# Environment  : any Linux machine (x86_64 or aarch64) with systemd and Internet access;
#                eBPF mode also needs kernel >= 5.10 with the BPF filesystem
# Changes      : CHANGES THE MACHINE (installs K3s and Calico; refuses to run if K3s is already there)
# Requires     : bash >= 4, curl, root or sudo (the password is asked once), phase 00 without FAIL
# Usage        : ./11-install-calico.sh [iptables|ebpf] [--yes]       (default: CALICO_MODE from config.env)
# Variables    : K3S_VERSION, CALICO_VERSION, CALICO_MODE, CALICO_BPF_DISABLE_CONNECT_LB, POD_CIDR, NODE_HOSTNAME
# Duration     : 5-20 minutes (Calico images are large; about 19 minutes on a slow link)
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing or installation failed
# In the thesis: Section 3.5 (tests closed-door and blind-spot, Calico installation)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
ARGS=(); for a in "$@"; do case "$a" in iptables|ebpf) CALICO_MODE_ARG=$a;; *) ARGS+=("$a");; esac; done
parse_common_options "${ARGS[@]+"${ARGS[@]}"}"
load_config "$HERE"
set -uo pipefail
MODE="${CALICO_MODE_ARG:-${CALICO_MODE:-iptables}}"
case "$MODE" in iptables|ebpf) ;; *) die "mode must be iptables or ebpf (got '$MODE')";; esac

need_sudo
k3s_installed && die "K3s is already installed: run ./90-reset.sh first"
require_vars CALICO_VERSION POD_CIDR
confirm "This installs K3s $K3S_VERSION with Calico $CALICO_VERSION ($MODE) on $(hostname). Continue?"

EXTRA=""; [ "$MODE" = ebpf ] && EXTRA="--disable-kube-proxy"
sec "Installing K3s $K3S_VERSION (no Flannel, no policy controller, $MODE mode, pod CIDR $POD_CIDR)"
if [ -n "${NODE_HOSTNAME:-}" ]; then as_root hostnamectl set-hostname "$NODE_HOSTNAME"; fi
install_k3s "--flannel-backend=none --disable-network-policy $EXTRA --cluster-cidr=$POD_CIDR"

sec "Installing the Tigera operator $CALICO_VERSION"
BASE="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests"
kubectl create -f "$BASE/tigera-operator.yaml" >/dev/null || die "cannot install the Tigera operator"

if [ "$MODE" = ebpf ]; then
  MY_IP=$(hostname -I | awk '{print $1}')
  [ -n "$MY_IP" ] || die "cannot find the IP address of this machine"
  kubectl wait --for=condition=Available deploy/tigera-operator -n tigera-operator --timeout=600s >/dev/null 2>&1 \
    || die "the Tigera operator did not start"
  sec "Telling Calico where the API server is ($MY_IP:6443)"
  kubectl apply -f - >/dev/null <<EOT
kind: ConfigMap
apiVersion: v1
metadata: {name: kubernetes-services-endpoint, namespace: tigera-operator}
data: {KUBERNETES_SERVICE_HOST: "$MY_IP", KUBERNETES_SERVICE_PORT: "6443"}
EOT
  # The operator reads the ConfigMap only at start-up: restart it.
  kubectl rollout restart deploy/tigera-operator -n tigera-operator >/dev/null
  kubectl rollout status deploy/tigera-operator -n tigera-operator --timeout=300s >/dev/null || die "operator restart failed"
fi

sec "Creating the Calico resources ($MODE, CIDR $POD_CIDR)"
# The default pool is 192.168.0.0/16: replaced with POD_CIDR so it does not overlap the LAN.
if [ "$MODE" = ebpf ]; then
  curl -sfL "$BASE/custom-resources.yaml" \
    | sed -e "s#192.168.0.0/16#${POD_CIDR}#" -e 's#encapsulation: VXLANCrossSubnet#encapsulation: VXLAN#' \
          -e 's#calicoNetwork:#calicoNetwork:\n    linuxDataplane: BPF#' \
    | kubectl create -f - >/dev/null || die "cannot create the Calico resources"
else
  curl -sfL "$BASE/custom-resources.yaml" | sed "s#192.168.0.0/16#${POD_CIDR}#" | kubectl create -f - >/dev/null \
    || die "cannot create the Calico resources"
fi

if [ "$MODE" = ebpf ] && [ "${CALICO_BPF_DISABLE_CONNECT_LB:-yes}" = yes ]; then
  # Must happen BEFORE waiting for Calico: on kernel 7.0 calico-node crashes at start (the kernel rejects the
  # program calico_sendmsg_v46) and Calico never becomes Available. The FelixConfiguration "default" appears
  # when calico-node starts for the first time; we patch it and restart calico-node.
  sec "Disabling connect-time load balancing (kernel 7.0 rejects the program calico_sendmsg_v46)"
  waitf 120 5 kubectl get felixconfiguration default || die "FelixConfiguration 'default' was not created"
  kubectl patch felixconfiguration default --type merge -p '{"spec":{"bpfConnectTimeLoadBalancing":"Disabled"}}' >/dev/null \
    || die "cannot patch the FelixConfiguration"
  kubectl rollout restart ds/calico-node -n calico-system >/dev/null
fi

sec "Waiting for Calico (it downloads several images)"
waitf 300 5 kubectl get tigerastatus calico || die "tigerastatus/calico was not created"
kubectl wait --for=condition=Available tigerastatus/calico --timeout=1800s >/dev/null 2>&1 && CAL=Available || CAL=NotAvailable
wait_node_ready 600 && NODE=Ready || NODE=NotReady
kubectl get nodes -o wide

# Available can be reported while calico-node is crashing (for example with an eBPF program that the kernel refuses):
# the check also requires that calico-node does not restart during one minute
if [ "$CAL" = Available ]; then
  r0=$(kubectl -n calico-system get pods -l k8s-app=calico-node -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END{print s+0}')
  sleep 60
  r1=$(kubectl -n calico-system get pods -l k8s-app=calico-node -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END{print s+0}')
  rd=$(kubectl -n calico-system get ds calico-node -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)
  { [ "$r1" = "$r0" ] && [ "${rd%/*}" = "${rd#*/}" ] && [ -n "${rd%/*}" ]; } || CAL="NotStable (restarts $r0 -> $r1, ready $rd)"
fi

sec "Checks"
expect "node status"   Ready     "$NODE"
expect "Calico status" Available "$CAL"
DP=$(kubectl get installation default -o jsonpath='{.spec.calicoNetwork.linuxDataplane}' 2>/dev/null)
if [ "$MODE" = ebpf ]; then
  expect "Calico dataplane" BPF "$DP"
  # Felix applies the setting a little after the operator: wait before judging.
  bpf_on() { [ "$(kubectl get felixconfiguration default -o jsonpath='{.spec.bpfEnabled}' 2>/dev/null)" = true ]; }
  waitf 60 5 bpf_on
  expect "Felix bpfEnabled"            true "$(kubectl get felixconfiguration default -o jsonpath='{.spec.bpfEnabled}' 2>/dev/null)"
  expect "kube-proxy processes"        0 "$(pgrep -c kube-proxy || true)"
  expect "kube-proxy rules (KUBE-SVC)" 0 "$(count_rules 'KUBE-SVC')"
  [ "$(mount | grep -c bpf)" -gt 0 ] && R=yes || R=no
  expect "BPF filesystem mounted" yes "$R"
else
  expect "Calico dataplane" Iptables "${DP:-Iptables}"
  [ "$(count_rules 'cali-')" -gt 0 ] 2>/dev/null && R=yes || R=no
  expect "Calico iptables rules (cali-) present" yes "$R"
  [ "$(count_rules 'KUBE-SVC')" -gt 0 ] 2>/dev/null && R=yes || R=no
  expect "kube-proxy rules (KUBE-SVC) present"   yes "$R"
fi
expect "K3s policy controller rules (KUBE-NWPLCY)" 0 "$(count_rules KUBE-NWPLCY)"
echo "K3s: $(k3s --version | head -1)   kernel: $(uname -r)"
table
