#!/bin/bash
# 30-netpol-cross-site.sh — test: do Kubernetes NetworkPolicies work between two sites interconnected with OVN-IC?
#
# What it does : target pod srv on site A, remote client cli on site B (same label and same namespace label that the
#                rules ask for), two local control clients on site A. Policies on site A, one step at a time:
#                deny-all (everyone blocked), podSelector (only the local pod with the label gets in: the remote one
#                does not), namespaceSelector (same), ipBlock on the pod CIDR of site B (the remote one gets in).
#                Last step: an egress deny-all on site B blocks the remote client at the source.
#                The local controls show that each rule is correct, so a block of the remote pod is due to the site.
# Environment  : two sites with OVN-IC working (11-install-ic.sh, 20-ic-state.sh PASS)
# Changes      : creates the namespaces ic-np (both sites) and ic-np-local (site A) with pods and policies;
#                everything is removed at the end, also if interrupted
# Requires     : bash >= 3.2, ssh
# Usage        : ./30-netpol-cross-site.sh        (REPETITIONS=1 ./30-netpol-cross-site.sh for a quick run)
# Variables    : NS_NP, NS_NP_LOCAL, SITE_B_POD_CIDR, REPETITIONS (from config.env)
# Duration     : about 10 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (NetworkPolicy between sites)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
M="$HERE/manifests"
for s in a b; do rk "$s" 'kubectl get crd subnets.kubeovn.io >/dev/null 2>&1' || die "site $s has no Kube-OVN: run ./10-install-sites.sh and ./11-install-ic.sh"; done
grep -q "cidr: $SITE_B_POD_CIDR" "$M/25-np-allow-ipblock.yaml" || die "manifests/25-np-allow-ipblock.yaml must name the pod CIDR of site B ($SITE_B_POD_CIDR)"

cleanup() {
  clear_line
  rk a "kubectl delete namespace $NS_NP $NS_NP_LOCAL --wait=false >/dev/null 2>&1"
  rk b "kubectl delete namespace $NS_NP --wait=false >/dev/null 2>&1"
}
trap cleanup EXIT
rk a "kubectl delete namespace $NS_NP $NS_NP_LOCAL --wait=true >/dev/null 2>&1"
rk b "kubectl delete namespace $NS_NP --wait=true >/dev/null 2>&1"

sec "Creating the pods"
ic_apply a "$M/20-np-site-a-pods.yaml" || die "cannot create the pods on site A"
ic_apply b "$M/21-np-site-b-pods.yaml" || die "cannot create the pod on site B"
run_spin "site A: waiting for the pods" "image download, up to 3 minutes" rk a "kubectl -n $NS_NP wait --for=condition=Ready pod/srv pod/ctl-label --timeout=180s && kubectl -n $NS_NP_LOCAL wait --for=condition=Ready pod/ctl-ns --timeout=180s" || { tail -5 "$RUN_LOG"; die "pods of site A not ready"; }
run_spin "site B: waiting for the pod" "up to 3 minutes" rk b "kubectl -n $NS_NP wait --for=condition=Ready pod/cli --timeout=180s" || { tail -5 "$RUN_LOG"; die "pod of site B not ready"; }
SRV="$(ic_pod_ip a "$NS_NP" srv)"; CLI="$(ic_pod_ip b "$NS_NP" cli)"
[ -n "$SRV" ] && [ -n "$CLI" ] || die "the pods have no address"
echo "srv (site A) = $SRV   cli (site B) = $CLI   ($REPETITIONS repetitions per row)"
ic_wait_probe open 60 b "$NS_NP" cli "$SRV" || die "no traffic from site B to site A even without policies: run ./20-ic-state.sh"

# step <title> : the three clients toward srv. Expected results are passed as open/blocked: remote, ctl-label, ctl-ns.
step() {
  local t=$1 r=$2 l=$3 n=$4
  ic_check "$t: cli (site B) -> srv"        "$r" b "$NS_NP" cli "$SRV"
  ic_check "$t: ctl-label (site A) -> srv"  "$l" a "$NS_NP" ctl-label "$SRV"
  ic_check "$t: ctl-ns (site A) -> srv"     "$n" a "$NS_NP_LOCAL" ctl-ns "$SRV"
}

sec "0. No policy"
step "no policy" open open open

sec "1. deny-all-ingress on site A"
ic_apply a "$M/22-np-deny-all.yaml"
ic_wait_probe blocked 60 a "$NS_NP" ctl-label "$SRV" || warn "deny-all not effective after 1 minute"
step "deny-all" blocked blocked blocked

sec "2. + allow by pod label (app=client)"
ic_apply a "$M/23-np-allow-podselector.yaml"
ic_wait_probe open 60 a "$NS_NP" ctl-label "$SRV" || warn "podSelector rule not effective after 1 minute"
step "podSelector" blocked open blocked

sec "3. allow by namespace label (np=allowed) instead"
ic_delete a "$M/23-np-allow-podselector.yaml"; ic_apply a "$M/24-np-allow-namespace.yaml"
ic_wait_probe open 60 a "$NS_NP_LOCAL" ctl-ns "$SRV" || warn "namespaceSelector rule not effective after 1 minute"
step "namespaceSelector" blocked blocked open

sec "4. allow by address (ipBlock $SITE_B_POD_CIDR) instead"
ic_delete a "$M/24-np-allow-namespace.yaml"; ic_apply a "$M/25-np-allow-ipblock.yaml"
ic_wait_probe open 60 b "$NS_NP" cli "$SRV" || warn "ipBlock rule not effective after 1 minute"
step "ipBlock" open blocked blocked

sec "5. Policies of site A removed, egress deny-all on site B"
ic_delete a "$M/25-np-allow-ipblock.yaml"; ic_delete a "$M/22-np-deny-all.yaml"
ic_wait_probe open 60 b "$NS_NP" cli "$SRV" || warn "traffic not restored after 1 minute"
ic_apply b "$M/26-np-egress-deny-site-b.yaml"
ic_wait_probe blocked 60 b "$NS_NP" cli "$SRV" || warn "egress deny-all not effective after 1 minute"
ic_check "egress deny-all on site B: cli -> srv" blocked b "$NS_NP" cli "$SRV"
ic_check "egress deny-all on site B: ctl-label (site A) -> srv" open a "$NS_NP" ctl-label "$SRV"
table
