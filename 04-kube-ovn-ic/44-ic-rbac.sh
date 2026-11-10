#!/bin/bash
# 44-ic-rbac.sh — test: can a tenant administrator change the routes, VPCs or subnets that decide the isolation?
#
# What it does : gives the ServiceAccount "default" of ns-vt the ClusterRole admin inside ns-vt (what a tenant
#                administrator has) and asks the API server (kubectl auth can-i --as, and a server-side dry-run patch)
#                whether that identity can read, patch or create the Kube-OVN resources that define routes, VPCs,
#                subnets and security groups, and whether it can still create pods in its own namespace but not in the
#                namespace of the other tenant.
# Environment  : the tenants of 21-ic-tenants.sh
# Changes      : creates a RoleBinding in ns-vt on site A; removed at the end, also if interrupted. No resource is changed
#                (the patch is a dry run).
# Requires     : bash >= 3.2, ssh
# Usage        : ./44-ic-rbac.sh
# Variables    : none
# Duration     : about 1 minute
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (RBAC and route injection)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
M="$HERE/manifests"
ic_need_tenants
trap 'clear_line; ic_delete a "$M/60-rbac-tenant-binding.yaml"' EXIT
ic_apply a "$M/60-rbac-tenant-binding.yaml" || die "cannot create the RoleBinding"
SA="system:serviceaccount:ns-vt:default"
can() { rk a "kubectl auth can-i $1 $2 --as=$SA ${3:-} 2>/dev/null"; }

sec "Control: the resource names exist (the cluster administrator can list them)"
# can-i answers "no" for a resource type that does not exist, and "yes" to the administrator whatever the name: neither
# tells whether the name is right. "kubectl get" does: it fails when the server has no such resource type.
for r in vpcs subnets security-groups vpc-nat-gateways ips ovn-eips; do
  expect "control: the resource type $r.kubeovn.io exists" yes "$(rk a "kubectl get $r.kubeovn.io -o name >/dev/null 2>&1 && echo yes || echo no" | tr -d '\r')"
done
sec "Kube-OVN resources (cluster scope)"
for r in vpcs subnets security-groups vpc-nat-gateways ips ovn-eips; do
  for v in get patch create; do
    expect "$v $r.kubeovn.io" no "$(can "$v" "$r.kubeovn.io")"
  done
done
sec "Dry-run patches"
OUT="$(rk a "kubectl patch vpc vpc-t --as=$SA --type merge -p '{\"spec\":{\"staticRoutes\":[]}}' --dry-run=server 2>&1")"
expect "patch of vpc-t as the tenant (dry run)" Forbidden "$(grep -q Forbidden <<<"$OUT" && echo Forbidden || echo "$OUT" | head -1)"
OUT="$(rk a "kubectl patch vpc ovn-cluster --as=$SA --type merge -p '{\"spec\":{\"staticRoutes\":[]}}' --dry-run=server 2>&1")"
expect "patch of ovn-cluster as the tenant (dry run)" Forbidden "$(grep -q Forbidden <<<"$OUT" && echo Forbidden || echo "$OUT" | head -1)"
sec "What the tenant can do"
expect "create pods in its own namespace (ns-vt)" yes "$(can create pods "-n ns-vt")"
expect "create network policies in its own namespace" yes "$(can create networkpolicies.networking.k8s.io "-n ns-vt")"
expect "create pods in the other tenant namespace (ns-vu)" no "$(can create pods "-n ns-vu")"
table
