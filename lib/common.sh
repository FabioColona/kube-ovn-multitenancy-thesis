#!/bin/bash
# lib/common.sh — functions shared by all scripts. It is not run directly: every script loads it with
#     . "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
#
# What it provides : messages, error handling, sudo handling, waiting with a progress bar, long commands with a
#                    spinner, configuration loading, K3s helpers, results table.
# Writes files     : none (a temporary file for the output of a long command, removed at exit).
# Requires         : bash >= 3.2 (macOS is fine).

# ---------------------------------------------------------------- messages
sec()  { echo; echo "=== $* ==="; }
info() { echo "  $*"; }
warn() { echo "WARNING: $*"; }
die()  { echo "ERROR: $*" >&2; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- options
# Scripts call parse_common_options "$@"; the remaining arguments are left in ARGS.
ASSUME_YES=0; ARGS=()
parse_common_options() {
  ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) ASSUME_YES=1 ;;
      *) ARGS+=("$1") ;;
    esac
    shift
  done
}

confirm() {   # confirm "question" — stops unless the user types "yes" (or --yes was given)
  [ "$ASSUME_YES" = 1 ] && return 0
  local a; read -r -p "$1 [yes/no] " a
  [ "$a" = yes ] || die "cancelled"
}

# ---------------------------------------------------------------- root / sudo
# SUDO is empty when already root. need_sudo asks for the password ONCE and keeps it
# valid until the script ends (long installs can last more than the sudo timeout).
SUDO=""
need_sudo() {
  if [ "$(id -u)" = 0 ]; then SUDO=""; return 0; fi
  have sudo || die "sudo not found: run this script as root"
  SUDO="sudo"
  sudo -v || die "sudo not available for user $(id -un)"
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 45; done ) &
}
as_root() { $SUDO "$@"; }

# ---------------------------------------------------------------- progress
# Progress is drawn on STDERR and only when it is an interactive terminal, so that results captured with $(...) or
# redirected to a file stay clean. Set NO_PROGRESS=1 to turn it off.
if [ -t 2 ] && [ "${NO_PROGRESS:-0}" != 1 ]; then PROGRESS=1; else PROGRESS=0; fi
clear_line() { [ "$PROGRESS" = 1 ] && printf '\r\033[K' >&2; return 0; }
fmt_time() {   # fmt_time <seconds> -> 45s | 2m05s
  if [ "$1" -ge 60 ]; then printf '%dm%02ds' $(($1/60)) $(($1%60)); else printf '%ds' "$1"; fi
}
progress_bar() {   # progress_bar <done> <total> -> [#####---------------]
  local d=$1 t=$2 w=20 f i bar=""
  [ "$t" -gt 0 ] || t=1
  f=$((d*w/t)); [ "$f" -gt "$w" ] && f=$w
  for ((i=0;i<w;i++)); do if [ "$i" -lt "$f" ]; then bar+="#"; else bar+="-"; fi; done
  printf '[%s]' "$bar"
}
tick() {   # tick <label> <i> <n>: "label  3/5" on the current line (cleared by clear_line)
  [ "$PROGRESS" = 1 ] && printf '\r\033[K  %s  %d/%d' "$1" "$2" "$3" >&2
  return 0
}

# ---------------------------------------------------------------- waiting
# waitf <attempts> <seconds between attempts> <command...>: returns 0 as soon as the command succeeds.
# On a terminal it shows a bar with the elapsed time out of the maximum, after the first 2 seconds. The text next to
# the bar is $WAIT_MSG (set it for one call: WAIT_MSG="the routes" waitf 30 2 ...).
waitf() {
  local n=$1 s=$2 i start=$SECONDS t total=$(($1*$2)); shift 2
  for ((i=0;i<n;i++)); do
    if "$@" >/dev/null 2>&1; then clear_line; return 0; fi
    t=$((SECONDS-start))
    if [ "$PROGRESS" = 1 ] && [ "$t" -ge 2 ]; then
      printf '\r\033[K  %s %s / %s  %s' "$(progress_bar "$t" "$total")" "$(fmt_time "$t")" "$(fmt_time "$total")" "${WAIT_MSG:-waiting}" >&2
    fi
    sleep "$s"
  done
  clear_line; return 1
}

