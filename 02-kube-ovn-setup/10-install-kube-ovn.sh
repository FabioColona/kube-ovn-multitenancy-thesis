#!/bin/bash
# 10-install-kube-ovn.sh — installs a single-node K3s cluster with Kube-OVN as the CNI.
#
# What it does : installs K3s without Flannel and without its policy controller, then Kube-OVN (official install.sh,
#                with the pod/service/join CIDRs rewritten, because install.sh ignores environment variables),
#                fixes CoreDNS if needed and points OVN_DB_IPS to the ovn-sb service.
#                Then checks node, Kube-OVN pods, default subnet, join subnet, default VPC and, with two test pods,
#                pod-to-pod traffic, DNS and a service ClusterIP.
# Environment  : any Linux machine (x86_64 or aarch64) with systemd and Internet access; run it on EACH site
# Changes      : CHANGES THE MACHINE (installs K3s, loads kernel modules, writes sysctl and modules-load files, turns swap off
#                until reboot; refuses to run if K3s is already there). /etc/fstab is NOT modified.
# Requires     : bash >= 4, curl, python3, root or sudo (the password is asked once), phase 00 without FAIL
# Usage        : ./10-install-kube-ovn.sh [--yes]
# Variables    : K3S_VERSION, KUBEOVN_VERSION, NODE_HOSTNAME, NODE_IFACE, NODE_IP, POD_CIDR, SVC_CIDR, JOIN_CIDR,
#                ALLOW_STOP_HOST_OVS, CHECK_IMAGE (from config.env)
# Duration     : about 5 minutes
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing or installation failed
# In the thesis: Chapter 5 (test bed: Kube-OVN installation)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
parse_common_options "$@"
load_config "$HERE"
set -uo pipefail

require_vars K3S_VERSION KUBEOVN_VERSION POD_CIDR SVC_CIDR JOIN_CIDR CHECK_IMAGE
have python3 || die "python3 is required"
need_sudo
k3s_installed && die "K3s is already installed: run ./90-reset.sh first"

# Interface and address of the node (empty in config = detect).
[ -n "${NODE_IFACE:-}" ] || NODE_IFACE="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
[ -n "${NODE_IP:-}" ]    || NODE_IP="$(ip -4 -o addr show dev "$NODE_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
[ -n "$NODE_IFACE" ] && [ -n "$NODE_IP" ] || die "cannot determine NODE_IFACE / NODE_IP: set them in config.local.env"

cat <<EOT
  K3s $K3S_VERSION   Kube-OVN $KUBEOVN_VERSION   host $(hostname)
  node: $NODE_IP on $NODE_IFACE
  pod $POD_CIDR   service $SVC_CIDR   join $JOIN_CIDR
EOT
confirm "This installs K3s and Kube-OVN on this machine. Continue?"

TMP="$(mktemp -d)"
# shellcheck disable=SC2034  # RUN_LOG_DIR is read by run_spin in lib/common.sh
RUN_LOG_DIR="$TMP"
trap 'rm -rf "$TMP"; kubectl delete namespace ko-check --wait=false >/dev/null 2>&1' EXIT

sec "1. Kernel modules and sysctl"
for m in openvswitch geneve ip_tables iptable_nat br_netfilter overlay; do as_root modprobe "$m" 2>/dev/null; done
printf "openvswitch\ngeneve\nip_tables\niptable_nat\nbr_netfilter\noverlay\n" | as_root tee /etc/modules-load.d/kube-ovn.conf >/dev/null
grep -q '^openvswitch ' /proc/modules || die "kernel module openvswitch missing: Kube-OVN cannot work on this kernel"
printf "net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n" | as_root tee /etc/sysctl.d/99-kube-ovn.conf >/dev/null
as_root sysctl --system >/dev/null
as_root swapoff -a   # runtime only
info "modules loaded, sysctl applied"

sec "2. Open vSwitch on the host"
if systemctl is-active --quiet openvswitch-switch 2>/dev/null || systemctl is-active --quiet ovs-vswitchd 2>/dev/null || pgrep -x ovs-vswitchd >/dev/null 2>&1; then
  [ "$ALLOW_STOP_HOST_OVS" = yes ] || die "Open vSwitch is running on the host: set ALLOW_STOP_HOST_OVS=yes in config.local.env (or stop it yourself)"
  as_root systemctl disable --now openvswitch-switch ovs-vswitchd ovsdb-server >/dev/null 2>&1
  info "host Open vSwitch stopped"
