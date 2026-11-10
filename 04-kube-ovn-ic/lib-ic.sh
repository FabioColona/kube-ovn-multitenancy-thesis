#!/bin/bash
# lib-ic.sh — helpers shared by the scripts of 04-kube-ovn-ic. Loaded after lib/common.sh and load_config.
#
# What it provides : site_get, ssh_to, ssh_tty, rk, rk_tty, push_repo, ssh_close (SSH to the machines of the lab),
#                    need_ssh_tools, cidr_overlap.
# Writes files     : none (SSH keeps one connection open per machine in /tmp/ovnic-*, so the password is asked once).
# Requires         : bash >= 3.2 (macOS is fine), ssh and scp.
#
# A "site" is the letter a, b or r (r = router). Variables of a site are SITE_A_*, SITE_B_*, ROUTER_*.

# site_get <a|b|r> <FIELD>: prints the value of SITE_A_<FIELD> / SITE_B_<FIELD> / ROUTER_<FIELD> (HOST, PORT, USER…).
site_get() {
  local p v
  case "$1" in a) p=SITE_A;; b) p=SITE_B;; r) p=ROUTER;; *) die "internal error: site '$1'";; esac
  v="${p}_$2"
  echo "${!v:-}"
}

# One SSH connection per machine stays open for 10 minutes, so the password (if any) is asked only once.
SSH_COMMON=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15
            -o ControlMaster=auto -o "ControlPath=/tmp/ovnic-%C" -o ControlPersist=10m)

# Machines behind a jump host (CrownLabs): SSH_JUMP="user@host" in config.local.env (also used by scp).
[ -n "${SSH_JUMP:-}" ] && SSH_COMMON+=(-J "$SSH_JUMP")

need_ssh_tools() { have ssh && have scp || die "ssh and scp are required"; }

# ssh_to <site> <command>: runs the command on the machine (no terminal).
ssh_to() {
  local s=$1; shift
  ssh -p "$(site_get "$s" PORT)" "${SSH_COMMON[@]}" "$(site_get "$s" USER)@$(site_get "$s" HOST)" "$@"
}
# ssh_tty <site> <command>: same, with a terminal (needed when sudo asks for a password).
ssh_tty() {
  local s=$1; shift
  ssh -t -p "$(site_get "$s" PORT)" "${SSH_COMMON[@]}" "$(site_get "$s" USER)@$(site_get "$s" HOST)" "$@"
}
# rk <site> <command>: runs the command on the machine with KUBECONFIG set (for kubectl).
rk()     { local s=$1; shift; ssh_to  "$s" "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; $*"; }
rk_tty() { local s=$1; shift; ssh_tty "$s" "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; $*"; }

# push_repo <site>: copies lib/ and 02-kube-ovn-setup/ into ~/$REMOTE_DIR on the machine.
push_repo() {
  local s=$1 root; root="$(cd "$HERE/.." && pwd)"
  ssh_to "$s" "mkdir -p \"\$HOME/$REMOTE_DIR\"" || return 1
  scp -q -r -P "$(site_get "$s" PORT)" "${SSH_COMMON[@]}" "$root/lib" "$root/02-kube-ovn-setup" \
      "$(site_get "$s" USER)@$(site_get "$s" HOST):$REMOTE_DIR/" || return 1
  ssh_to "$s" "chmod +x \"\$HOME/$REMOTE_DIR\"/02-kube-ovn-setup/*.sh"
}

# ssh_close: closes the shared connections (they close by themselves after 10 minutes of silence).
ssh_close() {
  local s
  for s in a b r; do ssh -O exit -p "$(site_get "$s" PORT)" "${SSH_COMMON[@]}" "$(site_get "$s" USER)@$(site_get "$s" HOST)" >/dev/null 2>&1; done
  return 0
}

# cidr_overlap <cidr> <cidr>: prints yes or no (needs python3; without it, compares the two strings).
cidr_overlap() {
  if have python3; then
    python3 -c "import ipaddress,sys; sys.exit(0 if ipaddress.ip_network('$1').overlaps(ipaddress.ip_network('$2')) else 1)" 2>/dev/null && echo yes || echo no
  else
    [ "$1" = "$2" ] && echo yes || echo no
  fi
}

