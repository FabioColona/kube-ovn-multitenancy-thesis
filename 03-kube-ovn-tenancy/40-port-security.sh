#!/bin/bash
# 40-port-security.sh — test: does the port_security annotation stop a pod from using an address it was not assigned?
#
# What it does : creates a server and two pods that hold the NET_ADMIN capability: ps-on, with the annotation
#                ovn.kubernetes.io/port_security: "true", and ps-off, without it. Each of the two pods adds an unassigned
#                address (PS_SPOOF_IP) to its interface and pings the server using that address as source.
#                Expected: without the annotation the server answers (the protection is opt-in); with it the packets are
#                dropped. With the address assigned by Kube-OVN both pods are answered. It also reads the port-security
#                field of the two logical ports in the OVN northbound database.
# Environment  : cluster installed by 02-kube-ovn-setup (the tenants of 10-apply-tenants.sh are NOT needed)
# Changes      : creates the namespace ns-ps and three pods; all removed at the end, also if interrupted
# Requires     : bash >= 4, kubectl (with the kubectl-ko plugin installed by Kube-OVN)
# Usage        : ./40-port-security.sh        (REPETITIONS=1 ./40-port-security.sh for a quick run)
# Variables    : NS_PS, PS_SPOOF_IP, REPETITIONS, SETTLE_SECONDS (from config.env)
# Duration     : about 2 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (spoofing and port security)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

need_cluster
kubectl ko nbctl show >/dev/null 2>&1 || die "the kubectl-ko plugin is not available (installed by Kube-OVN in /usr/local/bin)"
MAN="$HERE/manifests/70-port-security-pods.yaml"

cleanup() { kubectl delete -f "$MAN" --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT
kubectl delete -f "$MAN" --ignore-not-found --wait=true >/dev/null 2>&1

sec "Creating the pods"
kubectl apply -f "$MAN" >/dev/null || die "cannot apply manifests/70-port-security-pods.yaml"
for p in ps-dst ps-off ps-on; do
  wait_pod_ready "$NS_PS" "$p" || warn "pod $NS_PS/$p not Ready after 3 minutes"
done
sleep "$SETTLE_SECONDS"
DST="$(pod_ip "$NS_PS" ps-dst)"; OFF="$(pod_ip "$NS_PS" ps-off)"; ON="$(pod_ip "$NS_PS" ps-on)"
[ -n "$DST" ] && [ -n "$OFF" ] && [ -n "$ON" ] || die "the pods have no address"
echo "ps-dst=$DST  ps-off=$OFF  ps-on=$ON  fake source address=$PS_SPOOF_IP  ($REPETITIONS repetitions per row)"

sec "Adding the unassigned address $PS_SPOOF_IP/32 to ps-off and ps-on"
for p in ps-off ps-on; do
  kubectl -n "$NS_PS" exec "$p" -- ip addr add "$PS_SPOOF_IP/32" dev eth0 || die "cannot add the address to $p (is NET_ADMIN granted?)"
done

# has_port_security <pod>: yes if the logical port of the pod has a port-security entry in OVN.
has_port_security() {
  local out; out="$(kubectl ko nbctl lsp-get-port-security "$1.$NS_PS" 2>/dev/null)" || { echo error; return; }
  [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] && echo yes || echo no
}

sec "Probing"
expect "OVN port security on the port of ps-on"  yes "$(has_port_security ps-on)"
expect "OVN port security on the port of ps-off" no  "$(has_port_security ps-off)"
check_flow "ps-off, assigned address ($OFF) -> server"      ok      "$NS_PS" ps-off "$DST" "ping@$OFF"
check_flow "ps-on,  assigned address ($ON) -> server"       ok      "$NS_PS" ps-on  "$DST" "ping@$ON"
check_flow "ps-off, fake address $PS_SPOOF_IP -> server"    ok      "$NS_PS" ps-off "$DST" "ping@$PS_SPOOF_IP"
check_flow "ps-on,  fake address $PS_SPOOF_IP -> server"    blocked "$NS_PS" ps-on  "$DST" "ping@$PS_SPOOF_IP"
table
