#!/usr/bin/env bash
# Main entry point for a new machine. RUN AS YOUR NORMAL USER (no sudo).
#
# This script VALIDATES the host and configures the deployment. It never
# installs anything itself: every host change (apt packages, kernel modules,
# sysctl, swap, K3s, helm) belongs to deploy/bootstrap-root.sh, which you run
# separately with sudo. When something is missing, this script prints the
# exact command to fix it and stops.
#
# What it DOES:
#   1. validates the host: packages, kernel modules, sysctl keys, swap off,
#      k3s running with the right node name, helm v4
#   2. validates the two data paths (see "Data paths" below)
#   3. clears a 0-byte .env stub, then walks through EVERY key in .env with a
#      prompt and a validator: it asks for a value, checks it before moving
#      on, and stores it in .env the moment it is accepted. .env holds only
#      site values — every credential lives in the pre-created Kubernetes
#      Secrets (deploy/secret-init.sh), encrypted at rest by K3s, and the
#      wizard never touches one.
#   4. runs ./deploy/setup.sh (which may use sudo for directory creation,
#      and reports loudly when it cannot)
#
# Data paths: the live data root (LIVE_DATA_PATH in .env) and the backup
# archive root (BACKUP_DATA_PATH) default to ~/.open-webui/live-data and
# ~/.open-webui/backup-data; the wizard prompts for both with the default
# shown, and a path can be typed to override. They must be two DIFFERENT
# paths — directories, mount points, or anything else; the scripts never
# partition, format or mount. setup.sh creates the subdirectories on demand
# with the right owners. Production recommendation (advisory, not enforced):
# put them on two different physical devices, because a data disk holding
# its only backup dies with it.
#
# Usage:
#   ./deploy/bootstrap-host.sh --node-name NAME   # validate + wizard + setup.sh
#   ./deploy/bootstrap-host.sh                     # same, node name defaults
#                                                  # to `hostname -s` after a prompt
#   ./deploy/bootstrap-host.sh --check             # report only; changes nothing
#   ./deploy/bootstrap-host.sh --no-setup          # validate + wizard, skip the
#                                                  # setup.sh handoff at the end
#   ./deploy/bootstrap-host.sh --configure         # re-prompt every key even if
#                                                  # .env already holds a valid value
#
# Safe to re-run: every step is idempotent and skips what is already done.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"


ENV_EXAMPLE="$REPO_ROOT/.env.example"

# The two data roots. These are the DEFAULTS used when LIVE_DATA_PATH and
# BACKUP_DATA_PATH are empty in .env; the wizard prompts for both with the
# default shown, and the deploy scripts resolve the same defaults when the
# keys are absent. The paths are injected into the charts at deploy time
# (values.yaml carries "" + required guards), so nothing here is baked into
# a tracked file.

APP_ROOT_DEFAULT="$HOME/.open-webui/live-data"
BACKUP_ROOT_DEFAULT="$HOME/.open-webui/backup-data"

NODE_NAME=""
MODE=bootstrap
FORCE_CONFIGURE=0
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  arg="${args[i]}"
  case "$arg" in
    -h|--help)
      awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "${BASH_SOURCE[0]}" >&2
      exit 0
      ;;
    --node-name)
      # The space form: consume the next argument as the value.
      if (( i + 1 >= ${#args[@]} )) || [[ "${args[i+1]}" == --* ]]; then
        echo "ERROR: --node-name requires a value." >&2
        exit 2
      fi
      if [[ -n "$NODE_NAME" ]]; then
        echo "ERROR: --node-name given twice: '$NODE_NAME' and '${args[i+1]}'." >&2
        exit 2
      fi
      NODE_NAME="${args[i+1]}"
      i=$((i + 2))
      continue
      ;;
    --node-name=*)
      if [[ -n "$NODE_NAME" ]]; then
        echo "ERROR: --node-name given twice (value: '${arg#--node-name=}')." >&2
        exit 2
      fi
      NODE_NAME="${arg#--node-name=}"
      ;;
    --configure)
      FORCE_CONFIGURE=1
      ;;
    --check|--no-setup)
      if [[ "$MODE" != bootstrap && "$MODE" != "${arg#--}" ]]; then
        echo "ERROR: two modes given: --$MODE and $arg." >&2
        exit 2
      fi
      MODE="${arg#--}"
      ;;
    *)
      if [[ "$arg" == --* ]]; then
        echo "ERROR: unknown argument '$arg'." >&2
        exit 2
      fi
      # Bare positional argument: the node name.
      if [[ -z "$NODE_NAME" ]]; then
        NODE_NAME="$arg"
      else
        echo "ERROR: two node names given: '$NODE_NAME' and '$arg'." >&2
        exit 2
      fi
      ;;
  esac
  i=$((i + 1))
