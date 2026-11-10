#!/bin/bash
# 43-component-restart.sh — test: does the tenant configuration survive the restart of a Kube-OVN component?
#
# What it does : builds the state of 32-vpc-peering.sh (vpc-t peered with ovn-cluster, policy 29600, allowSubnets on
#                sub-t), saves the OVN routes, policies and ACLs, starts a ping every 0.2 s from c-t to d1, restarts the
#                component, waits until it is ready again, then checks that no ping was lost, that the OVN objects are
#                identical, that the isolation checks give the same answers and that a NEW pod gets an address.
# Environment  : cluster with the tenants (10-apply-tenants.sh) and the VPCs (30-apply-vpcs.sh)
# Changes      : PATCHES vpc-t, ovn-cluster and sub-t (restored at the end); RESTARTS the chosen component of
#                kube-system; creates one temporary pod in ns-t
# Requires     : bash >= 4, kubectl (with the kubectl-ko plugin installed by Kube-OVN)
# Usage        : ./43-component-restart.sh [controller|ovn-central|ovs-ovn|cni]     (default: controller)
#                  controller  -> deployment/kube-ovn-controller    ovn-central -> deployment/ovn-central
#                  ovs-ovn     -> daemonset/ovs-ovn                 cni         -> daemonset/kube-ovn-cni
# Variables    : NS_T, NS_U, NS_SHARED, NS_VT, NS_VU, VPC_T, SUBNET_T, REPETITIONS, SETTLE_SECONDS (from config.env)
# Duration     : about 6 minutes with 5 repetitions
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (restart of the control components)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-tenancy.sh"
set -uo pipefail

need_cluster
kubectl ko nbctl show >/dev/null 2>&1 || die "the kubectl-ko plugin is not available (installed by Kube-OVN in /usr/local/bin)"
case "${1:-controller}" in
  controller)  COMP=kube-ovn-controller; KIND=deployment;;
  ovn-central) COMP=ovn-central;         KIND=deployment;;
  ovs-ovn)     COMP=ovs-ovn;             KIND=daemonset;;
  cni)         COMP=kube-ovn-cni;        KIND=daemonset;;
  *) die "unknown component '$1' (use controller, ovn-central, ovs-ovn or cni)";;
esac
kubectl -n kube-system get "$KIND/$COMP" >/dev/null 2>&1 || die "$KIND/$COMP not found in kube-system"
CT="$(pod_ip "$NS_VT" c-t)"; CU="$(pod_ip "$NS_VU" c-u)"; D1="$(pod_ip "$NS_SHARED" d1)"; T1="$(pod_ip "$NS_T" t1)"; U1="$(pod_ip "$NS_U" u1)"
[ -n "$CT" ] && [ -n "$CU" ] && [ -n "$D1" ] && [ -n "$T1" ] && [ -n "$U1" ] || die "test pods not found: run ./10-apply-tenants.sh and ./30-apply-vpcs.sh first"
M="$HERE/manifests"
CIDR_T="$(kubectl get subnet "$SUBNET_T" -o jsonpath='{.spec.cidrBlock}')"

restore() {
  kubectl -n "$NS_VT" exec c-t -- touch /tmp/stop >/dev/null 2>&1
  kubectl -n "$NS_T" delete pod np-restart --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl patch vpc "$VPC_T" --type merge -p '{"spec":{"vpcPeerings":null,"staticRoutes":null}}' >/dev/null 2>&1
  kubectl patch vpc ovn-cluster --type merge -p '{"spec":{"vpcPeerings":null,"staticRoutes":null,"policyRoutes":null}}' >/dev/null 2>&1
  kubectl patch subnet "$SUBNET_T" --type merge -p '{"spec":{"allowSubnets":null}}' >/dev/null 2>&1
}
trap restore EXIT
restore; sleep 5

# snapshot: routes, policies and ACLs that the tenant configuration produces in OVN, sorted and without extra spaces.
# A command that fails leaves a line "SNAPSHOT-ERROR ...": the script stops if it is in the first snapshot, and the
# comparison fails if it is in the second one.
snapshot() {
  {
    kubectl ko nbctl lr-route-list ovn-cluster   || echo "SNAPSHOT-ERROR routes of ovn-cluster"
    kubectl ko nbctl lr-policy-list ovn-cluster  || echo "SNAPSHOT-ERROR policies of ovn-cluster"
    kubectl ko nbctl lr-route-list "$VPC_T"      || echo "SNAPSHOT-ERROR routes of $VPC_T"
    kubectl ko nbctl acl-list "$SUBNET_T"        || echo "SNAPSHOT-ERROR ACLs of $SUBNET_T"
  } 2>/dev/null | sed 's/[[:space:]]\+/ /g' | sort
}
# isolation checks, run before and after the restart: label prefix in $1.
checks() {
  check_probe "$1: c-t -> d1 (peering, allow 29600)"    open    "$NS_VT"     c-t "$D1"
  check_probe "$1: c-t -> t1 (allowSubnets of sub-t)"   open    "$NS_VT"     c-t "$T1"
  check_probe "$1: c-u -> d1 (vpc-u, no peering)"       blocked "$NS_VU"     c-u "$D1"
  check_probe "$1: u1 -> t1 (private subnets)"          blocked "$NS_U"      u1  "$T1"
  check_probe "$1: d1 -> t1 (default subnet to private)" blocked "$NS_SHARED" d1  "$T1"
}