# run_spin <label> <hint> <command...>: runs a long command with a spinner and the elapsed time.
# The output of the command goes to a temporary file, $RUN_LOG, which stays until the next run_spin or the end of the
# script (look at it with tail when the command fails). No percentage is shown: the time needed is not known; <hint> says
# how long it usually takes. Returns the exit code of the command (or 0 for an error accepted with SPIN_ACCEPT).
# Scripts that set their own EXIT trap replace this one, so the files live in their own folder and the ones older than a
# day are removed whenever a script starts.
RUN_LOG=""
RUN_LOG_DIR="${RUN_LOG_DIR:-${TMPDIR:-/tmp}/kube-ovn-thesis-run}"
mkdir -p "$RUN_LOG_DIR" 2>/dev/null && find "$RUN_LOG_DIR" -type f -name 'run.*' -mtime +0 -exec rm -f {} + 2>/dev/null
run_log_rm() { [ -n "$RUN_LOG" ] && rm -f "$RUN_LOG"; RUN_LOG=""; return 0; }
trap run_log_rm EXIT
run_spin() {
  local label=$1 hint=$2 pid rc start=$SECONDS i=0 frames='|/-\' t
  shift 2
  run_log_rm
  RUN_LOG="$(mktemp "$RUN_LOG_DIR/run.XXXXXX")"
  [ "$PROGRESS" = 1 ] || echo "  $label ..."
  "$@" >"$RUN_LOG" 2>&1 </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$PROGRESS" = 1 ]; then
      t=$((SECONDS-start))
      printf '\r\033[K  %s %s  %s%s' "${frames:i%4:1}" "$label" "$(fmt_time "$t")" "${hint:+  ($hint)}" >&2
      i=$((i+1))
    fi
    sleep 0.2
  done
  wait "$pid"; rc=$?
  clear_line
  # A known, harmless error can be accepted: SPIN_ACCEPT is a regex that must appear in the output, SPIN_NOTE says why.
  if [ "$rc" -ne 0 ] && [ -n "${SPIN_ACCEPT:-}" ] && grep -q -- "$SPIN_ACCEPT" "$RUN_LOG"; then
    echo "  $label: done in $(fmt_time $((SECONDS-start)))${SPIN_NOTE:+ ($SPIN_NOTE)}"; return 0
  fi
  if [ "$rc" -eq 0 ]; then echo "  $label: done in $(fmt_time $((SECONDS-start)))"
  else echo "  $label: FAILED (exit $rc) after $(fmt_time $((SECONDS-start)))"; fi
  return "$rc"
}

# ---------------------------------------------------------------- configuration
# load_config <dir>: reads <dir>/config.env, then <dir>/config.local.env if present (your own values).
# Priority: variables already set in the environment > config.local.env > config.env.
# So `REPETITIONS=1 ./20-paper-wall.sh` works without editing any file.
load_config() {
  local f n kv names="" saved=()
  for f in "$1/config.env" "$1/config.local.env"; do
    # every assignment, also the second and third one of a line (A=1; B=2); names found in comments do no harm
    [ -f "$f" ] && names+=" $(grep -oE '(^|[;[:space:]])[A-Z_][A-Z0-9_]*=' "$f" | tr -d '=;[:blank:]' | sort -u | tr '\n' ' ')"
  done
  for n in $names; do [ -n "${!n+x}" ] && saved+=("$n=${!n}"); done
  [ -f "$1/config.env" ] || die "cannot read $1/config.env"
  # shellcheck disable=SC1090,SC1091
  . "$1/config.env"
  # shellcheck disable=SC1090,SC1091
  [ -f "$1/config.local.env" ] && . "$1/config.local.env"
  for kv in "${saved[@]}"; do export "${kv%%=*}=${kv#*=}"; done
  return 0
}
require_vars() {   # require_vars VAR1 VAR2 …: stops naming the missing one
  local v
  for v in "$@"; do [ -n "${!v:-}" ] || die "variable $v is empty: set it in config.env or config.local.env"; done
}

# ---------------------------------------------------------------- preflight-style checks
NOK=0; NWARN=0; NFAIL=0
ok()  { NOK=$((NOK+1));     echo "  [ OK ] $*"; }
wrn() { NWARN=$((NWARN+1)); echo "  [WARN] $*"; }
bad() { NFAIL=$((NFAIL+1)); echo "  [FAIL] $*"; }
summary() {
  echo; echo "Summary: $NOK ok, $NWARN warnings, $NFAIL failures."
  [ "$NFAIL" -eq 0 ]
}