done

CHECK_ONLY=0
[[ "$MODE" == check ]] && CHECK_ONLY=1

errors=()
warnings=0
ok()   { printf '  OK    %s\n' "$1"; }
note() { printf  '  --    %s\n' "$1"; }
ask()  { printf  '  TODO  %s\n' "$1"; }
bad()  { errors+=("$1"); printf '  FAIL  %s\n' "$1" >&2; }
warn() { warnings=$((warnings + 1)); printf '  WARN  %s\n' "$1"; }

section() {
  echo
  echo "══════════════════════════════════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════════════════════════════════"
}

ROOT_SCRIPT="sudo $SCRIPT_DIR/bootstrap-root.sh"
root_hint() {
  echo "          Fix with: $ROOT_SCRIPT --node-name ${NODE_NAME:-<name>}"
}

# ── 0. Node name ─────────────────────────────────────────────────────────────
section "Node name"
# Every local PV pins nodeAffinity to the K3s node name, which is NOT necessarily
# what `hostname` prints. If K3s is already installed, the cluster's answer is
# authoritative and overriding it here would mean recreating the PVs later.
if [[ -z "$NODE_NAME" ]]; then
  if systemctl is-active --quiet k3s 2>/dev/null && command -v kubectl >/dev/null 2>&1; then
    existing=$(kubectl get nodes -o name 2>/dev/null | sed 's|^node/||' | head -1 || true)
    if [[ -n "$existing" ]]; then
      NODE_NAME="$existing"
      note "K3s is already installed; using its node name '$NODE_NAME' (from the cluster)."
    fi
  fi
  if [[ -z "$NODE_NAME" ]]; then
    suggested=$(hostname -s)
    if (( CHECK_ONLY )); then
      ask "no --node-name given; would prompt or default to '$suggested'."
      NODE_NAME="$suggested"
    elif [[ -t 0 ]]; then
      read -r -p "  K3s node name [${suggested}]: " NODE_NAME || true
      NODE_NAME=${NODE_NAME:-$suggested}
    else
      NODE_NAME="$suggested"
      note "no terminal; defaulting node name to '$NODE_NAME'. Pass --node-name to choose."
    fi
  fi