sec "State before the restart: peering of vpc-t, policy 29600, allowSubnets on $SUBNET_T"
kubectl patch vpc "$VPC_T" --type merge --patch-file "$M/52-vpc-t-peering-patch.yaml" >/dev/null || die "cannot patch $VPC_T"
kubectl patch vpc ovn-cluster --type merge --patch-file "$M/53-ovn-cluster-peering-patch.yaml" >/dev/null || die "cannot patch ovn-cluster"
kubectl patch vpc ovn-cluster --type merge --patch-file "$M/54-ovn-cluster-allow-policy.yaml" >/dev/null || die "cannot patch ovn-cluster"
kubectl patch subnet "$SUBNET_T" --type merge --patch-file "$M/55-sub-t-allow-vpc.yaml" >/dev/null || die "cannot patch $SUBNET_T"
wait_flow ok 60 "$NS_VT" c-t "$T1" ping || warn "c-t still cannot reach t1 after 60 s"
sleep "$SETTLE_SECONDS"
checks "before"
BEFORE="$(snapshot)"
grep -q SNAPSHOT-ERROR <<<"$BEFORE" && die "cannot read the OVN state before the restart (kubectl ko failed)"
info "saved $(wc -l <<<"$BEFORE") lines of OVN routes, policies and ACLs"

sec "Restarting $KIND/$COMP with a ping every 0.2 s from c-t to d1"
kubectl -n "$NS_VT" exec -i c-t -- sh -c 'cat > /tmp/loop.sh' <<'LOOP' || die "cannot write the ping loop into c-t"
#!/bin/sh
rm -f /tmp/stop
: > /tmp/pings
while [ ! -f /tmp/stop ]; do
  if ping -c 1 -W 1 "$1" >/dev/null 2>&1; then echo ok >> /tmp/pings; else echo lost >> /tmp/pings; fi
  sleep 0.2
done
LOOP
kubectl -n "$NS_VT" exec c-t -- sh -c "sh /tmp/loop.sh $D1 >/dev/null 2>&1 &" || die "cannot start the ping loop"
sleep 5
kubectl -n "$NS_VT" exec c-t -- test -s /tmp/pings || die "the ping loop in c-t is not producing samples"
kubectl -n kube-system rollout restart "$KIND/$COMP" >/dev/null || die "cannot restart $KIND/$COMP"
run_spin "restarting $COMP" "up to 2 minutes" kubectl -n kube-system rollout status "$KIND/$COMP" --timeout=300s || warn "$COMP not ready after 5 minutes"
WAIT_MSG="waiting for the OVN northbound database" waitf 60 2 kubectl ko nbctl show || warn "database not reachable after 2 minutes"
sleep "$SETTLE_SECONDS"
kubectl -n "$NS_VT" exec c-t -- touch /tmp/stop || warn "cannot stop the ping loop"
sleep 2
SENT="$(kubectl -n "$NS_VT" exec c-t -- sh -c 'wc -l < /tmp/pings' 2>/dev/null | tr -d ' ')"
LOST="$(kubectl -n "$NS_VT" exec c-t -- sh -c 'grep -c lost /tmp/pings' 2>/dev/null | tr -d ' ')"
info "pings sent: ${SENT:-?}   lost: ${LOST:-?}"

sec "Checks"
expect "pings lost during the restart (out of ${SENT:-?} sent)" 0 "${LOST:-?}"
AFTER="$(snapshot)"
if [ "$BEFORE" = "$AFTER" ]; then expect "OVN routes, policies and ACLs" unchanged unchanged
else
  record "OVN routes, policies and ACLs" unchanged different FAIL
  diff <(echo "$BEFORE") <(echo "$AFTER") | head -10 | sed 's/^/    /'
fi
checks "after"
kubectl -n "$NS_T" run np-restart --image=docker.io/library/busybox:1.36 --restart=Never -- sleep 600 >/dev/null 2>&1
wait_pod_ready "$NS_T" np-restart || warn "the new pod is not Ready after 3 minutes"
NEW="$(pod_ip "$NS_T" np-restart)"
expect "new pod created after the restart gets an address in $CIDR_T" yes "$( [ -n "$NEW" ] && in_cidr "$NEW" "$CIDR_T" || echo no )"
table