# ---------------------------------------------------------------- results table
RES_TEST=(); RES_EXP=(); RES_OBT=(); RES_STATUS=()
# record <test> <expected> <obtained> <status>   status: PASS|FAIL|INCONCLUSIVE|BLOCKED|NOT RUN
record() {
  case "$4" in PASS|FAIL|INCONCLUSIVE|BLOCKED|"NOT RUN") ;; *) die "internal error: invalid status '$4'";; esac
  RES_TEST+=("$1"); RES_EXP+=("$2"); RES_OBT+=("$3"); RES_STATUS+=("$4")
}
# expect <test> <expected> <obtained>: PASS if equal, FAIL otherwise
expect() {
  if [ "$2" = "$3" ]; then record "$1" "$2" "$3" PASS; else record "$1" "$2" "$3" FAIL; fi
}
# table: prints the results; returns 0 if there is no FAIL and no check that could not run (BLOCKED, NOT RUN).
# INCONCLUSIVE rows are reported but do not change the exit code.
table() {
  local i w1=4 w2=8 w3=8 n=${#RES_TEST[@]} fails=0
  for ((i=0;i<n;i++)); do
    [ ${#RES_TEST[i]} -gt $w1 ] && w1=${#RES_TEST[i]}
    [ ${#RES_EXP[i]}  -gt $w2 ] && w2=${#RES_EXP[i]}
    [ ${#RES_OBT[i]}  -gt $w3 ] && w3=${#RES_OBT[i]}
  done
  echo; printf "%-${w1}s  %-${w2}s  %-${w3}s  %s\n" TEST EXPECTED OBTAINED STATUS
  for ((i=0;i<n;i++)); do
    printf "%-${w1}s  %-${w2}s  %-${w3}s  %s\n" "${RES_TEST[i]}" "${RES_EXP[i]}" "${RES_OBT[i]}" "${RES_STATUS[i]}"
    [ "${RES_STATUS[i]}" = FAIL ] && fails=$((fails+1))
  done
  local i2 notrun=0 inc=0
  for ((i2=0;i2<n;i2++)); do
    case "${RES_STATUS[i2]}" in BLOCKED|"NOT RUN") notrun=$((notrun+1));; INCONCLUSIVE) inc=$((inc+1));; esac
  done
  echo; echo "$n checks, $fails FAIL.$([ "$notrun" -gt 0 ] && echo " $notrun not run (BLOCKED or NOT RUN).")$([ "$inc" -gt 0 ] && echo " $inc INCONCLUSIVE.")"
  [ "$fails" -eq 0 ] && [ "$notrun" -eq 0 ]
}

# ---------------------------------------------------------------- K3s helpers
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

k3s_installed() { [ -x /usr/local/bin/k3s ] || [ -f /etc/systemd/system/k3s.service ]; }

# install_k3s "<extra server arguments>": installs the pinned K3s version and waits for the API server.
_k3s_run_installer() {
  curl -sfL https://get.k3s.io | as_root env INSTALL_K3S_VERSION="$K3S_VERSION" \
    INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 $1" sh -
}
install_k3s() {
  require_vars K3S_VERSION
  have curl || die "curl is required"
  if ! run_spin "installing K3s $K3S_VERSION" "usually 1-2 minutes" _k3s_run_installer "$1"; then
    tail -15 "$RUN_LOG"; die "K3s installation failed"
  fi
  WAIT_MSG="waiting for the API server" waitf 90 2 kubectl get nodes || die "API server not reachable after 3 minutes"
}

_node_ready() { kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{exit c<1}'; }
wait_node_ready() {   # wait_node_ready [seconds]
  local secs="${1:-300}"
  WAIT_MSG="waiting for the node to be Ready" waitf $((secs/5)) 5 _node_ready
}

# uninstall_k3s: removes K3s and what CNIs leave on the node. Used by 90-reset.sh.
uninstall_k3s() {
  [ -x /usr/local/bin/k3s-uninstall.sh ] && as_root /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1
  as_root ip link delete vxlan.calico 2>/dev/null
  # Cilium and Flannel both use UDP 8472: a leftover cilium_vxlan makes the next Flannel fail ("address already in use").
  local l; for l in cilium_vxlan cilium_host cilium_net flannel.1 cni0; do as_root ip link delete "$l" 2>/dev/null; done
  # Calico (eBPF) leaves a cgroup2 mount in /run/calico/cgroup: files inside a cgroup cannot be removed, unmount it first.
  as_root umount /run/calico/cgroup 2>/dev/null
  as_root rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet /var/lib/calico /var/run/calico \
                 /etc/cni/net.d /usr/local/bin/cilium 2>/dev/null
  local t
  for t in iptables ip6tables; do
    have "${t}-save" && as_root "${t}-save" 2>/dev/null | grep -v -E 'cali|KUBE-|CNI-|CILIUM' | as_root "${t}-restore" 2>/dev/null
  done
  return 0
}

# count_rules <pattern>: number of iptables rules matching the pattern (0 if iptables is missing).
count_rules() {
  local t n=0 c ok=0 out
  for t in iptables-save iptables-legacy-save iptables-nft-save; do
    have "$t" || continue
    out=$(as_root "$t" 2>/dev/null) || continue
    ok=$((ok + 1)); c=$(printf '%s\n' "$out" | grep -c -E "$1"); n=$((n + c))
  done
  # no back-end could be read (for example sudo refused): print BLOCKED, so that a check "= 0" cannot pass by mistake
  [ "$ok" -gt 0 ] && echo "$n" || echo BLOCKED
}