fi
# Reject names the kubelet would refuse or that would break the PV template.
if [[ ! "$NODE_NAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
  bad "node name '$NODE_NAME' is not a valid lowercase RFC 1123 hostname; use lowercase letters, digits, '-' and '.'."
  echo "Stopped before any change." >&2
  exit 1
fi
ok "node name: $NODE_NAME"

# ── 1. Host installation (validated, never performed here) ──────────────────
section "Host installation (done by bootstrap-root.sh)"
# This script only checks. The root script owns every host change; if anything
# below fails, the fix is the single command printed with it.
host_missing=0
fail() { bad "$1"; host_missing=1; }

pkg_missing=0
for pkg in curl git python3 openssl; do
  dpkg -s "$pkg" >/dev/null 2>&1 || { fail "package '$pkg' is not installed."; pkg_missing=1; }
done
(( pkg_missing )) || ok "packages: curl, git, python3, openssl"

mod_missing=0
for mod in overlay br_netfilter; do
  # A module compiled into the kernel (CONFIG_OVERLAY_FS=y,
  # CONFIG_BRIDGE_NETFILTER=y) never appears in lsmod, yet it is present and
  # fully functional. lsmod alone therefore reports a false negative on those
  # kernels — /sys/module/<name> is the test that covers both cases. What K3s
  # needs is the feature, not a loadable module.
  lsmod | grep -q "^${mod} " || [[ -d "/sys/module/$mod" ]] \
    || { fail "kernel module '$mod' is not loaded."; mod_missing=1; }
done
(( mod_missing )) || ok "kernel modules: overlay, br_netfilter"

sysctl_missing=0
for key in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward; do
  [[ "$(sysctl -n "$key" 2>/dev/null)" == "1" ]] || { fail "sysctl $key is not 1."; sysctl_missing=1; }
done
(( sysctl_missing )) || ok "sysctl bridge/ip_forward keys are 1"

# The kubelet refuses to start with swap enabled (failSwapOn default).
if swapon --noheadings 2>/dev/null | grep -q .; then
  bad "swap is active. The kubelet will refuse to start; bootstrap-root.sh disables it and comments the fstab entry."
  host_missing=1
else
  ok "swap is off"
fi

if systemctl is-active --quiet k3s 2>/dev/null; then
  ok "k3s service is running"
  if command -v kubectl >/dev/null 2>&1 &&
     ! kubectl get nodes -l "kubernetes.io/hostname=$NODE_NAME" -o name 2>/dev/null | grep -q .; then
    warn "k3s is running but no node is labelled kubernetes.io/hostname=$NODE_NAME. The node registered under a different name; either pass --node-name matching 'kubectl get nodes', or recreate the cluster with this name — PV nodeAffinity is immutable."
  fi
else
  bad "k3s is not installed or not running."
  host_missing=1
fi

helm_ver=$(helm version --short 2>/dev/null | sed -E 's/^v?([0-9]+).*/\1/' || true)
if [[ -n "$helm_ver" ]] && (( helm_ver >= 4 )); then
  ok "helm $(helm version --short 2>/dev/null)"
elif [[ -n "$helm_ver" ]]; then
  bad "helm ${helm_ver}.x is installed but the deploy scripts pass --dry-run=client and --hide-secret, which need helm 4."
  host_missing=1
else
  bad "helm is not installed."
  host_missing=1
fi

if (( host_missing )); then
  echo
  echo "The host is not ready. Run the root installation script (it is idempotent"
  echo "and only does what is missing), then re-run this script:"
  echo "  $ROOT_SCRIPT --node-name $NODE_NAME"
fi

# ── 2. Data paths ────────────────────────────────────────────────────────────
section "Data paths"
# Read one key out of .env. Last match wins, matching the parser in both
# component deploy.sh scripts. Needed here, before the wizard, because the
# effective roots are the point of this section.
env_value() {
  [[ -f "$ENV_FILE" ]] || return 0
  grep "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Resolve data roots with ~ expansion, absolute path validation, and char whitelist.
resolve_data_root() { # <value> <default> <key-name>
  local v="${1:-}" def="$2" key="$3"
  [[ "$v" == CHANGE-ME* ]] && v=""
  v="${v:-$def}"
  [[ "$v" == "~" ]] && v="$HOME"
  [[ "$v" == "~/"* ]] && v="$HOME/${v#\~/}"
  [[ "$v" == /* ]] || { bad "$key must be an absolute path (or empty for the default); got '$v'."; return 1; }
  [[ "$v" =~ [[:space:]] ]] && { bad "$key must not contain spaces: '$v'."; return 1; }
  [[ "$v" =~ ^[A-Za-z0-9._/-]+$ ]] || { bad "$key may contain only letters, digits, '.', '_', '-' and '/': '$v'."; return 1; }
  printf '%s' "${v%/}"
}

# The effective roots: LIVE_DATA_PATH / BACKUP_DATA_PATH from .env when set,
# the defaults otherwise. The wizard below prompts for both with the current
# value as the suggestion, so the checks here run against the values the
# deploy will actually use.
# Two DIFFERENT user-provided paths: live data under $APPS_PATH, backups under
# $DATA_PATH. They may be plain directories, mount points, or anything else —
# this stack never partitions, formats or mounts, and setup.sh creates the
# subdirectories with the right owners. Only the difference is enforced:
# backups written into the same tree as the data they protect are not backups.
APPS_PATH=$(resolve_data_root "$(env_value LIVE_DATA_PATH)" "$APP_ROOT_DEFAULT" LIVE_DATA_PATH) || APPS_PATH=""
if [[ -z "$APPS_PATH" ]]; then
  # resolve_data_root already printed the reason, but errors+= ran in this
  # command substitution's subshell — record it where the exit code sees it.
  bad "LIVE_DATA_PATH is not a valid data root (see FAIL above)."
  APPS_PATH="$APP_ROOT_DEFAULT"
fi
DATA_PATH=$(resolve_data_root "$(env_value BACKUP_DATA_PATH)" "$BACKUP_ROOT_DEFAULT" BACKUP_DATA_PATH) || DATA_PATH=""
if [[ -z "$DATA_PATH" ]]; then
  bad "BACKUP_DATA_PATH is not a valid data root (see FAIL above)."
  DATA_PATH="$BACKUP_ROOT_DEFAULT"
fi
if [[ "$APPS_PATH" == "$DATA_PATH" ]]; then
  bad "LIVE_DATA_PATH and BACKUP_DATA_PATH are the same path ($APPS_PATH). Backups must go to a different location."
else
  for p in "$APPS_PATH" "$DATA_PATH"; do
    if [[ ! -e "$p" ]]; then
      note "$p does not exist yet — setup.sh will create it (with sudo when needed)."
    elif [[ ! -d "$p" ]]; then
      bad "$p exists but is not a directory."
    elif [[ -w "$p" ]]; then
      ok "$p exists and is writable"
    else
      # Root-owned is normal: setup.sh creates the per-component subdirectories
      # with the right owners via sudo.
      ok "$p exists (not writable by $(id -un); setup.sh will create subdirectories with sudo)"
    fi
  done
  # Production advisory, not a blocker: two paths on one physical device mean
  # one disk failure takes the data and its only backup together. The user
  # decides; the scripts just say it out loud.
  if [[ -d "$APPS_PATH" && -d "$DATA_PATH" ]]; then
    apps_dev=$(stat -c %d "$APPS_PATH" 2>/dev/null || true)
    data_dev=$(stat -c %d "$DATA_PATH" 2>/dev/null || true)
    if [[ -n "$apps_dev" && "$apps_dev" == "$data_dev" ]]; then
      warn "PRODUCTION RECOMMENDATION: $APPS_PATH and $DATA_PATH are on the same device (st_dev $apps_dev). A single disk failure loses the data AND its only backups. For production, put the backup path on a second physical device (or a remote target)."
    fi
  fi
fi

# ── 3. Capacity and scale ────────────────────────────────────────────────────
section "Capacity and scale"
# The three resources that decide which message-scale profile this machine can
# carry: cores, RAM and disk. Detected here and offered as the wizard's
# suggestions. The deploy scripts treat the stored values as minimums, so a
# MESSAGE_SCALE the machine cannot carry fails there with the exact shortfall
# rather than filling the disk months later.
detect_cores() { nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1; }
detect_mem_gb() {
  # MemAvailable, not MemTotal: whatever already runs on this host (an inference
  # server, another stack) is not spare capacity. Rounded down to whole GB.
  awk '/^MemAvailable:/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 1
}
detect_storage_gb() { # <path> — free space on the filesystem that holds it
  local p="$1"
  while [[ -n "$p" && ! -d "$p" ]]; do p=$(dirname "$p"); done
  df -Pk "${p:-/}" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1048576}' || echo 0
}
HOST_CORES=$(detect_cores)
HOST_MEM_GB=$(detect_mem_gb)
HOST_STORAGE_GB=$(detect_storage_gb "$APPS_PATH")
[[ "$HOST_CORES" =~ ^[0-9]+$ ]] && (( 10#$HOST_CORES > 0 )) || HOST_CORES=1
[[ "$HOST_MEM_GB" =~ ^[0-9]+$ ]] && (( 10#$HOST_MEM_GB > 0 )) || HOST_MEM_GB=1
[[ "$HOST_STORAGE_GB" =~ ^[0-9]+$ ]] && (( 10#$HOST_STORAGE_GB > 0 )) || HOST_STORAGE_GB=1
ok "detected capacity: $HOST_CORES CPU cores, $HOST_MEM_GB GB RAM available, $HOST_STORAGE_GB GB free on the live data root"
note "MESSAGE_SCALE decides the whole resource envelope (CPU and memory limits, uvicorn workers, Postgres cache and max_connections). The deploy scripts refuse a scale the values below cannot carry, and name the shortfall."

# ── 4. .env configuration wizard ─────────────────────────────────────────────
section ".env configuration (7 required site keys + 2 optional data paths + 4 capacity keys)"
# The wizard asks for every key, validates it before accepting, and stores it
# in .env immediately -- so a Ctrl-C mid-run leaves a file that is either
# complete for the keys already answered or still holds the template
# placeholder, never a half-written value.
#
# The prompt list below asks only for site values, in an order that puts the
# keys other answers depend on (node name, profile) first.

# Read one key out of .env. Last match wins, matching the parser in both
# component deploy.sh scripts. (Defined above, before the Data paths section,
# which needs it.)

# Write one key into .env, taking the value on stdin -- never as an argument:
# argv is world-readable through ps, and this file holds the database password
# and the session signing key. Duplicates are collapsed to the new value
# because the deploy scripts parse last-match-wins.
set_env_key() {
  python3 -c '
import sys, re
path, key = sys.argv[1], sys.argv[2]
value = sys.stdin.read()
if value.endswith("\n"):
    value = value[:-1]
lines = open(path).read().splitlines(keepends=True)
pat = re.compile("^%s=.*$" % re.escape(key))
kept = None
out = []
for line in lines:
    if pat.match(line):
        if kept is None:
            kept = "%s=%s\n" % (key, value)
            out.append(kept)
        continue
    out.append(line)
if kept is None:
    out.append("%s=%s\n" % (key, value))
open(path, "w").writelines(out)
' "$ENV_FILE" "$1"
}

# Seed the file before the first prompt so the comments explaining each key
# survive and set_env_key has something to rewrite.
if [[ ! -f "$ENV_FILE" ]]; then
  if (( CHECK_ONLY )); then
    ask "would seed $ENV_FILE from .env.example and prompt for every key."
  else
    umask 077
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "seeded $ENV_FILE from .env.example (mode 600)"
  fi
elif [[ "$(stat -c %a "$ENV_FILE")" != 600 ]]; then
  if (( CHECK_ONLY )); then
    ask "$ENV_FILE is mode $(stat -c %a "$ENV_FILE"); would chmod 600 (it holds site values)."
  elif chmod u+w "$ENV_FILE" 2>/dev/null && chmod 600 "$ENV_FILE" 2>/dev/null; then
    ok "chmod 600 $ENV_FILE"
  else
    bad "could not chmod 600 $ENV_FILE. Fix by hand: sudo chown $(id -un) '$ENV_FILE'"
  fi
else
  ok "$ENV_FILE exists (mode 600); the wizard will keep valid values unless --configure"
fi

# A 0-byte stub (mode 444 or not) would make every write below fail and holds
# nothing to lose; setup.sh's own cp would trip over it the same way.
if [[ -f "$ENV_FILE" ]] && (( $(stat -c %s "$ENV_FILE") == 0 )) && (( ! CHECK_ONLY )); then
  chmod u+w "$ENV_FILE" 2>/dev/null || true
  if rm -f "$ENV_FILE" 2>/dev/null; then
    umask 077
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "replaced empty $ENV_FILE with a fresh copy of .env.example"
  else
    # A read-only bind mount (sandboxes do this) cannot be replaced; every
    # later write would fail the same way, so stop with the reason instead of
    # dying on a python traceback inside set_env_key.
    bad "cannot replace the empty $ENV_FILE — it cannot be removed (read-only mount?). Delete it on the host and re-run."
    echo "Bootstrap stopped: .env is unwritable." >&2
    exit 1
  fi
fi

# Validators. Each takes the candidate value on argv, prints the reason it is
# wrong to stderr, and returns 1 -- the wizard then re-asks the same question
# instead of moving on. Rules mirror what the component deploy.sh scripts
# reject at deploy time, so a value accepted here cannot fail the deploy later.
v_required()      { [[ -n "$1" ]] || { echo "cannot be empty" >&2; return 1; }; }
v_node_name()     { [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || { echo "must be a lowercase hostname (letters, digits, '-', '.')" >&2; return 1; }; }
v_url() {
  [[ "$1" =~ ^https?://[^[:space:]/]+(/[^[:space:]]*)?$ ]] || { echo "must be a full URL starting with http:// or https://, no spaces, no trailing slash" >&2; return 1; }
  [[ "$1" != */ ]] || { echo "must not end with a trailing slash" >&2; return 1; }
}
v_webui_url() {
  v_url "$1" || return 1
  [[ "$1" == https://* ]] || echo "      WARN  http:// works fine for local use (no Google SSO). Google OAuth needs a public https:// URL." >&2
}
v_infer_url() {
  v_url "$1" || return 1
  [[ "$1" == */v1 ]] || echo "      WARN  endpoint does not end in /v1; OpenAI-compatible servers usually expose /v1 (e.g. http://host:8080/v1)." >&2
}
v_port()          { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )) || { echo "must be a number between 1 and 65535" >&2; return 1; }; }
# Capacity keys. The enum and the integer ranges are the same ones the deploy
# scripts accept, so a value the wizard takes can never fail the deploy gate on
# shape alone (only on capacity, which is a different message).
v_scale()         { [[ "$1" =~ ^(small|medium|large)$ ]] || { echo "must be small (100K messages), medium (1M) or large (10M)" >&2; return 1; }; }
v_cores()         { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 1024 )) || { echo "must be a whole number of CPU cores, 1-1024" >&2; return 1; }; }
v_gb()            { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 1048576 )) || { echo "must be a whole number of GB, at least 1" >&2; return 1; }; }
v_path() {
  # Empty is allowed (the optional flag makes it a real choice) and means the
  # default. A non-empty answer must be an absolute path, or ~ / ~/... which
  # the deploy scripts expand identically.
  [[ -z "$1" ]] && return 0
  [[ "$1" == /* || "$1" == "~" || "$1" == "~/"* ]] || { echo "must be an absolute path (start with / or ~/)" >&2; return 1; }
  [[ "$1" =~ [[:space:]] ]] && { echo "must not contain spaces" >&2; return 1; }
  [[ "$1" =~ ^[A-Za-z0-9._~/-]+$ ]] || { echo "may contain only letters, digits, '.', '_', '-', '/' and a leading ~" >&2; return 1; }
  return 0
}
v_ident()         { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "must be letters, digits and underscores, starting with a letter or underscore" >&2; return 1; }; }
# Echo validator output (an error reason, or a WARN that did not block) to
# stderr, one line at a time.
show_err() {
  [[ -n "$1" ]] || return 0
  while IFS= read -r line; do echo "  $line" >&2; done <<< "$1"
}

# Ask one key until the answer validates, then store it. An already-valid value
# is kept silently unless --configure forces a re-ask. Every key the wizard asks
# for is a site value — no credential reaches this function, so there is no
# hidden-input or generate-here path: ./deploy/secret-init.sh owns all of that.
ask_key() {
  local key="$1" prompt="$2" validator="$3" suggest="$4"
  local cur; cur=$(env_value "$key")
  if [[ -n "$cur" && "$cur" != CHANGE-ME* ]] && (( ! FORCE_CONFIGURE )); then
    note "$key already set; keeping it (pass --configure to re-ask)"
    return 0
  fi
  while true; do
    local val
    read -r -p "  $key: $prompt [$suggest]: " val || true
    if [[ -z "$val" ]]; then
      if [[ -n "$cur" && "$cur" != CHANGE-ME* ]]; then val="$cur"; else val="$suggest"; fi
    fi
    if [[ -z "$val" ]]; then
      echo "      It cannot be left empty: the deploy scripts reject a blank value." >&2
      continue
    fi
    # The validator prints its reason to stderr and returns 1 -> re-ask the
    # same question. It may also print WARN lines while accepting the value
    # (http:// WEBUI_URL, endpoint without /v1); those are surfaced but do
    # not block.
    local err
    if ! err=$("$validator" "$val" 2>&1); then
      show_err "$err"
      continue
    fi
    show_err "$err"
    printf '%s' "$val" | set_env_key "$key"
    ok "$key stored: $val"
    return 0
  done
}

if (( CHECK_ONLY )); then
  note "--check: the wizard does not run; it would prompt for the node name, the message-scale profile (small/medium/large), the site values (WEBUI_URL, inference endpoint, POSTGRES_HOST/PORT/DB/USER), the two data paths (Enter accepts the ~/.open-webui defaults), and the three capacity keys (CPU/RAM/disk budget, pre-filled from this host), each with validation. Credentials are not asked here: ./deploy/secret-init.sh owns them."
elif [[ ! -t 0 ]]; then
  warn "no terminal available for prompts. Fill $ENV_FILE by hand (see .env.example comments) before deploying."
else
  echo
  #            key                    prompt                                          validator       suggestion
  ask_key K3S_NODE_NAME        "K3s node name (the kubernetes.io/hostname label)"      v_node_name "${NODE_NAME:-$(hostname -s)}"
  ask_key MESSAGE_SCALE        "size for stored chat messages: small=100K, medium=1M, large=10M" v_scale small
  ask_key WEBUI_URL            "URL of the app (no TLS: http://<node-ip>:30000)"       v_webui_url ""
  ask_key OPENAI_API_BASE_URL  "OpenAI-compatible inference endpoint"                  v_infer_url ""
  ask_key LIVE_DATA_PATH       "live data root (Enter = the ~/.open-webui default)"    v_path "$APPS_PATH"
  ask_key BACKUP_DATA_PATH     "backup archive root (must differ from the live root)"  v_path "$DATA_PATH"
  ask_key DEPLOY_CPU_CORES     "CPU cores this deployment may use"                     v_cores "$HOST_CORES"
  ask_key DEPLOY_MEMORY_GB     "GB of RAM this deployment may use"                     v_gb "$HOST_MEM_GB"
  ask_key DEPLOY_STORAGE_GB    "GB of disk for the database, its backups and uploads"  v_gb "$HOST_STORAGE_GB"
  ask_key POSTGRES_HOST        "postgres host inside the cluster"                      v_required "postgres.default.svc.cluster.local"
  ask_key POSTGRES_PORT        "postgres port"                                         v_port "5432"
  ask_key POSTGRES_DB          "database name"                                         v_ident "openwebui"
  ask_key POSTGRES_USER        "database role"                                         v_ident "openwebui"
fi

# Final gate: every site value the deploy scripts demand must be present and
# not a placeholder, or the wizard aborted midway (Ctrl-C) -- say so before the
# handoff instead of letting setup.sh rediscover it.
if [[ -f "$ENV_FILE" ]] && (( ! CHECK_ONLY )); then
  still_missing=()
  for key in K3S_NODE_NAME WEBUI_URL OPENAI_API_BASE_URL POSTGRES_HOST POSTGRES_PORT \
             POSTGRES_DB POSTGRES_USER; do
    val=$(env_value "$key")
    [[ -n "$val" && "$val" != CHANGE-ME* ]] || still_missing+=("$key")
  done
  # The two data paths are optional (empty = the ~/.open-webui default), but a
  # half-written or placeholder value here is a mistake, and the same-path
  # rule is the one the deploy scripts enforce too.
  lp_raw=$(env_value LIVE_DATA_PATH); bp_raw=$(env_value BACKUP_DATA_PATH)
  [[ "$lp_raw" != CHANGE-ME* ]] || still_missing+=("LIVE_DATA_PATH (placeholder)")
  [[ "$bp_raw" != CHANGE-ME* ]] || still_missing+=("BACKUP_DATA_PATH (placeholder)")
  lp=$(resolve_data_root "$lp_raw" "$APP_ROOT_DEFAULT" LIVE_DATA_PATH 2>/dev/null) || lp=""
  bp=$(resolve_data_root "$bp_raw" "$BACKUP_ROOT_DEFAULT" BACKUP_DATA_PATH 2>/dev/null) || bp=""
  # Empty output means resolve_data_root rejected the value; its FAIL went to
  # stderr in a subshell, so name the failure where the gate can act on it.
  [[ -n "$lp" ]] || still_missing+=("LIVE_DATA_PATH is not a valid data root: '$lp_raw'")
  [[ -n "$bp" ]] || still_missing+=("BACKUP_DATA_PATH is not a valid data root: '$bp_raw'")
  if [[ -n "$lp" && "$lp" == "$bp" ]]; then
    still_missing+=("LIVE_DATA_PATH and BACKUP_DATA_PATH are the same path")
  fi
  # Capacity and scale. These four keys have defaults (small profile, its own
  # minimums), so an absent value is fine; a malformed one is not, and the deploy
  # scripts would reject it after this wizard had already declared .env complete.
  scale=$(env_value MESSAGE_SCALE)
  [[ -z "$scale" || "$scale" =~ ^(small|medium|large)$ ]] \
    || still_missing+=("MESSAGE_SCALE must be small, medium or large (got '$scale')")
  for key in DEPLOY_CPU_CORES DEPLOY_MEMORY_GB DEPLOY_STORAGE_GB; do
    val=$(env_value "$key")
    [[ -z "$val" || "$val" =~ ^[0-9]+$ ]] \
      || still_missing+=("$key must be a whole number (got '$val')")
  done
  if (( ${#still_missing[@]} )); then
    bad ".env is still incomplete: ${still_missing[*]}. Re-run the wizard or edit $ENV_FILE by hand."
  else
    ok ".env complete: 7 required site keys set, MESSAGE_SCALE=${scale:-small} (mode $(stat -c %a "$ENV_FILE"))"
  fi
fi

# ── 5. Report and hand off ───────────────────────────────────────────────────
echo
if (( warnings )); then
  echo "$warnings warning(s) recorded above. They do not block, but read them."
fi
if (( ${#errors[@]} )); then
  echo
  echo "Bootstrap stopped: ${#errors[@]} blocking problem(s):" >&2
  for e in "${errors[@]}"; do echo "  - $e" >&2; done
  if (( host_missing )); then
    echo
    echo "One command fixes the host-side items:" >&2
    echo "  $ROOT_SCRIPT --node-name $NODE_NAME" >&2
  fi
  exit 1
fi

if (( CHECK_ONLY )); then
  echo
  echo "OK: --check found no blocking problems. Nothing was changed."
  exit 0
fi

if [[ "$MODE" == no-setup ]]; then
  echo
  echo "OK: host and .env are ready. Run the deploy yourself when ready:"
  echo "    ./deploy/setup.sh"
  exit 0
fi

# The credentials are not in .env and the wizard never asks for them: they live
# in pre-created Kubernetes Secrets. The deploy below refuses to start pods
# without them, so stop here with the one command instead of a mid-setup fail.
# A fresh bootstrap always lands here once (nothing created the Secrets yet);
# the second run skips every answered question and goes straight through.
if command -v kubectl >/dev/null 2>&1 && kubectl get -n default svc >/dev/null 2>&1; then
  missing_secrets=()
  for s in ai-open-webui-secrets postgres; do
    kubectl get secret "$s" -n default >/dev/null 2>&1 || missing_secrets+=("$s")
  done
  if (( ${#missing_secrets[@]} )); then
    echo
    echo "OK: host and .env are ready. One step is left before the deploy:"
    echo
    echo "    ./deploy/secret-init.sh"
    echo
    echo "It prompts once for every credential (database password, session key,"
    echo "optional Google SSO and Brave key), stores them encrypted in the K3s"
    echo "datastore, and writes nothing to disk but a fingerprint manifest."
    echo "Then re-run: ./deploy/bootstrap-host.sh — the questions above are kept."
    exit 0
  fi
fi

echo
echo "Handing off to ./deploy/setup.sh — the wizard above has filled .env, so"
echo "setup.sh will re-verify prerequisites, apply the cluster primitives and deploy."
exec "$SCRIPT_DIR/setup.sh"
