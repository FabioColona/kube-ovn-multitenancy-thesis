#!/bin/bash
# 31-sg-cross-site.sh — test: do Security Groups work between two sites interconnected with OVN-IC?
#
# What it does : target srv on site A in the group sg-ic; on site B a client in a group with the SAME NAME (cli-sg) and a
#                client with no group (cli-nosg); on site A a local client of the same group (local-sg, control).
#                Step 0: the group lets in only its members: the local one gets in, the remote ones do not (membership
#                does not cross the sites). Step 1: a rule by address on the CIDR of site B: both remote clients get in.
#                Step 2: the rule only for TCP 8080: TCP passes, ping does not (result "tcp-only"). Step 3: rule removed: blocked again.
#                Step 4: rule by address back, but the group of site B lets out only toward its own CIDR: cli-sg is
#                blocked at the source, cli-nosg still gets in.
# Environment  : two sites with OVN-IC working (11-install-ic.sh, 20-ic-state.sh PASS)
# Changes      : creates the namespace ic-sg and the group sg-ic on both sites, with pods; everything is removed at
#                the end, also if interrupted
# Requires     : bash >= 3.2, ssh
# Usage        : ./31-sg-cross-site.sh        (REPETITIONS=1 ./31-sg-cross-site.sh for a quick run)
# Variables    : NS_SG, SG_NAME, SITE_B_POD_CIDR, REPETITIONS (from config.env)
# Duration     : about 10 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (Security Group between sites)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
M="$HERE/manifests"
for s in a b; do rk "$s" 'kubectl get crd security-groups.kubeovn.io >/dev/null 2>&1' || die "site $s has no Kube-OVN: run ./10-install-sites.sh and ./11-install-ic.sh"; done
grep -q "remoteAddress: $SITE_B_POD_CIDR" "$M/32-sg-a-address-all.yaml" || die "manifests/32-sg-a-address-all.yaml must name the pod CIDR of site B ($SITE_B_POD_CIDR)"

cleanup() {
  clear_line
  for s in a b; do rk "$s" "kubectl delete namespace $NS_SG --wait=false >/dev/null 2>&1; kubectl delete sg $SG_NAME --ignore-not-found >/dev/null 2>&1"; done
}
trap cleanup EXIT
for s in a b; do rk "$s" "kubectl delete namespace $NS_SG --wait=true >/dev/null 2>&1; kubectl delete sg $SG_NAME --ignore-not-found >/dev/null 2>&1"; done

sec "Creating the groups and the pods"
ic_apply a "$M/31-sg-a-members.yaml" && ic_apply b "$M/34-sg-b-members.yaml" || die "cannot create the groups"
ic_apply a "$M/30-sg-site-a-pods.yaml" || die "cannot create the pods on site A"
ic_apply b "$M/35-sg-site-b-pods.yaml" || die "cannot create the pods on site B"
run_spin "site A: waiting for the pods" "image download, up to 3 minutes" rk a "kubectl -n $NS_SG wait --for=condition=Ready pod/srv pod/local-sg --timeout=180s" || { tail -5 "$RUN_LOG"; die "pods of site A not ready"; }
run_spin "site B: waiting for the pods" "up to 3 minutes" rk b "kubectl -n $NS_SG wait --for=condition=Ready pod/cli-sg pod/cli-nosg --timeout=180s" || { tail -5 "$RUN_LOG"; die "pods of site B not ready"; }
SRV="$(ic_pod_ip a "$NS_SG" srv)"
[ -n "$SRV" ] || die "the target has no address"
echo "srv (site A) = $SRV   ($REPETITIONS repetitions per row)"
ic_wait_probe open 60 a "$NS_SG" local-sg "$SRV" || die "the local client does not reach the target: the group is wrong"

# step <title> <cli-sg> <cli-nosg> <local-sg>: the three clients toward srv (open|blocked|ping-only|tcp-only).
step() {
  ic_check "$1: cli-sg (site B, group of B) -> srv"  "$2" b "$NS_SG" cli-sg "$SRV"
  ic_check "$1: cli-nosg (site B, no group) -> srv"  "$3" b "$NS_SG" cli-nosg "$SRV"
  ic_check "$1: local-sg (site A, same group) -> srv" "$4" a "$NS_SG" local-sg "$SRV"
}

sec "0. Group of site A: members only"
step "members only" blocked blocked open

sec "1. + rule by address (all traffic from $SITE_B_POD_CIDR)"
ic_apply a "$M/32-sg-a-address-all.yaml"
ic_wait_probe open 60 b "$NS_SG" cli-nosg "$SRV" || warn "rule not effective after 1 minute"
step "address, all" open open open

sec "2. rule by address only for TCP 8080"
ic_apply a "$M/33-sg-a-address-tcp.yaml"
ic_wait_probe tcp-only 60 b "$NS_SG" cli-nosg "$SRV" || warn "rule not effective after 1 minute"
step "address, TCP 8080" tcp-only tcp-only open

sec "3. rule by address removed"
ic_apply a "$M/31-sg-a-members.yaml"
ic_wait_probe blocked 60 b "$NS_SG" cli-nosg "$SRV" || warn "rule not removed after 1 minute"
step "rule removed" blocked blocked open

sec "4. rule by address back, group of site B restricted in egress"
ic_apply a "$M/32-sg-a-address-all.yaml"
ic_wait_probe open 60 b "$NS_SG" cli-nosg "$SRV" || warn "rule not effective after 1 minute"
ic_apply b "$M/36-sg-b-egress-restricted.yaml"
ic_wait_probe blocked 60 b "$NS_SG" cli-sg "$SRV" || warn "egress restriction not effective after 1 minute"
step "egress restricted on B" blocked open open
table
