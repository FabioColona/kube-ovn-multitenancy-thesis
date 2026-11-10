#!/bin/bash
# 12-ic-db-raft.sh — moves the OVN-IC database from the single pod of site A to a Raft cluster of three members.
#
# What it does : stops the ovn-ic-server pod of site A and starts one container ovn-ic-db on site A (leader, containerd of
#                K3s), one on site B (containerd) and one on the router (Docker), with the procedure "High availability
#                deployment solution 2" of the Kube-OVN documentation. Then puts the three addresses in ic-db-host of both
#                sites (deleting ovn-ic-config and applying it again, as the documentation asks), restarts the
#                ovn-ic-controllers, waits until the three members agree and both zones are back, and counts the routes
#                learned for each remote CIDR once the count is stable (one transit switch: one route expected).
# Note         : all the members run start-ic-db.sh without the lines of ovn-ic-nbctl (only the leader creates the transit
#                switch) and without the leader checker, which needs the Kubernetes API and stops the container outside a pod.
# Note         : the script start-ic-db.sh of Kube-OVN v1.13.0 needs POD_IP (first address of NODE_IPS = leader) and
#                ENABLE_SSL=false; it creates ONE transit switch (TS_NUM is ignored).
# Environment  : two sites with OVN-IC installed by 11-install-ic.sh; Docker on the router; passwordless sudo on the three
#                machines; the Kube-OVN image on the sites (it is there after the installation) and internet on the router
# Note         : the members use their own host directories ($IC_DB_DIR), NOT /etc/ovn, /var/run/ovn or /var/log/ovn: those
#                belong to ovn-central and sharing them breaks it (it runs as an unprivileged user).
# Changes      : CHANGES THE LAB: scales ovn-ic-server to 0, creates three containers and recreates ovn-ic-config.
#                90-reset.sh removes them. Run it once.
# Requires     : bash >= 3.2, ssh
# Usage        : ./12-ic-db-raft.sh
# Variables    : SITE_*, ROUTER_*, IC_DB_IMAGE, IC_DB_DIR, IC_TS_NUM (from config.env)
# Duration     : about 5 minutes (up to 10 more while the learned routes settle)
# Exit code    : 0 = three members, both zones and one learned route per remote CIDR on each site; 1 = a check failed;
#                2 = prerequisite missing
# In the thesis: Chapter 5 (IC database with three members)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
load_config "$HERE"
. "$HERE/lib-ic.sh"
set -uo pipefail

need_ssh_tools
M="$HERE/manifests"
for s in a b r; do ssh_to "$s" 'sudo -n true' 2>/dev/null || die "passwordless sudo is needed on $(site_get "$s" HOST):$(site_get "$s" PORT)"; done
ssh_to r 'sudo -n docker version >/dev/null 2>&1' || die "Docker is not usable on the router: install it (apt install docker.io) and try again"
ssh_to a 'sudo -n ctr -n k8s.io task ls >/dev/null 2>&1' || die "ctr cannot reach containerd on site A (K3s): is K3s running?"
# Members left by an earlier attempt are removed (their data is recreated anyway)
for s in a b; do ssh_to "$s" 'sudo -n ctr -n k8s.io task kill -s SIGKILL ovn-ic-db >/dev/null 2>&1; sleep 1; sudo -n ctr -n k8s.io task delete -f ovn-ic-db >/dev/null 2>&1; sudo -n ctr -n k8s.io container delete ovn-ic-db >/dev/null 2>&1; sudo -n rm -rf /run/containerd/runc/k8s.io/ovn-ic-db /run/k3s/containerd/runc/k8s.io/ovn-ic-db; true'; done
ssh_to r 'sudo -n docker rm -f ovn-ic-db >/dev/null 2>&1; true'

NODE_IPS="$SITE_A_IP,$SITE_A_ROUTER_IP,$SITE_B_IP"
sec "Stopping the pod of site A"
rk a 'kubectl -n kube-system scale deploy/ovn-ic-server --replicas=0 >/dev/null && kubectl -n kube-system wait --for=delete pod -l app=ovn-ic-server --timeout=120s >/dev/null 2>&1; true'
info "ovn-ic-server scaled to 0"

