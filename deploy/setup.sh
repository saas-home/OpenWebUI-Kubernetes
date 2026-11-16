#!/usr/bin/env bash
# First-time setup: a booted node with K3s installed, to a running stack.
#
# Run this once on a new machine. It checks every prerequisite the stack needs,
# creates the cluster primitives the charts deliberately do not own, prepares
# .env, probes the things that are easy to get wrong and quiet about, and then
# hands off to deploy/deploy.sh. Re-running it on an already-working cluster is
# safe: every action is idempotent and nothing here deletes anything.
#
# What it will NOT do: install packages, format disks, install K3s, or change the
# ownership of a directory that already exists. Those are host decisions with
# blast radius beyond this repo, so it reports what it found and gives you the
# command instead of running it. See "Prerequisites" in README.md.
#
# Usage:
#   ./deploy/setup.sh              # check, fix, prepare .env, deploy
#   ./deploy/setup.sh --check      # report only; changes nothing anywhere
#   ./deploy/setup.sh --no-deploy  # prepare everything, skip the helm deploy
#
# --check and --no-deploy are mutually exclusive with each other and with
# anything unrecognised: the default path deploys, so a mistyped flag must not
# silently become a live change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
ENV_EXAMPLE="$REPO_ROOT/.env.example"
MANIFESTS="$SCRIPT_DIR/cluster/manifests"
NAMESPACE=default

# The node every local PV pins itself to with nodeAffinity. The charts take the
# same value from K3S_NODE_NAME in .env; this script reads it from there too and
# falls back to what the cluster reports, so a fresh clone needs no editing. It is
# the kubernetes.io/hostname label -- the K3s node name -- which is not
# necessarily what `hostname` prints on the box.
NODE_HOSTNAME=""
node_name_source=""

# path | uid | gid | mode | who must be able to write it | why
#
# The uids come from what actually runs: the postgres server and its backup job
# run as the image's postgres account (uid 70 — see podSecurityContext in
# deploy/postgresql/values.yaml), the SearXNG init container runs as uid 977 and
# must be able to rewrite settings.yml, and the open-webui app plus its uploads
# backup job run as the user invoking this script — deploy.sh injects that same
# uid/gid into the app pod's podSecurityContext and the CronJob, so files written
# on the host keep the tree owned by the operator, never root. Getting one of
# these wrong produces a pod that either CrashLoops on a directory it cannot
# write or, for SearXNG, starts, passes readiness and serves the default config
# with no engines configured.
#
# The list is built by build_host_paths() after the data roots are resolved from
# .env — the roots are site values (LIVE_DATA_PATH / BACKUP_DATA_PATH, default
# ~/.open-webui/live-data and ~/.open-webui/backup-data), and the same roots
# feed both component deploy.sh scripts and the PV template, so the directory
# layout lives in exactly one derivation in each script and the audit below
# cross-checks them.
HOST_PATHS=()

