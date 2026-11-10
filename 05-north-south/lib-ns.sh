#!/bin/bash
# lib-ns.sh — helpers shared by the scripts of 05-north-south. Loaded after lib/common.sh and load_config.
#
# What it provides : ns_setup, node_n, node_host, node_ip, node_iface, node_mtu, in_list, nssh, nroot, rk, rks,
#                    push_repo, ns_close (SSH to the machines of the test bed).
# Writes files     : none (SSH keeps one connection open per machine in /tmp/ns-*, so a password is asked once).
# Requires         : bash >= 3.2 (macOS is fine), ssh and scp.
#
# Machines are numbered by their position in NODES: 1, 2, 3 …

SSH_COMMON=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15
            -o ControlMaster=auto -o "ControlPath=/tmp/ns-%C" -o ControlPersist=10m)

# ns_setup: checks the variables and tools; call it right after load_config.
ns_setup() {
  require_vars NODES NODE_USER SSH_PORT CLUSTER_NODES FABRIC_NODE GATEWAY_NODES
  have ssh && have scp || die "ssh and scp are required"
  [ -n "${SSH_JUMP:-}" ] && SSH_COMMON+=(-J "$SSH_JUMP")
  SERVER="${CLUSTER_NODES%% *}"        # machine that runs the K3s server and kubectl
  return 0
}

node_n() { set -- $NODES; echo $#; }
node_host() {   # node_host <n>: SSH name of machine n
  local i=$1; set -- $NODES
  [ "$i" -ge 1 ] 2>/dev/null && [ "$i" -le "$#" ] || die "there is no machine number $i in NODES"
  eval "echo \"\${$i}\""
}
in_list() {     # in_list <n> <list>: 0 if n is in the space-separated list
  local n=$1 x; shift
  for x in $*; do [ "$x" = "$n" ] && return 0; done
  return 1
}

nssh() { local i=$1; shift; ssh -p "$SSH_PORT" "${SSH_COMMON[@]}" "$NODE_USER@$(node_host "$i")" "$@"; }
# nroot <n> [VAR=value …]: runs the script read from STDIN as root on machine n (the variables are passed in the environment).
nroot() { local i=$1; shift; nssh "$i" "sudo -n env ${*:-NS=1} bash -s"; }
# rk <n> <command>: runs the command on machine n with KUBECONFIG set. rks <n>: same, reading the commands from STDIN.
rk()  { nssh "$1" "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; $2"; }
rks() { nssh "$1" "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; bash -s"; }

node_iface() {  # interface of the default route of machine n (NODE_IFACE if set)
  [ -n "${NODE_IFACE:-}" ] && { echo "$NODE_IFACE"; return; }
  nssh "$1" "ip -4 route get 1.1.1.1" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1
}
node_ip() {     # address of machine n on that interface
  nssh "$1" "ip -4 route get 1.1.1.1" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1
}
node_mtu() { nssh "$1" "cat /sys/class/net/$(node_iface "$1")/mtu" 2>/dev/null; }

# push_repo <n>: copies lib/ and 02-kube-ovn-setup/ into ~/$REMOTE_DIR on machine n.
push_repo() {
  local i=$1 root; root="$(cd "$HERE/.." && pwd)"
  nssh "$i" "mkdir -p \"\$HOME/$REMOTE_DIR\"" || return 1
  scp -q -r -P "$SSH_PORT" "${SSH_COMMON[@]}" "$root/lib" "$root/02-kube-ovn-setup" \
      "$NODE_USER@$(node_host "$i"):$REMOTE_DIR/" || return 1
  nssh "$i" "chmod +x \"\$HOME/$REMOTE_DIR\"/02-kube-ovn-setup/*.sh"
}

# ns_close: closes the shared connections (they close by themselves after 10 minutes of silence).
ns_close() {
  local i n; n=$(node_n)
  for ((i=1;i<=n;i++)); do ssh -O exit -p "$SSH_PORT" "${SSH_COMMON[@]}" "$NODE_USER@$(node_host "$i")" >/dev/null 2>&1; done
  return 0
}

# kapply: applies the manifest read from STDIN on the cluster (kubectl runs on the server machine).
kapply() { rk "$SERVER" 'kubectl apply -f -'; }

# start_cust_servers: on the fabric machine, in the namespace "cust": HTTP on 8080 (log /tmp/ns-cust-http.log) and iperf3 on 5201.
start_cust_servers() {
  nroot "$FABRIC_NODE" CUST_HOST_IP="$CUST_HOST_IP" <<'EOS'
command -v iperf3 >/dev/null || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iperf3 >/dev/null 2>&1; }
pkill -f "http.server 8080" 2>/dev/null; pkill -x iperf3 2>/dev/null; sleep 1
: > /tmp/ns-cust-http.log
ip netns exec cust sh -c "nohup python3 -m http.server 8080 --bind $CUST_HOST_IP >/tmp/ns-cust-http.log 2>&1 &"
ip netns exec cust iperf3 -s -B "$CUST_HOST_IP" -p 5201 -D
sleep 1; ip netns exec cust ss -ltn | grep -cE ':(8080|5201) '
EOS
}