else info "none running"; fi
# The OVS containers of Kube-OVN run as an unprivileged user and need this directory.
as_root mkdir -p /run/openvswitch /var/run/openvswitch; as_root chmod 755 /run/openvswitch

sec "3. K3s $K3S_VERSION (no Flannel, no policy controller, no Traefik)"
if [ -n "${NODE_HOSTNAME:-}" ]; then as_root hostnamectl set-hostname "$NODE_HOSTNAME"; fi
install_k3s "--flannel-backend=none --disable-network-policy --disable=traefik --node-ip=$NODE_IP --advertise-address=$NODE_IP --tls-san=$NODE_IP --cluster-cidr=$POD_CIDR --service-cidr=$SVC_CIDR"
info "API server ready (the node stays NotReady until a CNI is installed)"

sec "4. Kube-OVN $KUBEOVN_VERSION"
# install.sh looks for a node with the control-plane (or master) label and stops at once if it finds none: right after the
# K3s install the node may not be registered yet, so wait for it.
WAIT_MSG="waiting for the node to register" waitf 60 2 bash -c "kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | grep -q . || kubectl get nodes -l node-role.kubernetes.io/master --no-headers 2>/dev/null | grep -q ." || warn "no node with the control-plane label after 2 minutes"
curl -fsSL "https://raw.githubusercontent.com/kubeovn/kube-ovn/${KUBEOVN_VERSION}/dist/images/install.sh" -o "$TMP/install.sh" || die "download of install.sh failed"
# install.sh has the network values written in the file and ignores environment variables: rewrite them.
POD_GW="$(echo "$POD_CIDR" | awk -F'[./]' '{print $1"."$2"."$3"."($4+1)}')"
sed -i -e "s|^POD_CIDR=\"10.16.0.0/16\"|POD_CIDR=\"$POD_CIDR\"|" -e "s|^POD_GATEWAY=\"10.16.0.1\"|POD_GATEWAY=\"$POD_GW\"|" \
       -e "s|^SVC_CIDR=\"10.96.0.0/12\"|SVC_CIDR=\"$SVC_CIDR\"|" -e "s|^JOIN_CIDR=\"100.64.0.0/16\"|JOIN_CIDR=\"$JOIN_CIDR\"|" "$TMP/install.sh"
WRITTEN="$(grep -E '^(POD_CIDR|POD_GATEWAY|SVC_CIDR|JOIN_CIDR)=' "$TMP/install.sh" | awk '{print $1}' | tr '\n' ' ')"
info "install.sh values: $WRITTEN"
echo "$WRITTEN" | grep -q "POD_CIDR=\"$POD_CIDR\"" || die "could not rewrite POD_CIDR in install.sh (different file layout?)"
# The last step of install.sh runs "kubectl ko diagnose", which fails because the container has no tar: the installation
# itself is complete, so that error is accepted.
if ! SPIN_ACCEPT='Step 6/6' SPIN_NOTE='its final diagnose step failed: missing tar in the container, harmless' \
     run_spin "installing Kube-OVN (install.sh)" "usually 3-5 minutes" env MASTER_NODES="$NODE_IP" IFACE="$NODE_IFACE" bash "$TMP/install.sh"; then
  warn "install.sh returned an error: last lines below; the checks at the end decide the result"
  tail -15 "$RUN_LOG"
fi
run_spin "waiting for kube-ovn-controller" "up to 5 minutes" kubectl -n kube-system wait --for=condition=Ready pods -l app=kube-ovn-controller --timeout=300s || warn "kube-ovn-controller not Ready after 5 minutes"
run_spin "waiting for kube-ovn-cni" "up to 5 minutes" kubectl -n kube-system wait --for=condition=Ready pods -l app=kube-ovn-cni --timeout=300s || warn "kube-ovn-cni not Ready after 5 minutes"

