#!/bin/bash
# 30-blind-spot.sh — test "blind-spot": Calico filters by address and port, not by HTTP method or path.
#
# What it does : creates a server, an allowed client (app=client) and an attacker (app=attacker).
#                1) no policy: everything is open.
#                2) a NetworkPolicy allows TCP/80 only from app=client: the attacker must be blocked.
#                3) the allowed client sends GET /public, POST /admin, GET /secret, DELETE /public and four
#                   non-HTTP payloads: Calico cannot tell them apart, so all of them pass (this is the result
#                   expected from Calico: PASS means "the blind spot is confirmed").
# Environment  : single-node K3s with Calico, iptables or eBPF (phase 11)
# Changes      : CHANGES THE CLUSTER (creates and deletes the namespace blind-spot)
# Requires     : bash >= 4, kubectl, Calico cluster running, Internet to pull images
# Usage        : ./30-blind-spot.sh [--yes]      (CNI_OVERRIDE=<name> to skip the CNI detection)
# Variables    : REPETITIONS (from config.env)
# Duration     : about 3 minutes
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Section 3.5 (test blind-spot)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
. "$HERE/lib-cni.sh"
parse_common_options "$@"
load_config "$HERE"
set -uo pipefail

have kubectl || die "kubectl not found: install the cluster first (phases 11-13)"
kubectl get nodes >/dev/null 2>&1 || die "the cluster does not answer: is K3s running? (export KUBECONFIG=/etc/rancher/k3s/k3s.yaml)"
CNI=$(detect_cni); info "CNI detected: $CNI"
case "$CNI" in
  calico|calico-ebpf) ;;
  cilium-*) die "This test is for Calico: for Cilium use 31-path-guard.sh" ;;
  flannel)  die "Flannel enforces no policy at all: use 20-paper-wall.sh" ;;
  *) die "CNI not recognised: install Calico with phase 11, or set CNI_OVERRIDE" ;;
esac
confirm "This creates and deletes the namespace blind-spot on this cluster. Continue?"
trap l7_down EXIT

sec "Preparing the scenario"
l7_up blind-spot
N=$REPETITIONS

sec "Round 1 - no policy"
check_repeated "no policy: client GET /public"     200 "$N" l7_http client-http GET    /public
check_repeated "no policy: client POST /admin"     200 "$N" l7_http client-http POST   /admin
check_repeated "no policy: attacker GET /secret"   200 "$N" l7_http attacker    GET    /secret
check_repeated "no policy: attacker DELETE /public" 200 "$N" l7_http attacker   DELETE /public

sec "Round 2 - NetworkPolicy: TCP/80 allowed only from app=client"
kubectl apply -n blind-spot -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-client-port80}
spec:
  podSelector: {matchLabels: {app: server}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {matchLabels: {app: client}}
    ports: [{protocol: TCP, port: 80}]
YAML
info "waiting for the policy to be enforced..."
attacker_blocked() { [ "$(l7_http attacker GET /secret)" = blocked ]; }
waitf 60 2 attacker_blocked || warn "the attacker is still not blocked after 2 minutes"
check_repeated "policy: attacker GET /secret"       blocked "$N" l7_http attacker GET    /secret
check_repeated "policy: attacker DELETE /public"    blocked "$N" l7_http attacker DELETE /public
check_repeated "policy: client GET /public"         200     "$N" l7_http client-http GET    /public

sec "Round 3 - the allowed client: Calico cannot see inside the request"
check_repeated "client POST /admin (not filtered)"      200 "$N" l7_http client-http POST   /admin
check_repeated "client GET /secret (not filtered)"      200 "$N" l7_http client-http GET    /secret
check_repeated "client DELETE /public (not filtered)"   200 "$N" l7_http client-http DELETE /public
for p in ascii redis tls binary; do
  check_repeated "client non-HTTP payload: $p"    connected "$N" l7_raw "$p"
done

sec "Results (CNI: $CNI, $N repetitions)"
table