# fix_nic_prefix <n>: if the address of machine n on its NIC is a /32, adds the same address with prefix NIC_PREFIX_FIX and
# noprefixroute (Kube-OVN 1.13 skips /32 addresses). Not persistent across reboots. Does nothing when NIC_PREFIX_FIX is empty.
fix_nic_prefix() {
  local i=$1 ip ifc
  [ -n "${NIC_PREFIX_FIX:-}" ] || return 0
  ip=$(node_ip "$i"); ifc=$(node_iface "$i")
  [ -n "$ip" ] && [ -n "$ifc" ] || return 1
  nroot "$i" IP="$ip" IFC="$ifc" P="$NIC_PREFIX_FIX" <<'EOS'
ip -4 -o addr show dev "$IFC" | grep -q "inet $IP/32 " || exit 0
ip addr show dev "$IFC" | grep -q "inet $IP/$P " || ip addr add "$IP/$P" dev "$IFC" noprefixroute
EOS
}
# unfix_nic_prefix <n>: removes the address added by fix_nic_prefix.
unfix_nic_prefix() {
  local i=$1 ip ifc
  [ -n "${NIC_PREFIX_FIX:-}" ] || return 0
  ip=$(node_ip "$i"); ifc=$(node_iface "$i")
  [ -n "$ip" ] && [ -n "$ifc" ] && nssh "$i" "sudo -n ip addr del $ip/$NIC_PREFIX_FIX dev $ifc 2>/dev/null; true"
}

# Numbers: always "." as decimal separator (awk in a comma locale truncates "75.8" to 75)
export LC_ALL=C

# --- iperf3 (this version) aborts at the end with "unable to cancel thread: Permission denied" and prints no final summary,
# so the rate is computed from the 1-second interval lines: per pod, the mean of the intervals (omitted seconds and zero-length
# intervals excluded, duplicated lines counted once); the total is the sum over the pods. Prints "total_Mbps total_retransmissions".
parse_raw() {
  awk '
    /^=== bench-/ { p=$2; sub("bench-","",p); next }
    /omitted/ { next }
    /Mbits\/sec/ {
      kind = ($0 ~ /^\[SUM\]/) ? "S" : "F"
      if (!match($0, /[0-9]+\.[0-9]+-[0-9]+\.[0-9]+ +sec/)) next
      iv = substr($0, RSTART, RLENGTH); sub(/ +sec/, "", iv); split(iv, ab, "-"); if (ab[2]-ab[1] < 0.5) next
      if ((p SUBSEP kind SUBSEP iv) in seen) next
      seen[p SUBSEP kind SUBSEP iv] = 1
      if (!match($0, /[0-9.]+ Mbits\/sec +[0-9]+/)) next
      t = substr($0, RSTART, RLENGTH); split(t, w, " "); rate = w[1]; rt = w[3]
      n[p,kind]++; sr[p,kind] += rate; sx[p,kind] += rt; pods[p] = 1
    }
    END {
      for (p in pods) { k = ((p,"S") in n) ? "S" : "F"; if (n[p,k] > 0) { tot += sr[p,k]/n[p,k]; rr += sx[p,k] } }
      printf "%.1f %d\n", tot, rr
    }' "$1"
}