sec "5. CoreDNS and OVN_DB_IPS"
WAIT_MSG="waiting for CoreDNS" waitf 60 2 kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers
CS="$(kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | awk '{print $3}' | head -1)"
if [ "${CS:-NotFound}" != Running ] && [ -f /run/systemd/resolve/resolv.conf ]; then
  # K3s issue #5466: CoreDNS cannot read the resolv.conf of the host; mount the real one.
  warn "CoreDNS is '${CS:-NotFound}': mounting the host resolv.conf"
  kubectl -n kube-system patch deployment coredns --type=json -p='[
    {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"host-resolv-conf","hostPath":{"path":"/run/systemd/resolve/resolv.conf","type":"File"}}},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"host-resolv-conf","mountPath":"/etc/resolv.conf","readOnly":true}}]' >/dev/null 2>&1
  run_spin "restarting CoreDNS" "up to 2 minutes" kubectl -n kube-system rollout status deployment coredns --timeout=120s || warn "CoreDNS rollout not completed"
else info "CoreDNS: ${CS:-NotFound}"; fi
SB_IP="$(kubectl -n kube-system get svc ovn-sb -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
if [ -n "$SB_IP" ]; then
  kubectl -n kube-system set env ds/ovs-ovn OVN_DB_IPS="$SB_IP" >/dev/null && run_spin "restarting ovs-ovn" "up to 3 minutes" kubectl -n kube-system rollout status ds/ovs-ovn --timeout=180s
  info "OVN_DB_IPS -> $SB_IP"
else warn "ClusterIP of ovn-sb not found"; fi

sec "6. Checks"
expect "node status" Ready "$(wait_node_ready 300 && echo Ready || echo NotReady)"
NOTREADY="$(kubectl -n kube-system get pods --no-headers 2>/dev/null | grep -E 'kube-ovn|ovs-ovn|ovn-central|coredns' | grep -vcE ' +([0-9]+)/\1 +Running')"
expect "Kube-OVN and CoreDNS pods not ready" 0 "$NOTREADY"
expect "subnet ovn-default" "$POD_CIDR" "$(kubectl get subnet ovn-default -o jsonpath='{.spec.cidrBlock}' 2>/dev/null)"
expect "subnet join" "$JOIN_CIDR" "$(kubectl get subnet join -o jsonpath='{.spec.cidrBlock}' 2>/dev/null)"
expect "default VPC ovn-cluster" ovn-cluster "$(kubectl get vpc ovn-cluster -o jsonpath='{.metadata.name}' 2>/dev/null)"
expect "kernel module openvswitch" loaded "$(grep -q '^openvswitch ' /proc/modules && echo loaded || echo missing)"
BR="$(kubectl -n kube-system exec ds/ovs-ovn -- ovs-vsctl list-br 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/ $//')"
expect "OVS bridge" br-int "$BR"

# Connectivity with two test pods.
kubectl create namespace ko-check >/dev/null 2>&1
for p in p1 p2; do kubectl -n ko-check run $p --image="$CHECK_IMAGE" --restart=Never -- sleep 3600 >/dev/null 2>&1; done
if run_spin "waiting for the test pods" "image download, up to 3 minutes" kubectl -n ko-check wait --for=condition=Ready pod/p1 pod/p2 --timeout=180s; then
  P1="$(kubectl -n ko-check get pod p1 -o jsonpath='{.status.podIP}')"; P2="$(kubectl -n ko-check get pod p2 -o jsonpath='{.status.podIP}')"
  KSVC="$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}')"
  IN_CIDR=no; python3 -c "import ipaddress,sys; sys.exit(0 if ipaddress.ip_address('$P1') in ipaddress.ip_network('$POD_CIDR') else 1)" && IN_CIDR=yes
  expect "pod address inside pod CIDR" yes "$IN_CIDR"
  expect "pod to pod (ping)" ok "$(kubectl -n ko-check exec p1 -- ping -c 2 -W 2 "$P2" >/dev/null 2>&1 && echo ok || echo fail)"
  expect "DNS (kubernetes.default)" ok "$(kubectl -n ko-check exec p1 -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo ok || echo fail)"
  expect "service ClusterIP ($KSVC:443)" ok "$(kubectl -n ko-check exec p1 -- nc -z -w 3 "$KSVC" 443 >/dev/null 2>&1 && echo ok || echo fail)"
else
  record "test pods ready" yes no FAIL
fi
echo "K3s: $(k3s --version | head -1)   Kube-OVN: $(kubectl -n kube-system get deploy kube-ovn-controller -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
table
