#!/bin/bash
# 29-ic-tenants-remove.sh — removes what 21-ic-tenants.sh created (the sites and OVN-IC stay).
#
# What it does : deletes the namespaces, the subnets, the VPCs of the tenants and the peerings, routes and policies
#                added to ovn-cluster on both sites.
# Environment  : the lab of 21-ic-tenants.sh
# Changes      : DELETES the tenants of the tests on both sites
# Requires     : bash >= 3.2, ssh
# Usage        : ./29-ic-tenants-remove.sh
# Variables    : SITE_* (from config.env)
# Duration     : about 1 minute
# Exit code    : 0 = removed; 2 = prerequisite missing
# In the thesis: not cited (support script)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
sec "Site A"
rk a 'kubectl patch vpc ovn-cluster --type merge -p "{\"spec\":{\"vpcPeerings\":null,\"staticRoutes\":null,\"policyRoutes\":null}}" >/dev/null 2>&1
kubectl delete namespace ns-t-a ns-u-a ns-d ns-vt ns-vu ns-hj --ignore-not-found --wait=true >/dev/null 2>&1
kubectl delete subnet sub-t-a sub-u-a sub-vt sub-vu sub-hijack --ignore-not-found >/dev/null 2>&1
kubectl delete vpc vpc-t vpc-u --ignore-not-found >/dev/null 2>&1'
info "removed"
sec "Site B"
rk b 'kubectl patch vpc ovn-cluster --type merge -p "{\"spec\":{\"vpcPeerings\":null,\"staticRoutes\":null,\"policyRoutes\":null}}" >/dev/null 2>&1
kubectl delete namespace ns-t-b ns-u-b ns-d ns-vb ns-hj --ignore-not-found --wait=true >/dev/null 2>&1
kubectl delete subnet sub-t-b sub-u-b sub-custom-b sub-ov-b sub-hijack --ignore-not-found >/dev/null 2>&1
kubectl delete vpc vpc-custom-b --ignore-not-found >/dev/null 2>&1'
info "removed"
