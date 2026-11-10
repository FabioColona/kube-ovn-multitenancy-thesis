#!/bin/bash
# 50-ic-db-failover.sh — test: what happens to the interconnection when the leader of the IC database is killed?
#
# What it does : with the three members of 12-ic-db-raft.sh and a ping every 0.3 s between the custom VPCs of the two
#                sites (c-t -> pb, double peering), kills the leader (SIGKILL). Checks: another member becomes leader, the
#                ping loses at most IC_MAX_LOST pings, a subnet created on site B while a member is down is announced to
#                site A (2 members out of 3 are enough), the killed member comes back as a follower and is aligned
#                (same Term). The test subnet is removed at the end.
# Environment  : the tenants of 21-ic-tenants.sh and the three members of 12-ic-db-raft.sh
# Changes      : kills and restarts a member; creates and deletes the subnet sub-ic-test on site B
# Requires     : bash >= 3.2, ssh; passwordless sudo on the three machines
# Usage        : ./50-ic-db-failover.sh
# Variables    : IC_MAX_LOST (from config.env)
# Duration     : about 4 minutes
# Exit code    : 0 = all PASS; 1 = at least one FAIL; 2 = prerequisite missing
# In the thesis: Chapter 5 (failover of the IC database)

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
  [ -n "$KILLED" ] && db_start "$KILLED" >/dev/null 2>&1
  rk a 'kill $(cat /tmp/pingloop.pid) 2>/dev/null; rm -f /tmp/pingloop.pid' >/dev/null 2>&1
  rk b 'kubectl delete subnet sub-ic-test --ignore-not-found >/dev/null 2>&1'
}
trap cleanup EXIT

LEADER="$(db_leader)"
echo "leader before the test: $LEADER ($(db_status "$LEADER"))"
rk b 'kubectl delete subnet sub-ic-test --ignore-not-found >/dev/null 2>&1'
rk a "nohup bash -c 'while true; do if kubectl exec -n $NS_VT c-t -- ping -c1 -W1 $IP_PB >/dev/null 2>&1; then echo ok; else echo lost; fi; sleep 0.3; done' > /tmp/pingloop.log 2>&1 & echo \$! > /tmp/pingloop.pid"
sleep 8

sec "Killing the leader ($LEADER)"
db_kill "$LEADER" >/dev/null; KILLED="$LEADER"
new_leader() { local l; l="$(db_leader)"; [ "$l" != none ] && [ "$l" != "$LEADER" ]; }
WAIT_MSG="a new leader is elected" waitf 40 3 new_leader
NEW="$(db_leader)"
expect "a different member becomes leader" yes "$([ "$NEW" != none ] && [ "$NEW" != "$LEADER" ] && echo yes || echo no)"
info "new leader: $NEW ($(db_status "$NEW" 2>/dev/null))"

sec "Announcing a subnet with the leader down (2 members out of 3)"
rk b 'kubectl apply -f - >/dev/null' <<'Y'
apiVersion: kubeovn.io/v1
kind: Subnet
metadata: {name: sub-ic-test}
spec: {vpc: ovn-cluster, protocol: IPv4, cidrBlock: 10.85.0.0/24, gatewayType: distributed}
Y
seen() { [ "$(ic_routes a 10.85.0.0/24)" -ge 1 ]; }
WAIT_MSG="site A learns 10.85.0.0/24" waitf 50 3 seen
expect "site A learns the new subnet with 2 members out of 3 (routes)" yes "$([ "$(ic_routes a 10.85.0.0/24)" -ge 1 ] && echo yes || echo no)"

sec "Restarting the killed member"
db_start "$KILLED" >/dev/null; KILLED=""
back() { case "$(db_status "$LEADER")" in follower*) true;; *) false;; esac; }
WAIT_MSG="the member is back as follower" waitf 40 3 back
expect "the killed member comes back as follower" follower "$(db_status "$LEADER" | awk '{print $1}')"
aligned() { [ "$(for s in a b r; do db_status "$s" | awk '{print $2}'; done | sort -u | wc -l | tr -d ' ')" = 1 ]; }
WAIT_MSG="same Term on the three members" waitf 20 3 aligned
info "members: a=$(db_status a) | b=$(db_status b) | r=$(db_status r)"
expect "the three members have the same Term" 1 "$(for s in a b r; do db_status "$s" | awk '{print $2}'; done | sort -u | wc -l | tr -d ' ')"
rk b 'kubectl delete subnet sub-ic-test --ignore-not-found >/dev/null'
gone() { [ "$(ic_routes a 10.85.0.0/24)" = 0 ]; }
WAIT_MSG="the route disappears from site A" waitf 40 3 gone
expect "the route of the deleted subnet disappears from site A" 0 "$(ic_routes a 10.85.0.0/24)"

sec "Traffic during the test"
rk a 'kill $(cat /tmp/pingloop.pid) 2>/dev/null' >/dev/null
TOT="$(rk a 'wc -l < /tmp/pingloop.log' | tr -d ' ')"; LOST="$(rk a 'grep -c lost /tmp/pingloop.log' | tr -d ' ')"
info "pings sent: $TOT   lost: $LOST"
expect "pings lost while the leader was killed (at most $IC_MAX_LOST)" yes "$([ "${LOST:-99}" -le "$IC_MAX_LOST" ] && echo yes || echo "no ($LOST)")"
table