# ic_subst: filter that replaces the example addresses written in the manifests (10.1.0.10 = node of site A,
# 10.2.0.10 = node of site B, 10.1.0.1 = router) and the gateway node names (site-a, site-b) with the ones of
# config.env / config.local.env.
ic_subst() {
  sed -e 's/10\.1\.0\.10/@A@/g; s/10\.2\.0\.10/@B@/g; s/10\.1\.0\.1\([",]\)/@R@\1/g' \
      -e "s/@A@/$SITE_A_IP/g; s/@B@/$SITE_B_IP/g; s/@R@/$SITE_A_ROUTER_IP/g" \
      -e "s/gw-nodes: \"site-a\"/gw-nodes: \"$SITE_A_NAME\"/; s/gw-nodes: \"site-b\"/gw-nodes: \"$SITE_B_NAME\"/"
}
# fix_nic_prefix <site>: some clouds (CrownLabs) give the NIC a /32 address, which Kube-OVN 1.13 ignores: the same address
# is added with a /24 prefix and the flag noprefixroute (routing does not change). Does nothing if the address is not a /32.
fix_nic_prefix() {
  local s=$1 P; P=SITE_$(echo "$s" | tr a-z A-Z)
  local IF IP; eval "IF=\${${P}_IFACE} IP=\${${P}_IP}"
  ssh_to "$s" "if ip -4 -o addr show dev $IF | grep -q ' $IP/32 '; then sudo -n ip addr add $IP/24 dev $IF noprefixroute 2>/dev/null; echo fixed; else echo ok; fi"
}
# ic_apply <site> <manifest>: applies a manifest on the site (the file stays on this computer).
ic_apply() { ic_subst < "$2" | ssh_to "$1" 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl apply -f -' >/dev/null; }
# ic_delete <site> <manifest>: removes what a manifest created (no error if it is not there).
ic_delete() { ssh_to "$1" 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl delete --ignore-not-found -f -' < "$2" >/dev/null 2>&1; }
# ic_pod_ip <site> <namespace> <pod>
ic_pod_ip() { rk "$1" "kubectl -n $2 get pod $3 -o jsonpath='{.status.podIP}'" 2>/dev/null; }

# ic_probe <site> <namespace> <pod> <destination IP>: from the pod, one ping and one TCP connection to port 8080.
# Prints open (both work), blocked (none works), ping-only (ping works, TCP 8080 does not), tcp-only (TCP 8080 works,
# ping does not) or error (the two commands did not run in the pod: SSH, kubectl or the pod failed). "error" is never
# an expected result, so a check does not pass because the probe could not run.
ic_probe() {
  local out p t
  out="$(rk "$1" "kubectl -n $2 exec $3 -- sh -c 'ping -c 1 -W 2 $4 >/dev/null 2>&1; echo P=\$?; nc -z -w 2 $4 8080 >/dev/null 2>&1; echo T=\$?'" 2>/dev/null)"
  p="$(printf '%s\n' "$out" | sed -n 's/^P=\([0-9]*\).*/\1/p' | head -1)"
  t="$(printf '%s\n' "$out" | sed -n 's/^T=\([0-9]*\).*/\1/p' | head -1)"
  [ -n "$p" ] && [ -n "$t" ] || { echo error; return; }
  [ "$p" = 0 ] && p=1 || p=0
  [ "$t" = 0 ] && t=1 || t=0
  case "$p$t" in 11) echo open;; 00) echo blocked;; 10) echo ping-only;; 01) echo tcp-only;; esac
}
# ic_probe_n <site> <namespace> <pod> <destination IP>: REPETITIONS probes; prints "open x5" or a count per result.
ic_probe_n() {
  local i out=""
  for ((i=0;i<REPETITIONS;i++)); do
    tick "probing $3 -> $4" $((i+1)) "$REPETITIONS"
    out="$out$(ic_probe "$@")"$'\n'
  done
  clear_line
  if [ "$(printf '%s' "$out" | sort -u | wc -l | tr -d ' ')" -eq 1 ]; then echo "$(printf '%s' "$out" | head -1) x$REPETITIONS"
  else printf '%s' "$out" | sort | uniq -c | awk '{print $2" "$1}' | paste -sd, - | sed 's/,/, /g'; fi
}
# ic_check <label> <open|blocked|ping-only|tcp-only> <site> <namespace> <pod> <destination IP>
ic_check() { expect "$1" "$2 x$REPETITIONS" "$(ic_probe_n "$3" "$4" "$5" "$6")"; }
# ic_wait_probe <expected> <seconds> <site> <namespace> <pod> <destination IP>: waits until one probe gives the
# expected result (used to let a policy settle before measuring).
_ic_is() { [ "$(ic_probe "${@:2}")" = "$1" ]; }
ic_wait_probe() { local w=$1 s=$2; shift 2; WAIT_MSG="waiting for $3 -> $4 to be $w" waitf $((s/2)) 2 _ic_is "$w" "$@"; }

