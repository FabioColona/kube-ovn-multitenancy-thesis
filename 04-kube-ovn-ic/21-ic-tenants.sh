#!/bin/bash
# 21-ic-tenants.sh — creates the tenants used by the tests 40-44 on the two sites.
#
# What it does : site A: tenants T and U, each with a private subnet and a custom VPC (vpc-t, vpc-u) peered with the
#                default VPC, plus a public pod. Site B: tenants T and U with a private subnet, a custom VPC
#                (vpc-custom-b) peered with the default VPC, plus a public pod. Then waits until OVN-IC has carried the
#                routes of the custom subnets to the other site. Every pod serves HTTP on 8080.
# Environment  : two sites with OVN-IC working (11-install-ic.sh)
# Changes      : creates namespaces, VPCs, subnets and pods on both sites and patches ovn-cluster (peerings, routes,
#                policies). Remove everything with 29-ic-tenants-remove.sh.
# Requires     : bash >= 3.2, ssh
# Usage        : ./21-ic-tenants.sh
# Variables    : SITE_*, the pod names and addresses of config.env
# Duration     : about 3 minutes
# Exit code    : 0 = ready; 1 = a check failed; 2 = prerequisite missing
# In the thesis: Chapter 5 (laboratory of the tests between sites)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
M="$HERE/manifests"
for s in a b; do rk "$s" 'kubectl get crd subnets.kubeovn.io >/dev/null 2>&1' || die "site $s has no Kube-OVN: run ./10-install-sites.sh and ./11-install-ic.sh"; done
rk a "kubectl -n $NS_VT get pod c-t >/dev/null 2>&1" && die "the tenants already exist: run ./29-ic-tenants-remove.sh first"

sec "Site A: VPCs, subnets, pods"
ic_apply a "$M/40-tenants-site-a.yaml" || die "cannot apply manifests/40-tenants-site-a.yaml"
ic_patch a vpc vpc-t "$M/42-vpc-t-peering.yaml" || die "cannot patch vpc-t"
ic_patch a vpc vpc-u "$M/43-vpc-u-peering.yaml" || die "cannot patch vpc-u"
ic_patch a vpc ovn-cluster "$M/44-ovn-cluster-a-peerings.yaml" || die "cannot patch ovn-cluster of site A"
sec "Site B: VPC, subnets, pods"
ic_apply b "$M/41-tenants-site-b.yaml" || die "cannot apply manifests/41-tenants-site-b.yaml"
ic_patch b vpc vpc-custom-b "$M/45-vpc-custom-b-peering.yaml" || die "cannot patch vpc-custom-b"
ic_patch b vpc ovn-cluster "$M/46-ovn-cluster-b-peering.yaml" || die "cannot patch ovn-cluster of site B"

sec "Waiting for the pods"
run_spin "site A: pods" "image download, up to 4 minutes" rk a "for p in ns-t-a/t-a ns-u-a/u-a ns-d/d-a ns-vt/c-t ns-vu/c-u; do kubectl -n \${p%/*} wait --for=condition=Ready pod/\${p#*/} --timeout=240s || exit 1; done" || { tail -5 "$RUN_LOG"; die "pods of site A not ready"; }
run_spin "site B: pods" "up to 4 minutes" rk b "for p in ns-t-b/t-b ns-u-b/u-b ns-d/d-b ns-vb/pb; do kubectl -n \${p%/*} wait --for=condition=Ready pod/\${p#*/} --timeout=240s || exit 1; done" || { tail -5 "$RUN_LOG"; die "pods of site B not ready"; }

sec "Routes carried by OVN-IC"
site_has() { [ "$(ic_routes "$1" "$2")" -ge 1 ]; }
WAIT_MSG="site B learns 10.90.0.0/24" waitf 30 3 site_has b 10.90.0.0/24
WAIT_MSG="site A learns 10.60.0.0/24" waitf 30 3 site_has a 10.60.0.0/24
expect "site A learns the custom subnet of site B (10.60.0.0/24)" yes "$(site_has a 10.60.0.0/24 && echo yes || echo no)"
expect "site B learns the custom subnets of site A (10.90.0.0/24)" yes "$(site_has b 10.90.0.0/24 && echo yes || echo no)"
expect "site B learns the custom subnets of site A (10.91.0.0/24)" yes "$(site_has b 10.91.0.0/24 && echo yes || echo no)"
expect "site B learns the private subnet of tenant T (10.80.0.0/24)" yes "$(site_has b 10.80.0.0/24 && echo yes || echo no)"
expect "site A learns the private subnet of tenant T (10.81.0.0/24)" yes "$(site_has a 10.81.0.0/24 && echo yes || echo no)"
ic_wait_probe open 90 a "$NS_D" d-a "$IP_D_B" || warn "d-a does not reach d-b yet"
table; RC=$?
info "next: ./40-private-subnets.sh"
exit $RC
