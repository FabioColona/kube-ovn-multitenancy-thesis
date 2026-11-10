#!/bin/bash
# 91-remove-vpcs.sh — removes everything created by 30-apply-vpcs.sh and any peering left on ovn-cluster.
#
# What it does : clears vpcPeerings, staticRoutes and policyRoutes of ovn-cluster and the allowSubnets of sub-t,
#                deletes the custom pods, subnets, VPCs and namespaces, then checks they are gone.
# Environment  : cluster with the VPCs of 30-apply-vpcs.sh
# Changes      : DELETES Kubernetes objects and RESETS the routing fields of ovn-cluster (the cluster itself stays)
# Requires     : bash >= 4, kubectl
# Usage        : ./91-remove-vpcs.sh
# Duration     : about 1 minute
# Exit code    : 0 = all removed; 1 = something left; 2 = prerequisite missing
# In the thesis: not cited (support script)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

need_cluster
sec "Deleting"
kubectl patch vpc ovn-cluster --type merge -p '{"spec":{"vpcPeerings":null,"staticRoutes":null,"policyRoutes":null}}' >/dev/null 2>&1
kubectl patch subnet "$SUBNET_T" --type merge -p '{"spec":{"allowSubnets":null}}' >/dev/null 2>&1
kubectl patch vpc "$VPC_T" --type merge -p '{"spec":{"vpcPeerings":null,"staticRoutes":null}}' >/dev/null 2>&1
kubectl patch vpc "$VPC_U" --type merge -p '{"spec":{"vpcPeerings":null,"staticRoutes":null}}' >/dev/null 2>&1
kubectl delete -f "$HERE/manifests/51-custom-pods.yaml" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl delete -f "$HERE/manifests/50-custom-vpcs.yaml" --ignore-not-found --wait=true >/dev/null 2>&1
sec "Checks"
for v in "$VPC_T" "$VPC_U"; do
  waitf 30 2 bash -c "! kubectl get vpc $v" && record "VPC $v removed" yes yes PASS || record "VPC $v removed" yes no FAIL
done
for n in "$NS_VT" "$NS_VU"; do
  waitf 60 2 bash -c "! kubectl get ns $n" && record "namespace $n removed" yes yes PASS || record "namespace $n removed" yes no FAIL
done
expect "ovn-cluster peerings" "" "$(kubectl get vpc ovn-cluster -o jsonpath='{.spec.vpcPeerings}' 2>/dev/null)"
table