# ic_patch <site> <kind> <name> <manifest>: merge patch (YAML or JSON file on this computer). Arrays are REPLACED.
ic_patch() { rk "$1" "kubectl patch $2 $3 --type merge -p \"\$(cat)\"" < "$4" >/dev/null; }
# ic_ttl <site> <namespace> <pod> <destination IP>: TTL of the reply to one ping (empty if there is none).
ic_ttl() { rk "$1" "kubectl -n $2 exec $3 -- ping -c 1 -W 2 $4 2>/dev/null" | sed -n 's/.*ttl=\([0-9]*\).*/\1/p' | head -1; }
# ic_who <site> <namespace> <pod> <destination IP>: content of /who served by the destination (empty if no answer).
ic_who() { rk "$1" "kubectl -n $2 exec $3 -- wget -qO- -T2 http://$4:8080/who 2>/dev/null" | tr -d '\r\n'; }
# ic_who_n <site> <namespace> <pod> <destination IP>: REPETITIONS readings of /who; prints "SITE-A x5" or a count per
# answer ("none" = no answer).
ic_who_n() {
  local i w out=""
  for ((i=0;i<REPETITIONS;i++)); do
    tick "asking $4 from $3" $((i+1)) "$REPETITIONS"
    w="$(ic_who "$@")"; out="$out${w:-none}"$'\n'
  done
  clear_line
  if [ "$(printf '%s' "$out" | sort -u | wc -l | tr -d ' ')" -eq 1 ]; then echo "$(printf '%s' "$out" | head -1) x$REPETITIONS"
  else printf '%s' "$out" | sort | uniq -c | awk '{print $2" "$1}' | paste -sd, - | sed 's/,/, /g'; fi
}
# ic_routes <site> <CIDR>: number of lines of the routes of ovn-cluster that contain the CIDR and are learned from OVN-IC
# ("error" if the routes cannot be read, so that a check expecting 0 does not pass because the command failed).
ic_routes() {
  local out
  out="$(rk "$1" "kubectl ko nbctl lr-route-list ovn-cluster 2>/dev/null")" || { echo error; return; }
  printf '%s\n' "$out" | grep -c "$2.*learned"
}
# ic_vpc_route <site> <router (VPC name)> <CIDR>: yes if the routes of that router contain the CIDR, no if they do not,
# error if they cannot be read.
ic_vpc_route() {
  local out
  out="$(rk "$1" "kubectl ko nbctl lr-route-list $2 2>/dev/null")" || { echo error; return; }
  printf '%s\n' "$out" | grep -qF "$3" && echo yes || echo no
}
_ic_vpc_route_is() { [ "$(ic_vpc_route "$1" "$2" "$3")" = yes ]; }
# ic_need_tenants: stops unless 21-ic-tenants.sh has created the pods.
ic_need_tenants() {
  rk a "kubectl -n $NS_VT get pod c-t >/dev/null 2>&1" && rk b "kubectl -n $NS_VB get pod pb >/dev/null 2>&1" \
    || die "the tenants are not there: run ./21-ic-tenants.sh first"
}
# ic_restore_baseline: puts back the routes and the allowSubnets of the baseline (manifests 42, 45, 47, 48, 50).
ic_restore_baseline() {
  local M="$HERE/manifests"
  ic_patch a vpc vpc-t "$M/42-vpc-t-peering.yaml"
  ic_patch b vpc vpc-custom-b "$M/45-vpc-custom-b-peering.yaml"
  ic_patch a subnet sub-t-a "$M/47-sub-t-a-baseline.yaml"
  ic_patch b subnet sub-t-b "$M/48-sub-t-b-baseline.yaml"
  ic_patch b subnet sub-t-b "$M/50-sub-t-b-acl-remove.yaml"
}

# ---- IC database with three members (containers ovn-ic-db on site A, site B and the router) ----
IC_NB_CTL="/var/run/ovn/ovn_ic_nb_db.ctl"
# db_exec <a|b|r> <command...>: runs the command inside the container ovn-ic-db of that machine.
db_exec() {
  local s=$1; shift
  if [ "$s" = r ]; then ssh_to r "sudo -n docker exec ovn-ic-db $*"
  else ssh_to "$s" "sudo -n ctr -n k8s.io task exec --exec-id e\$(date +%s%N) ovn-ic-db $*"; fi
}
# db_kill <a|b|r>: SIGKILL to the member.
db_kill() { if [ "$1" = r ]; then ssh_to r 'sudo -n docker kill ovn-ic-db'; else ssh_to "$1" 'sudo -n ctr -n k8s.io task kill -s SIGKILL ovn-ic-db'; fi; }
# db_start <a|b|r>: starts the member again (after a kill ctr needs the old task deleted first).
db_start() {
  if [ "$1" = r ]; then ssh_to r 'sudo -n docker start ovn-ic-db'
  else ssh_to "$1" 'sudo -n ctr -n k8s.io task delete ovn-ic-db >/dev/null 2>&1; sudo -n ctr -n k8s.io task start -d ovn-ic-db'; fi
}
# db_status <a|b|r>: "Role Term Leader" of the member in the Raft cluster of the northbound IC database.
db_status() { db_exec "$1" "ovs-appctl -t $IC_NB_CTL cluster/status OVN_IC_Northbound" 2>/dev/null | awk -F': ' '/^Role/{r=$2} /^Term/{t=$2} /^Leader/{l=$2} END{print r" term="t" leader="l}'; }
# db_leader: the site (a|b|r) whose member is the leader, or none.
db_leader() { local s; for s in a b r; do case "$(db_status "$s")" in leader*) echo "$s"; return;; esac; done; echo none; }
# ic_icsb_show: zones of the IC database, wherever the database runs (pod of install-ic-server.sh or containers).
ic_icsb_show() {
  if rk a 'kubectl -n kube-system get deploy ovn-ic-server -o jsonpath="{.status.readyReplicas}" 2>/dev/null' | grep -q '^[1-9]'; then rk a 'kubectl ko icsbctl show'
  else db_exec a "ovn-ic-sbctl --no-leader-only show"; fi
}