# Resolve the two data roots identically to deploy/postgresql/deploy.sh and
# deploy/open-webui/deploy.sh: empty or placeholder = the default under $HOME,
# a leading ~ is expanded, the result is absolute and has no trailing slash.
resolve_data_root() { # <value> <default> <key-name>
  local v="${1:-}" def="$2" key="$3"
  [[ "$v" == CHANGE-ME* ]] && v=""
  v="${v:-$def}"
  [[ "$v" == "~" ]] && v="$HOME"
  [[ "$v" == "~/"* ]] && v="$HOME/${v#\~/}"
  [[ "$v" == /* ]] || { bad "$key must be an absolute path (or empty for the default); got '$v'."; return 1; }
  [[ "$v" =~ [[:space:]] ]] && { bad "$key must not contain spaces: '$v'."; return 1; }
  # Same character class the component deploy scripts enforce: these roots are
  # rendered into CronJob manifests and PV specs, so shell metacharacters and
  # quotes are rejected at the first boundary that sees them.
  [[ "$v" =~ ^[A-Za-z0-9._/-]+$ ]] || { bad "$key may contain only letters, digits, '.', '_', '-' and '/': '$v'."; return 1; }
  printf '%s' "${v%/}"
}

LIVE_ROOT=""
BACKUP_ROOT=""
resolve_data_roots() {
  LIVE_ROOT=$(resolve_data_root "$(env_value LIVE_DATA_PATH)" "$HOME/.open-webui/live-data" LIVE_DATA_PATH) || return 1
  BACKUP_ROOT=$(resolve_data_root "$(env_value BACKUP_DATA_PATH)" "$HOME/.open-webui/backup-data" BACKUP_DATA_PATH) || return 1
  if [[ "$LIVE_ROOT" == "$BACKUP_ROOT" ]]; then
    bad "LIVE_DATA_PATH and BACKUP_DATA_PATH are the same path ($LIVE_ROOT). Backups must not live in the tree they protect."
    return 1
  fi
  export LIVE_DATA_PATH="$LIVE_ROOT" BACKUP_DATA_PATH="$BACKUP_ROOT"
}

build_host_paths() {
  HOST_PATHS=(
    "$LIVE_ROOT/postgresql|70|70|0755|uid 70|Postgres PGDATA parent; the pod runs as the image postgres account"
    "$LIVE_ROOT/postgresql-backups|70|70|0755|uid 70|the non-root backup job writes pg_dump archives here"
    "$LIVE_ROOT/searxng|977|977|0755|uid 977|the searxng init container writes settings.yml"
    "$LIVE_ROOT/open-webui|$(id -u)|$(id -g)|0755|the deploying user|uploads and vector_db; the app pod runs as this user, so its files keep the tree user-owned"
    "$BACKUP_ROOT/postgresql|70|70|0755|uid 70|off-root database dumps, written by the non-root backup job"
    "$BACKUP_ROOT/open-webui|$(id -u)|$(id -g)|0755|the deploying user|off-root volume archives, written by the uploads backup job, which runs as this user"
  )
}

# Keys .env must carry, with the value that means "still a template". They name
# this installation -- node, public host, inference endpoint, Postgres
# coordinates. No credential is a .env key: the database password, the session
# key, the Google pair and the Brave key live in the pre-created Kubernetes
# Secrets (deploy/secret-init.sh) and are checked against the cluster in
# phase 5.
REQUIRED_KEYS=(
  K3S_NODE_NAME WEBUI_URL OPENAI_API_BASE_URL
  POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER
)

errors=()
warnings=()
ok()   { printf '  OK    %s\n' "$1"; }
note() { printf  '  --    %s\n' "$1"; }
ask()  { printf  '  TODO  %s\n' "$1"; }
bad()  { errors+=("$1"); printf '  FAIL  %s\n' "$1" >&2; }
warn() { warnings+=("$1"); printf '  WARN  %s\n' "$1"; }

section() {
  echo
  echo "══════════════════════════════════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════════════════════════════════"
}

# Write one key into .env, taking the value on stdin. Not as an argument: argv is
# world-readable through ps, and this file holds the database password and the
# session signing key.
#
# The program must be passed with -c, not as `python3 -`: `python3 -` reads the
# program itself from stdin, which then collides with the piped value. With a
# heredoc supplying the code, the value is never read, set_env_key writes an empty
# string, and the generator upstream dies on a broken pipe.
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
        # Drop every later duplicate rather than leaving it behind. The deploy scripts
        # parse .env last-match-wins, so a second copy of the key that survives here
        # silently outranks the value just written: setup.sh generated a password into
        # line 1 and a stale duplicate further down is what actually got deployed.
        continue
    out.append(line)
if kept is None:
    out.append("%s=%s\n" % (key, value))
open(path, "w").writelines(out)
' "$ENV_FILE" "$1"
}

usage() {
  cat >&2 <<'MSG'
Usage: ./deploy/setup.sh [--check | --no-deploy]

  (no flag)   check prerequisites, create cluster primitives, prepare .env,
              probe inference and the public URL, then run deploy/deploy.sh
  --check     report every finding and change nothing at all
  --no-deploy do everything except the helm deploy
MSG
}

MODE=setup
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --check|--no-deploy)
      if [[ "$MODE" != setup && "$MODE" != "${arg#--}" ]]; then
        echo "ERROR: two modes given: --$MODE and $arg." >&2
        usage
        exit 2
      fi
      MODE="${arg#--}"
      ;;
    *)
      echo "ERROR: unknown argument '$arg'." >&2
      usage
      exit 2
      ;;
  esac
done

CHECK_ONLY=0
[[ "$MODE" == check ]] && CHECK_ONLY=1

# This script creates the host tree the stack's data lives in, and it must run
# as the user who will own that tree. Running it as root is exactly how a data
# tree ends up root-owned: the roots and every sudo-stamped leaf come out owned
# by root, and a root-owned ~/.open-webui is what the operator then has to dig
# out of with sudo later. Root work (packages, kernel, K3s, helm) belongs to
# deploy/bootstrap-root.sh, the only script in this repo you run with sudo.
# Checked after argument parsing so `sudo ./deploy/setup.sh --help` still prints
# the usage instead of refusing: --check is refused too, because it derives the
# expected owners from `id -u` and would report a root-owned tree as correct.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "ERROR: setup.sh must run as your normal user, not root." >&2
  echo "Run it as the user who deploys and owns the data tree; host-level work" >&2
  echo "belongs to sudo deploy/bootstrap-root.sh." >&2
  exit 1
fi

# Can we escalate without a password? Needed only to create missing host paths
# with the right owner; everything else runs as the invoking user.
have_sudo=0
if sudo -n true 2>/dev/null; then have_sudo=1; fi

# Read one key out of .env. Defined here because the cluster and host-path checks
# below need the site values before the Credentials section runs.
#
# Last match wins, matching the parser in both component deploy.sh scripts. `grep -m1`
# read the FIRST definition, so with a duplicated key this script validated and probed
# one value while the deploy shipped the other: it reported a reachable inference
# endpoint and a resolving WEBUI_URL for a line nothing was going to deploy.
env_value() {
  [[ -f "$ENV_FILE" ]] || return 0
  grep "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Decide which node the local PVs must name, before anything checks them. The
# value lives in .env so the charts and this script agree; on a fresh clone with
# no .env yet, a single-node cluster is unambiguous and the answer is right there.
resolve_node_name() {
  local from_env nodes
  from_env=$(env_value K3S_NODE_NAME)
  if [[ -n "$from_env" && "$from_env" != CHANGE-ME* ]]; then
    NODE_HOSTNAME="$from_env"
    node_name_source=".env"
    return 0
  fi
  nodes=$(kubectl get nodes -o name 2>/dev/null | sed 's|^node/||' || true)
  case "$(printf '%s\n' "$nodes" | grep -c . )" in
    1)
      NODE_HOSTNAME="$nodes"
      node_name_source="the cluster's only node"
      ;;
    0)
      ;;
    *)
      bad "the cluster reports several nodes: ${nodes//$'\n'/ }. This stack is single-node, and K3S_NODE_NAME in .env has to say which one the local PVs pin to."
      ;;
  esac
}

# ── 1. Tooling ────────────────────────────────────────────────────────────────
section "Tooling"
for tool in kubectl helm python3 curl git; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool $(case $tool in
         python3) python3 --version 2>&1 | awk '{print $2}' ;;
         helm) helm version --short 2>/dev/null | cut -d+ -f1 ;;
         kubectl) kubectl version --client=true -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || echo '?' ;;
         *) "$tool" --version 2>/dev/null | head -1 | awk '{print $NF}' ;;
       esac)"
  else
    bad "$tool is not installed but is required. See Prerequisites in README.md."
  fi
done

# The deploy scripts pass --dry-run=client and --hide-secret, which helm 3 does
# not have. A silent fallback would print credentials in a dry run.
if command -v helm >/dev/null 2>&1; then
  helm_major=$(helm version --short 2>/dev/null | sed -E 's/^v?v?([0-9]+).*/\1/' || true)
  if [[ -z "$helm_major" ]]; then
    warn "could not parse the helm version; the deploy scripts need helm 4."
  elif (( helm_major < 4 )); then
    warn "helm ${helm_major}.x found; the deploy scripts pass --dry-run=client and --hide-secret, which need helm 4."
  fi
fi

# ── 2. Cluster ────────────────────────────────────────────────────────────────
section "Cluster"
if ! kubectl get --raw /readyz --request-timeout=10s >/dev/null 2>&1; then
  bad "cannot reach the cluster. Is K3s running? Check with: systemctl status k3s"
else
  ok "API server reachable"
  if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    bad "namespace $NAMESPACE does not exist."
  fi

  resolve_node_name
  if [[ -z "$NODE_HOSTNAME" ]]; then
    bad "cannot tell which node the local PVs should pin to: K3S_NODE_NAME is unset in .env and the cluster reports no ready node. Set it to the output of \`kubectl get nodes\`."
  else
    # Every local PV in this repo carries nodeAffinity on this hostname. If the
    # node registered under another name the PVCs bind to nothing and the pods sit
    # in Pending with events that do not mention the mismatch.
    if [[ -n "$(kubectl get nodes -l "kubernetes.io/hostname=$NODE_HOSTNAME" -o name 2>/dev/null)" ]]; then
      ok "node labelled kubernetes.io/hostname=$NODE_HOSTNAME is present (from $node_name_source)"
    else
      bad "no node is labelled kubernetes.io/hostname=$NODE_HOSTNAME, taken from $node_name_source. Every local PV pins itself to that name, so nothing will schedule. On a fresh node, install K3s with:
          curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server --disable traefik --node-name <name>' sh -
        and put the same <name> in K3S_NODE_NAME."
    fi

    # A node registered under a name the operator did not expect is the usual cause
    # of the failure above, so surface the difference even when the check passed.
    shell_host=$(hostname)
    if [[ "$shell_host" != "$NODE_HOSTNAME" ]]; then
      note "the OS hostname is '$shell_host' while the K3s node name is '$NODE_HOSTNAME'. That is expected; it is the node name the PVs match on."
    fi
  fi
fi

# ── 3. Host paths ─────────────────────────────────────────────────────────────
section "Host paths"
# The two roots are the earliest site values this script needs: HOST_PATHS,
# the PV template, and both deploy scripts all read them. This script only
# READS them: empty means the documented ~/.open-webui defaults, and choosing
# something else is the job of the single .env wizard in
# deploy/bootstrap-host.sh (the prompt copy that lived here was a second,
# weaker clone of that wizard and had started drifting from it). The PV path
# is immutable once bound, so pick the roots in the wizard before directories
# exist, not by editing .env under a running stack.
if resolve_data_roots; then
  # Label each root by whether .env actually set it. Comparing the raw value to the
  # resolved path mislabelled a hand-written `~/...` or a trailing slash as "defaults"
  # because resolve_data_root expands and strips those before the comparison.
  live_src="default"; [[ -n "$(env_value LIVE_DATA_PATH)" && "$(env_value LIVE_DATA_PATH)" != CHANGE-ME* ]] && live_src=".env"
  backup_src="default"; [[ -n "$(env_value BACKUP_DATA_PATH)" && "$(env_value BACKUP_DATA_PATH)" != CHANGE-ME* ]] && backup_src=".env"
  ok "data roots: $LIVE_ROOT (live, $live_src) and $BACKUP_ROOT (backups, $backup_src)"
  build_host_paths

  # Create the roots themselves, owned by the invoking user, before the
  # per-leaf loop: a leaf that loop creates with sudo (the uid 70 and 977 dirs)
  # would drag any missing parent along as root, and a root-owned tree is
  # exactly the state this script must never recreate.
  for root in "$LIVE_ROOT" "$BACKUP_ROOT"; do
    if [[ -d "$root" ]]; then
      # Guarded like the per-leaf stat below: under `set -e` an unguarded failure
      # here would kill the script with no message at all.
      root_uid=$(stat -c '%u' "$root" 2>/dev/null) || { bad "could not stat $root; re-run --check if this repeats."; continue; }
      if [[ "$root_uid" == "$(id -u)" ]]; then
        ok "data root $root is owned by $(id -un)"
      elif [[ "$root_uid" == "0" ]]; then
        bad "$root is root-owned. Pick one:
           keep the data:  sudo chown $(id -u):$(id -g) -R '$root'
                           (the per-leaf checks below then ask you to restore the uid 70
                            and uid 977 owners on postgresql/, postgresql-backups/ and searxng/)
           start over:     sudo rm -rf '$root'    (deletes everything under it)"
      else
        bad "$root is owned by uid $root_uid, not $(id -un). Fix with: sudo chown $(id -u):$(id -g) '$root'"
      fi
    elif (( CHECK_ONLY )); then
      ask "$root does not exist. Would create it owned by $(id -un)."
    elif mkdir -p -m 0755 "$root" 2>/dev/null; then
      ok "created $root (owned by $(id -un), mode 0755)"
    else
      bad "cannot create $root as $(id -un). Run: sudo mkdir -p '$root' && sudo chown $(id -u):$(id -g) '$root'"
    fi
  done
fi
for entry in "${HOST_PATHS[@]}"; do
  IFS='|' read -r path uid gid mode who why <<<"$entry"
  if [[ ! -d "$path" ]]; then
    if (( CHECK_ONLY )); then
      ask "$path does not exist (needed by $who: $why). Would create it as $uid:$gid mode $mode."
      continue
    fi
    if (( have_sudo )); then
      if sudo install -d -o "$uid" -g "$gid" -m "$mode" "$path"; then
        ok "created $path ($uid:$gid $mode)"
      else
        bad "could not create $path even with sudo."
      fi
    elif install -d "$path" 2>/dev/null; then
      # The kubelet's fsGroup rescues group ownership for Deployment hostPath
      # mounts at pod start, but the backup CronJob's hostPath mounts are not
      # rescued the same way (observed twice on this host): they stay exactly
      # as created, and a uid-70 job then cannot write them. With no sudo,
      # world-writable is the operator-approved fallback; the designed
      # ownership is still recommended.
      if (( uid != $(id -u) )) && [[ "$uid" != 0 ]]; then
        chmod o+w "$path" 2>/dev/null || true
        warn "$path was created as $(id -un) with mode o+w (no sudo available): the container user ($uid) can write it. Designed ownership:
          sudo chown $uid:$gid '$path' && sudo chmod $mode '$path'"
      else
        warn "$path was created as $(id -un) because passwordless sudo is unavailable. Fix ownership before deploying:
          sudo chown $uid:$gid '$path' && sudo chmod $mode '$path'"
      fi
    else
      bad "$path does not exist and cannot be created by $(id -un). Run: sudo install -d -o $uid -g $gid -m $mode $path"
    fi
    continue
  fi

  # Report the real ownership and evaluate write access for the uid that needs
  # it, rather than insisting on an owner: ownership matters exactly where a
  # non-root pod depends on it (uid 70, uid 977, the deploying user), and a
  # directory that is merely group- or world-writable is accepted as writable.
  # Only the mode is octal -- stat prints it without a leading zero, so 8# is
  # required there, while uid and gid are decimal and must not get the prefix
  # (8#977 is not a number). A required uid of 0 always passes: root holds
  # CAP_DAC_OVERRIDE and writes regardless of the permission bits.
  read -r cur_uid cur_gid cur_mode < <(stat -c '%u %g %a' "$path") || { bad "could not stat $path between the existence check and now; re-run --check if this repeats."; continue; }
  cur_mode=$((8#$cur_mode))
  if (( uid == 0 )) || (( cur_uid == uid )) \
     || { (( cur_gid == gid )) && (( (cur_mode & 8#0020) != 0 )); } \
     || (( (cur_mode & 8#0002) != 0 )); then
    ok "$path ($cur_uid:$cur_gid $(printf '%o' "$cur_mode")) is writable by $who"
  else
    bad "$path ($cur_uid:$cur_gid $(printf '%o' "$cur_mode")) is NOT writable by $who, which $why. Fix with:
          sudo chown $uid:$gid '$path' && sudo chmod $mode '$path'"
  fi
done

# HOST_PATHS is a hand-written list, and the two deploy scripts are what actually
# build the paths the charts mount. If a deploy script is edited to mount a
# subdirectory that is not in HOST_PATHS, the loop above keeps validating the old
# set and prints OK about a path nothing uses, while the new one is never checked
# for ownership and can sit outside every backup. Derive the mounted list from
# the deploy scripts and the PV template, and fail on anything unaccounted for.
section "Host paths vs charts"
declared=$( {
  # The deploy scripts build each path as req('LIVE_DATA_PATH') + '/<sub>' (or
  # BACKUP_DATA_PATH). Reconstruct the absolute path from the same roots.
  grep -ohE "req\('(LIVE|BACKUP)_DATA_PATH'\) \+ '/[a-z0-9-]+'" \
    "$SCRIPT_DIR/postgresql/deploy.sh" "$SCRIPT_DIR/open-webui/deploy.sh" 2>/dev/null \
    | sed -E "s@.*req\('(LIVE|BACKUP)_DATA_PATH'\) \+ '/([a-z0-9-]+)'.*@\2 \1@" \
    | while read -r sub root; do
        [[ "$root" == LIVE ]] && echo "$LIVE_ROOT/$sub" || echo "$BACKUP_ROOT/$sub"
      done
  # The open-webui PV template hardcodes the open-webui subdirectory of the live root.
  grep -ohE '\$\{LIVE_DATA_PATH\}/[a-z0-9-]+' "$MANIFESTS/open-webui-volume.yaml.template" 2>/dev/null \
    | sed -E "s@\\\$\{LIVE_DATA_PATH\}@${LIVE_ROOT}@"
} | sort -u )
# The derivation above greps the deploy scripts for a fixed code shape
# (req('LIVE_DATA_PATH') + '/sub'). If that shape is ever refactored the grep
# silently yields fewer paths and the loop below would then bless a HOST_PATHS
# list that covers nothing. Six is the whole fixed layout; anything less is the
# audit going stale, not a clean run.
num_declared=$(printf '%s\n' "$declared" | grep -c . || true)
if (( num_declared < 6 )); then
  bad "only $num_declared of the 6 expected data paths were derived from the deploy scripts and the PV template — the grep patterns here have gone stale against a refactor. Fix this section before trusting HOST_PATHS."
fi
uncovered=0
while IFS= read -r want; do
  [[ -n "$want" ]] || continue
  covered=0
  for entry in "${HOST_PATHS[@]}"; do
    if [[ "${entry%%|*}" == "$want" ]]; then covered=1; fi
  done
  if (( ! covered )); then
    bad "$want is mounted by a deploy script but is not in HOST_PATHS in this script, so its ownership is never checked. Add it to HOST_PATHS."
    uncovered=1
  fi
done <<< "$declared"
if (( ! uncovered )) && [[ -n "$declared" ]]; then
  ok "every data path the deploy scripts build is covered by HOST_PATHS ($(printf '%s\n' "$declared" | grep -c .) paths)"
fi

# ── 4. Cluster primitives ─────────────────────────────────────────────────────
section "Cluster primitives"
# <what kubectl calls it>|<file in the repo>. A *.template is rendered to stdout
# and piped into kubectl rather than written to a temp file: the only value it
# needs is this cluster's node name, which a repository meant to be cloned cannot
# carry, and nothing holding it is left behind in /tmp.
for entry in \
  "storageclass.yaml|storageclass.yaml" \
  "open-webui-volume.yaml|open-webui-volume.yaml.template"; do
  IFS='|' read -r manifest source <<<"$entry"
  file="$MANIFESTS/$source"
  if [[ ! -f "$file" ]]; then
    bad "$file is missing from the repository."
    continue
  fi

  if [[ "$source" == *.template ]]; then
    if [[ -z "$NODE_HOSTNAME" ]]; then
      bad "$source names a node and none could be resolved; set K3S_NODE_NAME in .env."
      continue
    fi
    if [[ -z "$LIVE_ROOT" ]]; then
      bad "$source names a data root and none could be resolved; fix LIVE_DATA_PATH in .env."
      continue
    fi
    if ! rendered=$(NODE_HOSTNAME="$NODE_HOSTNAME" LIVE_DATA_PATH="$LIVE_ROOT" python3 -c '
import os, re, sys
text = open(sys.argv[1]).read()
text = text.replace("${K3S_NODE_NAME}", os.environ["NODE_HOSTNAME"])
text = text.replace("${LIVE_DATA_PATH}", os.environ["LIVE_DATA_PATH"])
left = sorted(set(re.findall(r"\$\{[^}]*\}", text)))
if left:
    sys.exit("unrendered placeholder(s): " + ", ".join(left))
sys.stdout.write(text)
' "$file"); then
      bad "could not render $file."
      continue
    fi
    src_desc="$source (node $NODE_HOSTNAME, data $LIVE_ROOT)"
    apply() { kubectl "$@" -f - <<<"$rendered"; }
  else
    src_desc="$source"
    apply() { kubectl "$@" -f "$file"; }
  fi

  if (( CHECK_ONLY )); then
    if apply apply --dry-run=server >/dev/null 2>&1; then
      ok "$manifest validates against the server"
    else
      ask "$manifest would not apply cleanly; run kubectl apply -f $file to see why."
    fi
    continue
  fi
  if apply apply >/dev/null; then
    ok "applied $src_desc"
  else
    bad "kubectl apply failed for $file."
  fi
done

if (( ! CHECK_ONLY )); then
  # The app pod cannot start without this claim Bound, and a Pending PVC here
  # means the PV above did not match -- usually the node hostname.
  phase=$(kubectl get pvc open-webui -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)
  if [[ "$phase" == Bound ]]; then
    ok "PVC open-webui is Bound"
  else
    bad "PVC open-webui is ${phase}, not Bound. The app pod will not start. Inspect with:
          kubectl describe pvc open-webui -n $NAMESPACE
          kubectl get pv open-webui-pv-local -o wide"
  fi
fi

# The StorageClass is intentionally provisioner-less. Warn if something else
# created a dynamic one under the same name, because that turns a missing PV into
# a silently-wrong volume on the wrong disk.
if command -v kubectl >/dev/null 2>&1 && kubectl get sc local-storage >/dev/null 2>&1; then
  prov=$(kubectl get sc local-storage -o jsonpath='{.provisioner}' 2>/dev/null || echo '?')
  if [[ "$prov" == "kubernetes.io/no-provisioner" ]]; then
    ok "StorageClass local-storage uses no-provisioner"
  else
    warn "StorageClass local-storage has provisioner '$prov'. A PVC with no matching PV would then be satisfied dynamically outside $LIVE_ROOT and outside every backup."
  fi
fi

# ── 5. Credentials ────────────────────────────────────────────────────────────
section "Credentials (Secrets in the cluster)"
needs_generation=0
if [[ ! -f "$ENV_FILE" ]] || (( $(stat -c %s "$ENV_FILE" 2>/dev/null || echo 0) == 0 )); then
  if (( CHECK_ONLY )); then
    ask "$ENV_FILE does not exist or is empty. Run ./deploy/setup.sh without --check to create it."
    needs_generation=1
  else
    ask "$ENV_FILE does not exist or is empty. Creating it from .env.example."
    needs_generation=1
  fi
else
  ok "$ENV_FILE exists ($(stat -c %a "$ENV_FILE") permissions)"
  if [[ "$(stat -c %a "$ENV_FILE")" != "600" ]]; then
    if (( CHECK_ONLY )); then
      ask "$ENV_FILE is mode $(stat -c %a "$ENV_FILE"); it holds credentials and should be 600. Run: chmod 600 $ENV_FILE"
    else
      chmod 600 "$ENV_FILE" && ok "chmod 600 $ENV_FILE"
    fi
  fi
fi

if (( ! CHECK_ONLY )) && [[ -f "$ENV_FILE" ]]; then
  # The template ships literal CHANGE-ME markers; a deploy that got this far with
  # one in place would start with a blank or guessable credential.
  for key in "${REQUIRED_KEYS[@]}"; do
    val=$(env_value "$key")
    if [[ -z "$val" || "$val" == CHANGE-ME* ]]; then
      needs_generation=1
      ask "$key is unset or still a template placeholder."
    fi
  done
fi

if (( ! CHECK_ONLY )) && (( needs_generation )); then
  # No secret is generated into .env any more: credentials live in the cluster.

  if [[ ! -f "$ENV_FILE" ]] || (( $(stat -c %s "$ENV_FILE" 2>/dev/null || echo 0) == 0 )); then
    # Seed from the template so the comments explaining each key survive, then
    # fill in. umask first: this file is created holding credentials.
    umask 077
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "seeded $ENV_FILE from .env.example (mode 600)"
  fi

  # The node name is the one value this script can answer on its own, because the
  # running cluster knows which node it has.
  if [[ -n "$NODE_HOSTNAME" ]] &&
     { [[ -z "$(env_value K3S_NODE_NAME)" ]] || [[ "$(env_value K3S_NODE_NAME)" == CHANGE-ME* ]]; }; then
    printf '%s' "$NODE_HOSTNAME" | set_env_key K3S_NODE_NAME
    ok "set K3S_NODE_NAME=$NODE_HOSTNAME (taken from $node_name_source)"
  fi

  # What is left cannot be invented: the node name when there was no cluster to
  # ask, and the site values only a human knows. setup.sh deliberately does NOT
  # prompt for those: deploy/bootstrap-host.sh owns the single validating .env
  # wizard, and the weaker copy of it that used to live here had already started
  # drifting from it (fewer validators, different prompts, same keys). Report
  # what is missing and send the operator to the wizard once.
  missing_human=()
  for key in "${REQUIRED_KEYS[@]}"; do
    val=$(env_value "$key")
    [[ -n "$val" && "$val" != CHANGE-ME* ]] || missing_human+=("$key")
  done
  if (( ${#missing_human[@]} )); then
    bad "setup.sh never prompts for site values — deploy/bootstrap-host.sh owns the .env wizard. Still missing in $ENV_FILE: ${missing_human[*]}. Run: ./deploy/bootstrap-host.sh --node-name ${NODE_HOSTNAME:-<name>}  (pass --configure to re-ask keys that are already set)"
  fi
fi

# The credentials themselves are checked against the cluster, not the file: the
# three pre-created Secrets (deploy/secret-init.sh) must exist and hold their
# keys, or the deploy below starts pods that CrashLoop on a blank password. A
# missing Secret is a loud refusal with the exact command, not a half-booted
# stack. --check reports it as a TODO and changes nothing.
secret_keys=(ai-open-webui-secrets:WEBUI_SECRET_KEY ai-open-webui-secrets:DATABASE_URL postgres:password)
if command -v kubectl >/dev/null 2>&1 && kubectl get -n default svc >/dev/null 2>&1; then
  for ref in "${secret_keys[@]}"; do
    s="${ref%%:*}"; k="${ref#*:}"
    if ! kubectl get secret "$s" -n default >/dev/null 2>&1; then
      if (( CHECK_ONLY )); then
        ask "Secret $s does not exist in default. Run: ./deploy/secret-init.sh"
      else
        bad "Secret $s does not exist in default — run ./deploy/secret-init.sh first (it prompts once for every credential, none are printed, nothing is written to disk)."
      fi
    elif [[ -z "$(kubectl get secret "$s" -n default -o jsonpath="{.data.$k}" 2>/dev/null)" ]]; then
      if (( CHECK_ONLY )); then
        ask "Secret $s is missing key $k. Run: ./deploy/secret-init.sh"
      else
        bad "Secret $s in default is missing key $k — re-run ./deploy/secret-init.sh."
      fi
    else
      ok "Secret $s carries $k"
    fi
  done
else
  if (( CHECK_ONLY )); then
    ask "kubectl not usable — cannot verify the credential Secrets (ai-open-webui-secrets, postgres)."
  fi
fi

# Format checks that the component scripts do not repeat, and that have bitten
# before: quotes, spaces around '=', and an `export` prefix all parse as part of
# the value and reach the container mangled.
if [[ -f "$ENV_FILE" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == export\ * ]]; then
      bad "$ENV_FILE has an 'export ' prefix; the deploy scripts parse the key literally. Drop 'export'."
    elif [[ "$line" != *=* ]]; then
      bad "$ENV_FILE has a line with no '=': ${line:0:30}"
    elif [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*[[:space:]]+= ]] || [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*=[[:space:]] ]]; then
      bad "$ENV_FILE has whitespace around '=' on: ${line:0:30}"
    fi
  done < <(grep -v $'\r' "$ENV_FILE" | grep -v '^[[:space:]]*$' || true)

  if grep -q $'\r' "$ENV_FILE" 2>/dev/null; then
    warn "$ENV_FILE has CRLF line endings; the trailing \\r becomes part of every value. Fix with: sed -i 's/\\r$//' $ENV_FILE"
  fi

fi

# ── 6. Inference endpoints ────────────────────────────────────────────────────
section "Inference backend"
# The app reads its endpoint list from its own config table when persistent
# config is on, so the chart value is only the fallback. Read the row when the
# database is up; it is the only accurate answer to "what is it using".
endpoints=()

# Endpoints reach this script in three shapes: the chart value is a full
# http://host:port/v1, the config table stores bare host:port with /v1, and a
# hand-written entry might carry a scheme or a trailing slash. Probe one form.
normalise_endpoint() {
  local e="$1"
  e="${e#http://}"; e="${e#https://}"; e="${e%/}"; e="${e%/v1}"
  [[ -n "$e" ]] || return 1
  printf 'http://%s/v1' "$e"
}

add_endpoint() {
  local n x
  n=$(normalise_endpoint "$1") || return 0
  if (( ${#endpoints[@]} )); then
    for x in "${endpoints[@]}"; do
      [[ "$x" == "$n" ]] && return 0
    done
  fi
  endpoints+=("$n")
}

chart_default=$(env_value OPENAI_API_BASE_URL)
if [[ -n "$chart_default" && "$chart_default" != CHANGE-ME* ]]; then
  add_endpoint "$chart_default"
fi

if kubectl get deploy/postgres -n "$NAMESPACE" >/dev/null 2>&1; then
  # Ask as the role the app uses, taken from .env, so a non-default
  # POSTGRES_USER/POSTGRES_DB does not make this silently report "no row yet".
  db_role=$(env_value POSTGRES_USER); db_role=${db_role:-openwebui}
  db_name=$(env_value POSTGRES_DB);   db_name=${db_name:-openwebui}
  row=$(kubectl exec deploy/postgres -n "$NAMESPACE" -- \
    psql -U "$db_role" -d "$db_name" -tAc \
    "select value from config where key='openai.api_base_urls'" 2>/dev/null | tr -d ' \r' || true)
  if [[ -n "$row" ]]; then
    note "the app's config row lists: $row"
    # The row stores a JSON array, not a comma-separated list. Splitting it on
    # commas yields fragments like `http://"http://10.0.0.5:8080/v1"/v1`, which
    # then probe nothing and get reported as down.
    mapfile -t row_list < <(printf '%s' "$row" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    v = json.loads(raw)
except Exception:
    v = [p for p in raw.split(",") if p]
if v is None:
    v = []
elif isinstance(v, str):
    v = [v]
elif not isinstance(v, (list, tuple)):
    v = [str(v)]
for e in v:
    if e is None:
        continue
    if str(e).strip():
        print(str(e).strip())
')
    for e in "${row_list[@]:-}"; do
      [[ -n "$e" ]] && add_endpoint "$e"
    done
  else
    note "no openai.api_base_urls row yet; the chart default is in effect."
  fi
else
  note "postgres is not deployed yet; checking only the chart default."
fi

if (( ${#endpoints[@]} == 0 )); then
  warn "no inference endpoint is configured anywhere; the app will start and have no models."
fi
live=0
for base in "${endpoints[@]}"; do
  # A fresh file per endpoint: reusing one makes a timed-out endpoint report the
  # model count of whichever probe last succeeded.
  tmp=$(mktemp)
  count=-
  code=000
  ms=0
  # Two attempts: an idle llama.cpp-style server can take seconds to answer the
  # first request after loading a model, and one short timeout would report a live
  # endpoint as down. Latency is printed so slow reads differently from absent.
  for _attempt in 1 2; do
    t0=$(date +%s%3N)
    # curl prints 000 through -w when it never connected and still exits non-zero,
    # so appending `|| echo 000` produced "000000".
    code=$(curl -s -o "$tmp" -w '%{http_code}' --max-time 10 "${base%/}/models" 2>/dev/null) || code=000
    ms=$(( $(date +%s%3N) - t0 ))
    [[ "$code" == 200 ]] && break
  done
  count=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1])).get('data',[])))" "$tmp" 2>/dev/null || echo '-')
  rm -f "$tmp"
  if [[ "$code" == 200 && "$count" != 0 && "$count" != "-" ]]; then
    ok "$base -> $code, $count model(s) in ${ms}ms"
    live=$((live + 1))
  elif [[ "$code" == 000 ]]; then
    warn "$base is unreachable after 2 attempts (${ms}ms). Chat requests to it will fail; the app logs a connection error for it on every model-list refresh."
  else
    warn "$base returned $code with $count models (${ms}ms)."
  fi
done
if (( live == 0 )) && (( ${#endpoints[@]} > 0 )); then
  warn "not one inference endpoint answered. Open WebUI will deploy and serve, but no chat will work."
fi

# ── 7. Public URL and the reverse proxy ───────────────────────────────────────
section "Public URL and TLS"
# TLS is terminated outside the cluster: the chart sets WEBUI_URL from .env and the
# app Service is a NodePort. If nothing forwards the hostname, OAuth breaks because
# the provider redirects the browser there.
webui_url=$(env_value WEBUI_URL)
if [[ -z "$webui_url" || "$webui_url" == CHANGE-ME* ]]; then
  warn "WEBUI_URL is not set in $ENV_FILE; the app cannot build correct OAuth and email links."
else
  # Parse the authority out of the URL before asking anything about it. Handing
  # getent the scheme-stripped string outright breaks a legitimate WEBUI_URL that
  # carries a port or a path: 'ai.example.com:8443' never resolves, and this branch
  # calls bad(), so setup.sh refused to run over a URL that deploy.sh accepts.
  if [[ "$webui_url" == *://* ]]; then
    scheme=${webui_url%%://*}
    hostport=${webui_url#*://}
  else
    scheme=http
    hostport=$webui_url
  fi
  hostport=${hostport%%/*}
  hostport=${hostport##*@}   # drop any basic-auth userinfo; a public URL has none
  webui_host=${hostport%%:*}
  case "$hostport" in
    *:*) webui_port="${hostport##*:}" ;;
    *)   if [[ "$scheme" == https ]]; then webui_port=443; else webui_port=80; fi ;;
  esac
  # `|| true` is load-bearing: getent exits 2 on an unknown name, and with
  # `set -o pipefail` that status becomes the assignment's, which would abort the
  # script under set -e on the very case this check exists to report.
  ip=$(getent hosts "$webui_host" | awk '{print $1; exit}' || true)
  if [[ -z "$ip" ]]; then
    bad "$webui_url does not resolve '$webui_host'. Google OAuth redirects the browser there, so login fails silently. Point the DNS record at the reverse proxy."
  else
    ok "$webui_url resolves to $ip"
    # curl prints 000 through -w when it never connected and still exits non-zero,
    # so appending `|| echo 000` produced "000000" here, the same way it did in the
    # inference probe above. Assign the status and default it on failure instead.
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$webui_url/" 2>/dev/null) || code=000
    if [[ "$code" =~ ^2|^3 ]]; then
      ok "$webui_url answers $code"
    else
      warn "$webui_url returned $code. The reverse proxy must forward it to the app's NodePort 30000 on $NODE_HOSTNAME."
    fi
    if [[ "$scheme" == https ]]; then
      cert_end=$(echo | timeout 8 openssl s_client -connect "${webui_host}:${webui_port}" -servername "$webui_host" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2- || true)
      if [[ -n "$cert_end" ]]; then
        ok "TLS certificate valid until $cert_end"
      else
        warn "no TLS certificate presented for ${webui_host}:${webui_port}."
      fi
    else
      # Probing TLS against a plain-http port used to emit a bogus "no certificate"
      # warning for a WEBUI_URL that never claimed to be TLS. OAuth needs https in
      # production, so say that instead of the misleading one.
      warn "WEBUI_URL is $scheme, not https: no certificate checked. Google OAuth needs a public https URL."
    fi
  fi
fi

# ── 8. Report and hand off ────────────────────────────────────────────────────
echo
if (( ${#warnings[@]} )); then
  echo "${#warnings[@]} warning(s) recorded above. They do not block a deploy."
fi
if (( ${#errors[@]} )); then
  echo
  echo "Setup stopped: ${#errors[@]} blocking problem(s):" >&2
  for e in "${errors[@]}"; do echo "  - $e" >&2; done
  exit 1
fi

if (( CHECK_ONLY )); then
  echo
  echo "OK: --check found no blocking problems. Nothing was changed."
  exit 0
fi

if [[ "$MODE" == no-deploy ]]; then
  echo
  echo "OK: prerequisites satisfied and primitives applied. Skipped the deploy (--no-deploy)."
  echo "    Run the deploy when ready: ./deploy/deploy.sh"
  exit 0
fi

section "Deploy"
exec "$SCRIPT_DIR/deploy.sh"