CTR_LEADER="sudo -n ctr -n k8s.io run -d --env ENABLE_OVN_LEADER_CHECK=false --env ENABLE_SSL=false --net-host --privileged --mount type=bind,src=$IC_DB_DIR/etc,dst=/etc/ovn,options=rbind:rw --mount type=bind,src=$IC_DB_DIR/run,dst=/var/run/ovn,options=rbind:rw --mount type=bind,src=$IC_DB_DIR/log,dst=/var/log/ovn,options=rbind:rw --env NODE_IPS=$NODE_IPS --env POD_IP=$SITE_A_IP --env LOCAL_IP=$SITE_A_IP docker.io/$IC_DB_IMAGE ovn-ic-db bash -c 'sed /ovn-ic-nbctl/d /kube-ovn/start-ic-db.sh > /tmp/start-member.sh && exec bash /tmp/start-member.sh'"
CTR_FOLLOWER="sudo -n ctr -n k8s.io run -d --env ENABLE_OVN_LEADER_CHECK=false --env ENABLE_SSL=false --net-host --privileged --mount type=bind,src=$IC_DB_DIR/etc,dst=/etc/ovn,options=rbind:rw --mount type=bind,src=$IC_DB_DIR/run,dst=/var/run/ovn,options=rbind:rw --mount type=bind,src=$IC_DB_DIR/log,dst=/var/log/ovn,options=rbind:rw --env NODE_IPS=$NODE_IPS --env POD_IP=$SITE_B_IP --env LOCAL_IP=$SITE_B_IP docker.io/$IC_DB_IMAGE ovn-ic-db bash -c 'sed /ovn-ic-nbctl/d /kube-ovn/start-ic-db.sh > /tmp/start-follower.sh && exec bash /tmp/start-follower.sh'"
DOCKER_FOLLOWER="sudo -n docker run --name=ovn-ic-db -d -e ENABLE_OVN_LEADER_CHECK=false -e ENABLE_SSL=false --network=host --privileged -v $IC_DB_DIR/etc:/etc/ovn -v $IC_DB_DIR/run:/var/run/ovn -v $IC_DB_DIR/log:/var/log/ovn -e POD_IP=$SITE_A_ROUTER_IP -e LOCAL_IP=$SITE_A_ROUTER_IP -e NODE_IPS=$NODE_IPS $IC_DB_IMAGE bash -c 'sed /ovn-ic-nbctl/d /kube-ovn/start-ic-db.sh > /tmp/start-follower.sh && exec bash /tmp/start-follower.sh'"

sec "Starting the three members"
ssh_to a "sudo -n rm -rf $IC_DB_DIR && sudo -n mkdir -p $IC_DB_DIR/etc $IC_DB_DIR/run $IC_DB_DIR/log; $CTR_LEADER" || die "cannot start the leader on site A"
info "site A: leader started"
leader_up() { ssh_to a "sudo -n ctr -n k8s.io task exec --exec-id w\$(date +%s%N) ovn-ic-db ovs-appctl -t $IC_NB_CTL cluster/status OVN_IC_Northbound" | grep -q '^Role: leader'; }
WAIT_MSG="waiting for the leader (up to 2 minutes)" waitf 40 3 leader_up || { ssh_to a "sudo -n ctr -n k8s.io task ls | grep ovn-ic-db; ls -l $IC_DB_DIR/run $IC_DB_DIR/etc | head -20; tail -n 20 $IC_DB_DIR/log/*.log" >&2; die "the leader does not start: see the task state above"; }
ssh_to b "sudo -n rm -rf $IC_DB_DIR && sudo -n mkdir -p $IC_DB_DIR/etc $IC_DB_DIR/run $IC_DB_DIR/log; $CTR_FOLLOWER" || die "cannot start the member on site B"
info "site B: follower started"
ssh_to r "sudo -n rm -rf $IC_DB_DIR && sudo -n mkdir -p $IC_DB_DIR/etc $IC_DB_DIR/run $IC_DB_DIR/log; sudo -n docker pull $IC_DB_IMAGE >/dev/null 2>&1; $DOCKER_FOLLOWER" >/dev/null || die "cannot start the member on the router"
info "router: follower started"

is_member() { case "$(db_status "$1")" in leader*|follower*) return 0;; esac; return 1; }
members_ok() { local s n=0; for s in a b r; do case "$(db_status "$s")" in leader*|follower*) n=$((n+1));; esac; done; [ "$n" = 3 ]; }
WAIT_MSG="three members in the cluster" waitf 40 3 members_ok
# The members run start-ic-db.sh WITHOUT its ovn-ic-nbctl lines (a member restarted as follower would stop on them): the
# transit switch is created here, once, on the leader.
db_exec a "ovn-ic-nbctl --may-exist ts-add ts" >/dev/null || die "cannot create the transit switch"
db_exec a "ovn-ic-nbctl set Transit_Switch ts external_ids:subnet=169.254.100.0/24" >/dev/null || die "cannot set the subnet of the transit switch"

