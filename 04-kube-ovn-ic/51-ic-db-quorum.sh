#!/bin/bash
# 51-ic-db-quorum.sh — test: what happens when the IC database loses the quorum (two members out of three down)?
#
# What it does : with a ping every 0.3 s between the custom VPCs of the two sites, kills two members and leaves only one.
#                Checks: the surviving member has no leader; the existing traffic does not stop; a subnet created on site
#                B is NOT announced to site A in 40 seconds; after restarting the two members the quorum comes back, the
#                route appears, the three members are aligned and the ping lost during the whole test is zero or very few.
#                The test subnet is removed at the end.
# Environment  : the tenants of 21-ic-tenants.sh and the three members of 12-ic-db-raft.sh
# Changes      : kills and restarts two members; creates and deletes the subnet sub-ic-test on site B
# Requires     : bash >= 3.2, ssh; passwordless sudo on the three machines
# Usage        : ./51-ic-db-quorum.sh
# Variables    : IC_MAX_LOST (from config.env)
# Duration     : about 5 minutes
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (loss of the quorum of the IC database)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
ic_need_tenants
[ "$(db_leader)" != none ] || die "the three members are not up: run ./12-ic-db-raft.sh first"
KILLED=""
cleanup() {
  clear_line
  for s in $KILLED; do db_start "$s" >/dev/null 2>&1; done
  rk a 'kill $(cat /tmp/pingloop.pid) 2>/dev/null; rm -f /tmp/pingloop.pid' >/dev/null 2>&1
  rk b 'kubectl delete subnet sub-ic-test --ignore-not-found >/dev/null 2>&1'
}
trap cleanup EXIT

# The survivor is the member on site A; the other two are killed.
rk b 'kubectl delete subnet sub-ic-test --ignore-not-found >/dev/null 2>&1'
echo "before: A=$(db_status a)  B=$(db_status b)  router=$(db_status r)"
rk a "nohup bash -c 'while true; do if kubectl exec -n $NS_VT c-t -- ping -c1 -W1 $IP_PB >/dev/null 2>&1; then echo ok; else echo lost; fi; sleep 0.3; done' > /tmp/pingloop.log 2>&1 & echo \$! > /tmp/pingloop.pid"
sleep 8

sec "Killing the members of site B and of the router"
db_kill b >/dev/null; db_kill r >/dev/null; KILLED="b r"
nolead() { case "$(db_status a)" in leader*) false;; *) true;; esac; }
WAIT_MSG="the survivor loses the leadership" waitf 30 3 nolead
alive() { [ -n "$(db_status a | awk '{print $2}' | sed 's/term=//')" ]; }
expect "the surviving member is still running" yes "$(alive && echo yes || echo no)"
expect "the surviving member is not a leader" yes "$(nolead && echo yes || echo no)"
# The survivor was usually a follower already: the check above passes at once. What shows that it has noticed the loss
# of the quorum is that it no longer has a leader (role candidate, or leader unknown).
lostleader() { case "$(db_status a)" in candidate*|*leader=unknown*|*leader=) true;; *) false;; esac; }
WAIT_MSG="the survivor notices that the leader is gone" waitf 30 2 lostleader
expect "the surviving member has no leader any more (candidate or leader unknown)" yes "$(lostleader && echo yes || echo no)"
info "survivor: $(db_status a)"
sleep 10
ic_check_traffic() { ic_check "$1" open a "$NS_VT" c-t "$IP_PB"; }
ic_check_traffic "without quorum: c-t -> pb (existing traffic)"
ic_check "without quorum: pb -> c-t (existing traffic)" open b "$NS_VB" pb "$IP_CT"

sec "A subnet created on site B without quorum"
rk b 'kubectl apply -f - >/dev/null' <<'Y'
apiVersion: kubeovn.io/v1
kind: Subnet
metadata: {name: sub-ic-test}
spec: {vpc: ovn-cluster, protocol: IPv4, cidrBlock: 10.85.0.0/24, gatewayType: distributed}
Y
sleep 40
expect "40 s without quorum: routes to 10.85.0.0/24 on site A" 0 "$(ic_routes a 10.85.0.0/24)"

sec "Restarting the two members"
db_start r >/dev/null; db_start b >/dev/null; KILLED=""
hasleader() { [ "$(db_leader)" != none ]; }
WAIT_MSG="the quorum is back" waitf 40 3 hasleader
expect "a leader exists again" yes "$([ "$(db_leader)" != none ] && echo yes || echo no)"
seen() { [ "$(ic_routes a 10.85.0.0/24)" -ge 1 ]; }
WAIT_MSG="site A learns 10.85.0.0/24" waitf 50 3 seen
expect "after the quorum is back site A learns the subnet (routes)" yes "$([ "$(ic_routes a 10.85.0.0/24)" -ge 1 ] && echo yes || echo no)"
aligned() { [ "$(for s in a b r; do db_status "$s" | awk '{print $2}'; done | sort -u | wc -l | tr -d ' ')" = 1 ]; }
WAIT_MSG="same Term on the three members" waitf 30 3 aligned
info "members: a=$(db_status a) | b=$(db_status b) | r=$(db_status r)"
expect "the three members have the same Term" 1 "$(for s in a b r; do db_status "$s" | awk '{print $2}'; done | sort -u | wc -l | tr -d ' ')"
rk b 'kubectl delete subnet sub-ic-test --ignore-not-found >/dev/null'
gone() { [ "$(ic_routes a 10.85.0.0/24)" = 0 ]; }
WAIT_MSG="the route disappears from site A" waitf 40 3 gone
expect "the route of the deleted subnet disappears from site A" 0 "$(ic_routes a 10.85.0.0/24)"

sec "Traffic during the whole test"
rk a 'kill $(cat /tmp/pingloop.pid) 2>/dev/null' >/dev/null
TOT="$(rk a 'wc -l < /tmp/pingloop.log' | tr -d ' ')"; LOST="$(rk a 'grep -c lost /tmp/pingloop.log' | tr -d ' ')"
info "pings sent: $TOT   lost: $LOST"
expect "pings lost during the whole test (at most $IC_MAX_LOST)" yes "$([ "${LOST:-99}" -le "$IC_MAX_LOST" ] && echo yes || echo "no ($LOST)")"
table
