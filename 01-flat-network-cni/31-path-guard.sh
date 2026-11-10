#!/bin/bash
# 31-path-guard.sh — test "path-guard": Cilium filters HTTP requests by method and path.
#
# What it does : creates a server and a client (app=client).
#                1) no policy: every request gets 200.
#                2) a CiliumNetworkPolicy allows only GET /public on TCP/80: GET /public must give 200,
#                   every other request (POST /admin, GET /secret, GET /, DELETE /public) must give 403
#                   (the answer comes from the Envoy proxy of Cilium).
#                3) control: the L7 rule is replaced by an L3/L4 ingressDeny: nothing at all must connect.
#                This test checks the answers seen by the client; whether a refused request still reaches
#                the application is measured by 32-side-door.sh.
# Environment  : single-node K3s with Cilium, strict or legacy (phase 13)
# Changes      : CHANGES THE CLUSTER (creates and deletes the namespace path-guard)
# Requires     : bash >= 4, kubectl, Cilium cluster running, Internet to pull images
# Usage        : ./31-path-guard.sh [--yes]      (CNI_OVERRIDE=<name> to skip the CNI detection)
# Variables    : REPETITIONS (from config.env)
# Duration     : about 3 minutes
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Section 3.5 (test path-guard)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
. "$HERE/lib-cni.sh"
parse_common_options "$@"
load_config "$HERE"
set -uo pipefail

have kubectl || die "kubectl not found: install the cluster first (phase 13)"
kubectl get nodes >/dev/null 2>&1 || die "the cluster does not answer: is K3s running? (export KUBECONFIG=/etc/rancher/k3s/k3s.yaml)"
CNI=$(detect_cni); info "CNI detected: $CNI"
case "$CNI" in
  cilium-strict|cilium-legacy) ;;
  calico|calico-ebpf) die "Calico has no HTTP filtering: use 30-blind-spot.sh" ;;
  flannel) die "Flannel enforces no policy at all: use 20-paper-wall.sh" ;;
  *) die "CNI not recognised: install Cilium with phase 13, or set CNI_OVERRIDE" ;;
esac
confirm "This creates and deletes the namespace path-guard on this cluster. Continue?"
trap l7_down EXIT

sec "Preparing the scenario"
l7_up path-guard
N=$REPETITIONS

sec "Round 1 - no policy"
check_repeated "no policy: GET /public"    200 "$N" l7_http client-http GET    /public
check_repeated "no policy: POST /admin"    200 "$N" l7_http client-http POST   /admin
check_repeated "no policy: GET /secret"    200 "$N" l7_http client-http GET    /secret
check_repeated "no policy: DELETE /"       200 "$N" l7_http client-http DELETE /

sec "Round 2 - CiliumNetworkPolicy: only GET /public"
kubectl apply -n path-guard -f - >/dev/null <<'YAML'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: allow-get-public-only}
spec:
  endpointSelector: {matchLabels: {app: server}}
  ingress:
  - fromEndpoints: [{matchLabels: {app: client}}]
    toPorts:
    - ports: [{port: "80", protocol: TCP}]
      rules: {http: [{method: GET, path: "/public"}]}
YAML
info "waiting for the HTTP rule to be enforced..."
rule_active() { [ "$(l7_http client-http POST /admin)" = 403 ]; }
waitf 60 2 rule_active || warn "the HTTP rule is still not active after 2 minutes"
check_repeated "HTTP rule: GET /public"      200 "$N" l7_http client-http GET    /public
check_repeated "HTTP rule: POST /admin"      403 "$N" l7_http client-http POST   /admin
check_repeated "HTTP rule: GET /secret"      403 "$N" l7_http client-http GET    /secret
check_repeated "HTTP rule: GET /"            403 "$N" l7_http client-http GET    /
check_repeated "HTTP rule: DELETE /public"   403 "$N" l7_http client-http DELETE /public

sec "Round 3 - control: L3/L4 ingressDeny instead of the HTTP rule"
kubectl delete cnp allow-get-public-only -n path-guard >/dev/null
kubectl apply -n path-guard -f - >/dev/null <<'YAML'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: deny-all-tcp-80}
spec:
  endpointSelector: {matchLabels: {app: server}}
  ingressDeny:
  - fromEndpoints: [{matchLabels: {app: client}}]
    toPorts: [{ports: [{port: "80", protocol: TCP}]}]
YAML
deny_active() { [ "$(l7_http client-http GET /public)" = blocked ]; }
waitf 60 2 deny_active || warn "the deny rule is still not active after 2 minutes"
check_repeated "deny: GET /public"           blocked "$N" l7_http client-http GET /public
check_repeated "deny: POST /admin"           blocked "$N" l7_http client-http POST /admin
for p in ascii binary tls; do
  check_repeated "deny: non-HTTP payload $p" blocked "$N" l7_raw "$p"
done

sec "Results (CNI: $CNI, $N repetitions)"
table