sec "Addresses of the database in both sites"
# The documentation asks to delete ovn-ic-config and apply it again instead of changing it in place
ic_delete a "$M/12-ovn-ic-config-site-a-raft.yaml"; ic_delete b "$M/12-ovn-ic-config-site-b-raft.yaml"
sleep 5
ic_apply a "$M/12-ovn-ic-config-site-a-raft.yaml" && ic_apply b "$M/12-ovn-ic-config-site-b-raft.yaml" || die "cannot apply the ConfigMaps"
info "ovn-ic-config deleted and applied again on both sites (three addresses in ic-db-host)"
# Ports left in the local Northbound DBs by the previous IC database (other transit switches) make the controller fail
# with "constraint violation": they are removed, the controller creates them again.
for s in a b; do
  rk "$s" 'for t in ts ts1 ts2; do for az in '"$SITE_A_AZ $SITE_B_AZ"'; do kubectl ko nbctl --if-exists lrp-del $az-$t; kubectl ko nbctl --if-exists lsp-del $t-$az; done; done; kubectl ko nbctl --if-exists ls-del ts1; kubectl ko nbctl --if-exists ls-del ts2' >/dev/null 2>&1
done
for s in a b; do rk "$s" 'kubectl -n kube-system rollout restart deploy/ovn-ic-controller >/dev/null'; done
for s in a b; do run_spin "site $s: ovn-ic-controller" "up to 3 minutes" rk "$s" 'kubectl -n kube-system rollout status deploy/ovn-ic-controller --timeout=180s' || warn "controller of site $s not ready"; done
zones_ok() { local o; o="$(ic_icsb_show 2>/dev/null)"; grep -q "availability-zone $SITE_A_AZ" <<<"$o" && grep -q "availability-zone $SITE_B_AZ" <<<"$o"; }
WAIT_MSG="both zones" waitf 40 3 zones_ok

for s in a b r; do
  st="$(db_status "$s")"
  expect "member on $s is in the cluster" yes "$(is_member "$s" && echo yes || echo "$st")"
done
expect "one leader among the three members" 1 "$(for s in a b r; do db_status "$s"; done | grep -c '^leader')"
expect "zone $SITE_A_AZ in the IC database" yes "$(ic_icsb_show 2>/dev/null | grep -q "availability-zone $SITE_A_AZ" && echo yes || echo no)"
expect "zone $SITE_B_AZ in the IC database" yes "$(ic_icsb_show 2>/dev/null | grep -q "availability-zone $SITE_B_AZ" && echo yes || echo no)"
has_routes() { [ "$(ic_routes a "$SITE_B_POD_CIDR")" -ge 1 ] && [ "$(ic_routes b "$SITE_A_POD_CIDR")" -ge 1 ]; }
WAIT_MSG="routes learned" waitf 40 3 has_routes
# Routes learned through the transit switches of the previous database can stay for a while: the count is read until it
# has not changed for 3 readings 10 s apart (at most 10 minutes), then compared with the expected value.
LAST=""; SAME=0; T0=$SECONDS; TCHG=0
while :; do
  RA="$(ic_routes a "$SITE_B_POD_CIDR")"; RB="$(ic_routes b "$SITE_A_POD_CIDR")"
  if [ "$RA $RB" = "$LAST" ]; then SAME=$((SAME+1)); else SAME=0; LAST="$RA $RB"; TCHG=$((SECONDS-T0)); info "routes per remote CIDR at +$((SECONDS-T0)) s: $RA (site A), $RB (site B)"; fi
  [ "$SAME" -ge 2 ] && break
  [ $((SECONDS-T0)) -ge 600 ] && { warn "the number of routes still changes after 10 minutes"; break; }
  sleep 10
done
info "routes per remote CIDR, unchanged since +$TCHG s: $RA (site A), $RB (site B); with the single-pod installation there were $IC_TS_NUM"
for s in a b; do
  c=$SITE_B_POD_CIDR; [ "$s" = b ] && c=$SITE_A_POD_CIDR
  info "learned routes to $c on site $s:"
  rk "$s" "kubectl ko nbctl lr-route-list ovn-cluster 2>/dev/null | grep '$c.*learned' | head -5" | sed 's/^/    /'
done
# start-ic-db.sh of this image creates a single transit switch (it ignores TS_NUM), so one route per CIDR is expected
expect "routes to $SITE_B_POD_CIDR learned on site A (one transit switch)" 1 "$RA"
expect "routes to $SITE_A_POD_CIDR learned on site B (one transit switch)" 1 "$RB"
table
