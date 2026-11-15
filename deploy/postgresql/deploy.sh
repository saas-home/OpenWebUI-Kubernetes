#!/usr/bin/env bash
# Deploy the postgres release.
#
# The database password lives only in the gitignored .env at the repository root.
# It is never written to values.yaml, which is tracked, and is passed to helm in a
# 0600 temp file that this script deletes on exit.
#
# Usage:
#   ./deploy.sh              # lint, then upgrade --install
#   ./deploy.sh --dry-run    # render the chart, change nothing on the cluster
#   ./deploy.sh --check      # does .env match what the release and the live DB use?
#
# An unrecognized argument is a hard error: the default path is a live deploy, so a
# mistyped --dry-run must not silently become one.
set -euo pipefail

cd "$(dirname "$0")"

RELEASE=postgres          # MUST stay `postgres`: _helpers.tpl returns .Release.Name verbatim
NAMESPACE=default
# Two levels up from deploy/postgresql/ is the repository root, where .env lives.
REPO_ROOT="$(cd ../.. && pwd)"
ENV_FILE="$REPO_ROOT/.env"
ENV_EXAMPLE="$(cd ../.. && pwd)/.env.example"

# manifest_check: recompute every fingerprint recorded in secrets.manifest
# (HMAC-SHA256 of the live Secret value under its stored salt) and fail loudly on
# any change. Read-only; the value never appears in output or on a command line.
# The manifest carries names, salts and hashes only — never a value.
manifest_check() {
  local ref salt expected m_secret m_key live actual drift=0
  while read -r ref salt expected; do
    m_secret="${ref%%/*}"; m_key="${ref#*/}"
    live="$(kubectl get secret "$m_secret" -n "$NAMESPACE" -o jsonpath="{.data.$m_key}" 2>/dev/null | base64 -d 2>/dev/null || true)"
    actual="$(printf '%s' "$live" | openssl dgst -sha256 -hmac "$salt" -hex 2>/dev/null | awk '{print $NF}')"
    if [[ "$actual" != "$expected" ]]; then
      echo "DRIFT: $ref changed since secrets.manifest was written (rotated?). Re-run ./deploy/secret-init.sh to re-record." >&2
      drift=1
    fi
  done <"$REPO_ROOT/secrets.manifest"
  if (( drift )); then return 1; fi
  echo "OK: every fingerprint matches secrets.manifest."
  return 0
}

# The chart renders no credentials: the DB password lives in the pre-created
# `postgres` Secret (deploy/secret-init.sh), encrypted at rest by K3s
# --secrets-encryption, and the chart references it by name. What .env still
# owns is the database coordinates and K3S_NODE_NAME — the node the local PV
# pins itself to.
REQUIRED_VARS=(K3S_NODE_NAME POSTGRES_DB POSTGRES_USER)

# Optional site values with defaults. An empty or absent value means the
# documented default under $HOME; the resolve function below turns every
# spelling into an absolute path and injects it into the chart values.
PATH_VARS=(LIVE_DATA_PATH BACKUP_DATA_PATH)

# Capacity and scale. Optional: an empty MESSAGE_SCALE means the small profile,
# and an empty DEPLOY_* means "the profile's own minimum", so an .env written
# before these keys existed keeps deploying unchanged. apply_profile() below
# validates the enum and gates the declared capacity against the profile.
SCALE_VARS=(MESSAGE_SCALE DEPLOY_CPU_CORES DEPLOY_MEMORY_GB DEPLOY_STORAGE_GB)

usage() {
  cat >&2 <<'MSG'
Usage: ./deploy.sh [--dry-run | --check] [--pinned]

  (no argument)  lint, helm upgrade --install, wait for the rollout, verify
  --dry-run      lint and render the chart; changes nothing on the cluster.
                 Secret manifests are withheld from the output.
  --check        compare .env against the live release and the stored DB password
  --pinned       on a FRESH install (no such release on the cluster yet), deploy
                 the values.yaml pins instead of resolving the newest GA images
MSG
}

MODE=deploy
USE_PINNED=0
seen_mode=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|--check)
      # One mode, repeatable only when it is the same mode. --pinned is an
      # orthogonal flag, so ./deploy.sh --dry-run --pinned is well defined.
      if (( seen_mode )) && [[ "$MODE" != "${arg#--}" ]]; then
        echo "ERROR: two modes given." >&2
        usage
        exit 2
      fi
      MODE="${arg#--}"; seen_mode=1 ;;
    --pinned) USE_PINNED=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument '$arg'." >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  echo "       Create it from the template and fill in real values:" >&2
  echo "         cp $ENV_EXAMPLE $ENV_FILE" >&2
  echo "         chmod 600 $ENV_FILE" >&2
  echo "         \${EDITOR:-vi} $ENV_FILE" >&2
  exit 1
fi

if ! git check-ignore -q "$ENV_FILE" 2>/dev/null; then
  echo "ERROR: $ENV_FILE is not gitignored. Add it to .gitignore before continuing." >&2
  exit 1
fi

perms=$(stat -c '%a' "$ENV_FILE") || { echo "ERROR: cannot stat $ENV_FILE." >&2; exit 1; }
if [[ "$perms" != "600" && "$perms" != "400" ]]; then
  echo "WARNING: $ENV_FILE has mode $perms; expected 600. Fixing it." >&2
  chmod 600 "$ENV_FILE"
fi

# Parse KEY=VALUE lines only; ignore comments and blanks.
#
#  - `|| [[ -n ... ]]` keeps a final line with no trailing newline. `read` fills the
#    variables and still returns non-zero at EOF, so that line used to vanish -- and
#    when it was the second definition of a key, the stale earlier value won and the
#    script deployed it happily.
#  - Only REQUIRED_VARS are exported, after clearing them first, so a credential can
#    only ever come from .env (never from an inherited shell variable), and a stray
#    `RELEASE=` or `NAMESPACE=` line cannot retarget the helm and kubectl calls below.
#  - Values are trimmed of CR and outer whitespace so this shell and the python
#    renderer, which strips, always compare the same bytes.
unset "${REQUIRED_VARS[@]}" "${PATH_VARS[@]}" "${SCALE_VARS[@]}"
while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
  [[ "$key" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${key// /}" ]] && continue
  key="${key//[[:space:]]/}"
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
  value="${value%$'\r'}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  for v in "${REQUIRED_VARS[@]}" "${PATH_VARS[@]}" "${SCALE_VARS[@]}"; do
    [[ "$key" == "$v" ]] && export "$key=$value"
  done
done < "$ENV_FILE"

missing=()
for v in "${REQUIRED_VARS[@]}"; do
  val="${!v:-}"
  if [[ -z "$val" ]]; then missing+=("$v (unset)");
  elif [[ "$val" == CHANGE-ME* ]]; then missing+=("$v (still the .env.example placeholder)"); fi
done
if (( ${#missing[@]} )); then
  echo "ERROR: $ENV_FILE is incomplete:" >&2
  printf '       %s\n' "${missing[@]}" >&2
  exit 1
fi

# Shape checks, deploy-time not wizard-time: the README documents hand-editing
# .env, which bypasses bootstrap-host.sh's validators. These four names reach
# the backup CronJob (PG_USER as a container env, and the host through psql
# arguments), and auth.username also lands in initdb SQL. An identifier with a
# quote or $( ) in it must die here, at the boundary, not render into a
# manifest.
[[ "$POSTGRES_USER" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "ERROR: POSTGRES_USER '$POSTGRES_USER' must be letters, digits and underscores, starting with a letter or underscore." >&2; exit 1; }
[[ "$POSTGRES_DB"   =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "ERROR: POSTGRES_DB '$POSTGRES_DB' must be letters, digits and underscores, starting with a letter or underscore." >&2; exit 1; }

# Resolve the two data roots. Empty or a leftover placeholder means the
# documented default; a leading ~ is expanded so a hand-edited .env may use
# either spelling. Both the deploy scripts and setup.sh resolve identically,
# and the charts receive the full paths from gen_values below — no
# machine-specific path is ever committed to a tracked file.
resolve_data_root() { # <value> <default> <key-name>
  local v="${1:-}" def="$2" key="$3"
  [[ "$v" == CHANGE-ME* ]] && v=""
  v="${v:-$def}"
  [[ "$v" == "~" ]] && v="$HOME"
  [[ "$v" == "~/"* ]] && v="$HOME/${v#\~/}"
  [[ "$v" == /* ]] || { echo "ERROR: $key must be an absolute path (or empty for the default); got '$v'." >&2; exit 1; }
  [[ "$v" =~ [[:space:]] ]] && { echo "ERROR: $key must not contain spaces: '$v'." >&2; exit 1; }
  # Character class, not just "no spaces": these strings are rendered into
  # CronJob manifests and PV specs. Anything outside [A-Za-z0-9._/-] -- $, (,
  # ), backtick, quote, semicolon -- is rejected here even though the
  # templates now pass such values through env, so a hand-edited .env cannot
  # smuggle shell metacharacters into anything the node executes.
  [[ "$v" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "ERROR: $key may contain only letters, digits, '.', '_', '-' and '/': '$v'." >&2; exit 1; }
  printf '%s' "${v%/}"
}
LIVE_DATA_PATH=$(resolve_data_root "${LIVE_DATA_PATH:-}" "$HOME/.open-webui/live-data" LIVE_DATA_PATH)
BACKUP_DATA_PATH=$(resolve_data_root "${BACKUP_DATA_PATH:-}" "$HOME/.open-webui/backup-data" BACKUP_DATA_PATH)
if [[ "$LIVE_DATA_PATH" == "$BACKUP_DATA_PATH" ]]; then
  echo "ERROR: LIVE_DATA_PATH and BACKUP_DATA_PATH are the same path ($LIVE_DATA_PATH)." >&2
  echo "       Backups must not live in the tree they protect. See .env.example." >&2
  exit 1
fi
export LIVE_DATA_PATH BACKUP_DATA_PATH

# ── Message-scale resource profile ───────────────────────────────────────────
# What this deployment is sized FOR, in total stored chat messages. One table,
# two consumers: this script renders the open-webui, searxng, redis and
# uploads-backup envelopes plus the app's concurrency env vars, and the sibling
# component script renders the database's. selftest.sh asserts the two copies
# are byte-identical, so a value edited in one place and not the other fails the
# self-test instead of silently splitting the stack in two.
#
# Why the numbers move together:
#   workers               a request holds a worker for longer as the tables grow,
#                         so the worker count rises with the message count and
#                         latency stays flat instead of drifting up.
#   shared_buffers,       the database grows about 20 kB per stored message
#   effective_cache_size  (measured on this deployment), so the cache Postgres
#                         owns and the cache the planner is told about both have
#                         to grow with it.
#   max_connections       20 per worker (pool 10 + overflow 10) plus headroom for
#                         migrations, the backup job and a psql session.
#   memory limits         they SUM to the profile's RAM, and the requests sum to
#                         about half of it. The unrequested half stays kernel
#                         page cache, which is what actually accelerates Postgres
#                         reads on a single node. Idle RAM is not wasted RAM.
#
# MESSAGE_SCALE picks the row. DEPLOY_CPU_CORES / DEPLOY_MEMORY_GB /
# DEPLOY_STORAGE_GB declare what the machine can spare and are enforced as
# minimums, so a scale the host cannot carry fails here with the exact shortfall
# instead of filling the disk six months later.
#
# BEGIN PROFILE TABLE (duplicated verbatim in the sibling component script)
profile_block() { # <scale> — the profile as key=value lines
  case "$1" in
  small) cat <<'EOF'
messages=100000
db_gb=2
cpu=4
ram_gb=8
disk_gb=50
workers=3
pool_size=10
pool_overflow=10
max_connections=100
app_cpu_req=500m
app_cpu_lim=2
app_mem_req=2560Mi
app_mem_lim=4Gi
pg_cpu_req=500m
pg_cpu_lim=1
pg_mem_req=1Gi
pg_mem_lim=2Gi
shared_buffers=512MB
effective_cache_size=1GB
work_mem=16MB
maintenance_work_mem=256MB
max_wal_size=2GB
searxng_cpu_req=100m
searxng_cpu_lim=500m
searxng_mem_req=256Mi
searxng_mem_lim=1Gi
redis_cpu_req=50m
redis_cpu_lim=200m
redis_mem_req=64Mi
redis_mem_lim=256Mi
backup_cpu_req=50m
backup_cpu_lim=300m
backup_mem_req=64Mi
backup_mem_lim=512Mi
EOF
    ;;
  medium) cat <<'EOF'
messages=1000000
db_gb=20
cpu=8
ram_gb=16
disk_gb=250
workers=5
pool_size=10
pool_overflow=10
max_connections=150
app_cpu_req=1
app_cpu_lim=4
app_mem_req=4Gi
app_mem_lim=8Gi
pg_cpu_req=500m
pg_cpu_lim=2
pg_mem_req=1536Mi
pg_mem_lim=4Gi
shared_buffers=1GB
effective_cache_size=2GB
work_mem=16MB
maintenance_work_mem=512MB
max_wal_size=4GB
searxng_cpu_req=200m
searxng_cpu_lim=1
searxng_mem_req=384Mi
searxng_mem_lim=1536Mi
redis_cpu_req=100m
redis_cpu_lim=500m
redis_mem_req=128Mi
redis_mem_lim=512Mi
backup_cpu_req=100m
backup_cpu_lim=500m
backup_mem_req=128Mi
backup_mem_lim=1Gi
EOF
    ;;
  large) cat <<'EOF'
messages=10000000
db_gb=200
cpu=12
ram_gb=24
disk_gb=1500
workers=8
pool_size=10
pool_overflow=10
max_connections=200
app_cpu_req=2
app_cpu_lim=6
app_mem_req=6Gi
app_mem_lim=12Gi
pg_cpu_req=1
pg_cpu_lim=4
pg_mem_req=3Gi
pg_mem_lim=8Gi
shared_buffers=2GB
effective_cache_size=4GB
work_mem=16MB
maintenance_work_mem=512MB
max_wal_size=8GB
searxng_cpu_req=300m
searxng_cpu_lim=1
searxng_mem_req=512Mi
searxng_mem_lim=2Gi
redis_cpu_req=200m
redis_cpu_lim=500m
redis_mem_req=256Mi
redis_mem_lim=1Gi
backup_cpu_req=200m
backup_cpu_lim=500m
backup_mem_req=256Mi
backup_mem_lim=1Gi
EOF
    ;;
  *) return 1 ;;
  esac
}
# END PROFILE TABLE

# Turn the selected row into P_<field> variables. The transport is textual and
# never eval: a value from this table can only ever be assigned, never executed.
load_profile() { # <scale>
  local k v
  while IFS='=' read -r k v; do
    [[ -n "$k" ]] && printf -v "P_$k" '%s' "$v"
  done < <(profile_block "$1")
}

fmt_count() { # 100000 -> 100,000
  local n="$1" out=""
  while (( ${#n} > 3 )); do out=",${n: -3}${out}"; n="${n:0:${#n}-3}"; done
  printf '%s' "$n$out"
}

print_profile() {
  printf 'Resource profile: %s — sized for %s stored messages (~%s GB database)\n' \
    "$MESSAGE_SCALE" "$(fmt_count "$P_messages")" "$P_db_gb"
  printf '  %-11s cpu %-9s memory %-12s %s\n' \
    open-webui "$P_app_cpu_req/$P_app_cpu_lim" "$P_app_mem_req/$P_app_mem_lim" \
    "$P_workers uvicorn workers"
  printf '  %-11s cpu %-9s memory %-12s %s\n' \
    postgresql "$P_pg_cpu_req/$P_pg_cpu_lim" "$P_pg_mem_req/$P_pg_mem_lim" \
    "shared_buffers $P_shared_buffers, effective_cache_size $P_effective_cache_size, max_connections $P_max_connections"
  printf '  %-11s cpu %-9s memory %-12s\n' \
    searxng "$P_searxng_cpu_req/$P_searxng_cpu_lim" "$P_searxng_mem_req/$P_searxng_mem_lim"
  printf '  %-11s cpu %-9s memory %-12s\n' \
    redis "$P_redis_cpu_req/$P_redis_cpu_lim" "$P_redis_mem_req/$P_redis_mem_lim"
  printf '  %-11s cpu %-9s memory %-12s\n' \
    backups "$P_backup_cpu_req/$P_backup_cpu_lim" "$P_backup_mem_req/$P_backup_mem_lim"
  printf 'Capacity: %s CPU cores, %s GB RAM, %s GB disk declared (profile minimum %s/%s/%s)\n' \
    "$DEPLOY_CPU_CORES" "$DEPLOY_MEMORY_GB" "$DEPLOY_STORAGE_GB" \
    "$P_cpu" "$P_ram_gb" "$P_disk_gb"
}

# One gate, one message. Declaring MORE than the profile needs is normal — the
# surplus becomes page cache — so only a shortfall fails.
require_capacity() { # <key> <declared> <minimum> <unit>
  local key="$1" have="$2" need="$3" unit="$4"
  [[ "$have" =~ ^[0-9]+$ ]] || {
    echo "ERROR: $key='$have' must be a whole number ($unit)." >&2; exit 1; }
  if (( 10#$have < 10#$need )); then
    echo "ERROR: MESSAGE_SCALE=$MESSAGE_SCALE is sized for $(fmt_count "$P_messages") stored messages and needs at least $need $unit." >&2
    echo "       $key=$have. Raise $key in .env, or choose a smaller MESSAGE_SCALE." >&2
    exit 1
  fi
}

apply_profile() {
  MESSAGE_SCALE="${MESSAGE_SCALE:-small}"
  case "$MESSAGE_SCALE" in
    small|medium|large) ;;
    *) echo "ERROR: MESSAGE_SCALE='$MESSAGE_SCALE' must be small, medium or large." >&2; exit 1 ;;
  esac
  load_profile "$MESSAGE_SCALE"
  # A missing key means "the profile's own minimum", so an .env written before
  # this feature existed keeps deploying instead of failing on three blank lines.
  DEPLOY_CPU_CORES="${DEPLOY_CPU_CORES:-$P_cpu}"
  DEPLOY_MEMORY_GB="${DEPLOY_MEMORY_GB:-$P_ram_gb}"
  DEPLOY_STORAGE_GB="${DEPLOY_STORAGE_GB:-$P_disk_gb}"
  require_capacity DEPLOY_CPU_CORES  "$DEPLOY_CPU_CORES"  "$P_cpu"     "CPU cores"
  require_capacity DEPLOY_MEMORY_GB  "$DEPLOY_MEMORY_GB"  "$P_ram_gb"  "GB of RAM"
  require_capacity DEPLOY_STORAGE_GB "$DEPLOY_STORAGE_GB" "$P_disk_gb" "GB of disk"
  # gen_values reads the selected row from the environment rather than
  # re-deriving it, so the shell gate and the rendered values cannot disagree.
  PROFILE_BLOCK=$(profile_block "$MESSAGE_SCALE")
  export PROFILE_BLOCK
  print_profile
}

# Render, print and gate the message-scale envelope before anything is deployed.
apply_profile

GEN_VALUES=""
cleanup() {
  if [[ -n "$GEN_VALUES" && -f "$GEN_VALUES" ]]; then
    rm -f "$GEN_VALUES" || echo "WARNING: could not remove $GEN_VALUES." >&2
  fi
  return 0
}
# return 0 is not decoration. When the script reaches its end normally, the false
# `[[ -n ... ]]` short-circuit inside the trap becomes the exit status under `set -e`,
# which made ./deploy.sh --check exit 1 on a run where every check had passed. An
# explicit `exit N` still keeps its own status.
trap cleanup EXIT
# TERM and HUP are caught: killing or disconnecting a deploy removes the file. Ctrl-C
# is not -- measured on bash 5.2.21, a SIGINT that kills the foreground child takes bash
# down without running any trap, foreground or background. That residue is bounded by
# the sweep in gen_values, which deletes leftovers from earlier interrupted runs on the
# next invocation. `ls /tmp/openwebui-deploy-*.yaml` shows what is outstanding.
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

gen_values() {
  # Clear leftovers from deploys that were killed before any trap could run. The prefix
  # is unique to these scripts, -user leaves other accounts' files alone, and the age
  # bound spares a run that is in progress right now.
  find "${TMPDIR:-/tmp}" -maxdepth 1 -type f -user "$(id -u)" \
    -name 'openwebui-deploy-*.yaml' -mmin +60 -delete 2>/dev/null || true
  GEN_VALUES=$(mktemp "${TMPDIR:-/tmp}/openwebui-deploy-XXXXXXXX.yaml")
  chmod 600 "$GEN_VALUES"
  GEN_FILE="$GEN_VALUES" python3 - <<'PY'
import json, os
e = os.environ
def req(k):
    v = e.get(k, '').strip()
    if not v or v.startswith('CHANGE-ME'):
        raise SystemExit(f"ERROR: {k} missing from .env")
    return v

# The message-scale row selected by MESSAGE_SCALE, as key=value lines emitted by
# profile_block() in the shell above. Parsing that one block here — instead of
# repeating the numbers in Python — is what keeps the printed table, the gate
# that validated it and the rendered settings from ever disagreeing. The app
# script parses the same block for the other workloads.
prof = dict(line.split('=', 1) for line in e['PROFILE_BLOCK'].splitlines() if '=' in line)

def res(pre):
    """One workload's requests/limits from the profile row."""
    return {'requests': {'cpu': prof[pre + '_cpu_req'],
                         'memory': prof[pre + '_mem_req']},
            'limits':   {'cpu': prof[pre + '_cpu_lim'],
                         'memory': prof[pre + '_mem_lim']}}

# No password is rendered: the chart references the pre-created Secret by
# name (auth.existingSecret in values.yaml). Nothing in this file ever holds
# or sees the credential.
doc = {'auth': {'database': req('POSTGRES_DB'),
                'username': req('POSTGRES_USER')},
       'persistence': {'nodeName': req('K3S_NODE_NAME'),
                       'localPath': req('LIVE_DATA_PATH') + '/postgresql'},
       'backup': {'hostPath': req('LIVE_DATA_PATH') + '/postgresql-backups',
                  'offDisk': {'hostPath': req('BACKUP_DATA_PATH') + '/postgresql'},
                  'resources': res('backup')},
       'resources': res('pg')}

# The server flags come from the same row, so shared_buffers and the container's
# memory limit are decided together: a cache the cgroup would evict is worse
# than no cache at all. `docker-entrypoint.sh postgres` keeps initdb and
# /docker-entrypoint-initdb.d in the path — a command starting with `postgres`
# skips both and extraDatabases silently stops being created.
doc['command'] = ['docker-entrypoint.sh', 'postgres',
                  '-c', 'max_connections=' + prof['max_connections'],
                  '-c', 'shared_buffers=' + prof['shared_buffers'],
                  '-c', 'effective_cache_size=' + prof['effective_cache_size'],
                  '-c', 'work_mem=' + prof['work_mem'],
                  '-c', 'maintenance_work_mem=' + prof['maintenance_work_mem'],
                  '-c', 'wal_compression=on',
                  '-c', 'random_page_cost=1.1',
                  '-c', 'max_wal_size=' + prof['max_wal_size'],
                  '-c', 'max_parallel_workers_per_gather=4']

with open(os.environ['GEN_FILE'], 'w') as f:
    json.dump(doc, f)
PY
  ARGS+=(-f "$GEN_VALUES")
}

ARGS=()

# The password lives only in the pre-created `postgres` Secret (secret-init.sh);
# it is honoured only while initdb runs on an empty data directory. Rotating it
# means ALTER USER in psql first, then re-running secret-init.sh — a Secret edit
# alone leaves the database on the old credential and the CronJob on the new one,
# which breaks backups silently. So the drift check compares what .env still owns
# (the POSTGRES_* coordinates, node name, paths) against both places those are
# stored: the release values helm kept, and the Secret the container and the
# backup job read.
#
# Prints the names of the keys that disagree with .env, space-separated and on one
# line, and never prints a value. The expectations arrive in the 0600 rendered
# values file, not on a command line, so the password never reaches the node's
# process list. Exit 1 means drift, 3 means the input was unreadable, 0 means
# everything matched.
#
# The comparison is driven by what gen_values renders, not by a hand-written key
# list: a key added to gen_values used to be silently never checked, which is how
# a MESSAGE_SCALE change could leave the database on the previous profile while
# the app moved to the new one.
#
# persistence.nodeName is compared alongside the credentials because it is a
# user-supplied value now, and it is the one that decides whether the pod can
# schedule at all: a PV whose nodeAffinity names the wrong node leaves the release
# installed, the PVC Pending, and nothing in the events saying why.
compare_release_values() { # <rendered-values-file> ; live JSON on stdin
  python3 -c '
import json, sys
try:
    live = json.load(sys.stdin)
except ValueError:
    sys.stderr.write("the release values are not valid JSON\n")
    sys.exit(3)
want = json.load(open(sys.argv[1]))
bad = []
def walk(path, want_node, live_node):
    if isinstance(want_node, dict):
        if not isinstance(live_node, dict):
            bad.append(path or "<root>")
            return
        for key, value in want_node.items():
            walk(path + "." + key if path else key, value, live_node.get(key))
    elif live_node != want_node:
        bad.append(path)
walk("", want, live)
if bad:
    print(" ".join(sorted(bad)))
    sys.exit(1)
' "$1"
}

if [[ "$MODE" == "check" ]]; then
  echo "Comparing $ENV_FILE against the live release..."
  # "Cannot ask the cluster" and "release not installed" used to print the same line,
  # which sent people looking for a release nobody had deleted.
  if ! current=$(helm get values "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null); then
    echo "ERROR: cannot read the values of release $RELEASE in $NAMESPACE." >&2
    echo "       It was either never installed or the cluster is unreachable. Check:" >&2
    echo "         helm list -n $NAMESPACE" >&2
    exit 1
  fi
  [[ -n "$current" ]] || current='{}'

  drift=0
  # Parsed, not grepped. `grep -q password:` also matches the `auth.password: ""`
  # that a bare `helm upgrade` (no .env, no ./deploy.sh) leaves behind, so an
  # empty credential read as a match. gen_values renders exactly what a deploy
  # would write — credentials, paths, the profile's resources and the server
  # flags — so every one of them is compared by value.
  gen_values
  drifted=$(printf '%s' "$current" | compare_release_values "$GEN_VALUES") || drifted_rc=$?
  drifted_rc=${drifted_rc:-0}
  case "$drifted_rc" in
    0) echo "OK: every key the deploy would write matches $ENV_FILE." ;;
    1) echo "DRIFT: the live release values differ from $ENV_FILE for: $drifted" >&2
       echo "       Run ./deploy.sh to reconcile." >&2
       drift=1 ;;
    *) echo "ERROR: could not read the live values of release $RELEASE." >&2
       exit 1 ;;
  esac

  # Then the pre-created Secret. helm no longer owns it, so this is not release
  # drift — it is the credential contract: both the Deployment and the backup
  # CronJob consume it through a non-optional secretKeyRef, and envFrom yields ""
  # for a missing key rather than failing. The fingerprint check compares against
  # secrets.manifest when it exists: enough to catch a value that changed since
  # secret-init.sh last ran, without ever holding or printing the value.
  if ! kubectl get secret "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "DRIFT: the $RELEASE Secret does not exist in $NAMESPACE." >&2
    echo "       The Deployment and the backup CronJob both require it." >&2
    echo "       Create it with: ./deploy/secret-init.sh" >&2
    drift=1
  elif [[ -z "$(kubectl get secret "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null)" ]]; then
    echo "DRIFT: the $RELEASE Secret holds no password key." >&2
    echo "       Re-run: ./deploy/secret-init.sh" >&2
    drift=1
  else
    echo "OK: the $RELEASE Secret exists and holds the password key."
  fi
  if [[ -f "$REPO_ROOT/secrets.manifest" ]]; then
    manifest_check || drift=1
  else
    echo "NOTE: no secrets.manifest — run ./deploy/secret-init.sh once to record fingerprints."
  fi
  exit "$drift"
fi

# Fresh-install policy: with no release on the cluster, deploy the newest GA
# image instead of the repo pin — a brand-new machine should not start life
# on a months-old tag. Once the release exists, deploys stop floating and
# follow values.yaml exactly, because a steady-state upgrade must be
# reproducible and reviewed. --pinned opts out of the float even on a fresh
# install. A registry that cannot be reached is never a deploy failure: the
# pin is used and the fallback is printed. Taking a newer *major* is safe
# here alone — fresh means an empty database, no dump/restore in play.
if [[ "$MODE" != check ]] && (( ! USE_PINNED )) &&
   ! helm list -n "$NAMESPACE" -q 2>/dev/null | grep -qx "$RELEASE"; then
  latest=$(curl -s --max-time 12 -H "User-Agent: openwebui-deploy/1.0" \
      "https://hub.docker.com/v2/repositories/library/postgres/tags?page_size=100&ordering=last_updated" | \
    python3 -c '
import sys, json, re
try:
    tags = [t["name"] for t in json.load(sys.stdin)["results"]]
except Exception:
    raise SystemExit(0)
ga = [t for t in tags if re.fullmatch(r"\d+\.\d+(\.\d+)?-alpine", t)]
def v(t):
    m = re.match(r"(\d+)\.(\d+)(?:\.(\d+))?", t)
    return tuple(int(x or 0) for x in m.groups())
ga.sort(key=v, reverse=True)
print(ga[0] if ga else "")
' 2>/dev/null || true)
  pinned=$(awk '$1=="tag:" {gsub(/"/,"",$2); print $2; exit}' values.yaml)
  if [[ -z "$latest" ]]; then
    echo "fresh install: Docker Hub unreachable; deploying the pinned postgres:$pinned"
  elif [[ "$latest" == "$pinned" ]]; then
    echo "fresh install: postgres:$pinned is already the newest GA"
  else
    echo "fresh install: postgres:$latest (values.yaml pins $pinned) — pass --pinned to deploy the pin"
    ARGS+=(--set "image.tag=$latest")
  fi
fi

# Render the values before linting so the dry-run and the real deploy differ by
# exactly one flag. A lint or dry-run that skips them renders an empty
# auth.password and reviews a manifest the deploy will never produce.
gen_values

echo "helm lint"
helm lint . "${ARGS[@]}"

if [[ "$MODE" == "dry-run" ]]; then
  echo
  echo "helm upgrade --dry-run=client --hide-secret"
  # --hide-secret is belt and braces: the chart no longer owns a credential
  # Secret (the password lives in the pre-created `postgres` Secret that helm
  # never renders), so a dry-run prints nothing sensitive today — the flag keeps
  # it that way if a Secret template were ever reintroduced. Dry-run output is
  # what gets pasted into tickets, chats and CI logs. helm lint above still
  # renders every template, and a real deploy re-reads the value from the
  # running container, so nothing that catches a broken Secret is lost.
  # --dry-run=client is the current spelling; bare --dry-run is deprecated in helm 4.
  # No `exec` here: replacing the shell skips the EXIT trap and leaves the 0600
  # rendered values file sitting in /tmp.
  helm upgrade --install "$RELEASE" . -n "$NAMESPACE" "${ARGS[@]}" \
    --dry-run=client --hide-secret
  exit $?
fi

# The local PV and the backup hostPath mounts need these directories before the
# first pod can schedule. setup.sh creates them with the right owners; a bare
# ./deploy.sh on a host that never ran setup.sh would install a release whose
# pods fail with a mount error, so fail here with the actionable fix instead.
for d in "$LIVE_DATA_PATH/postgresql" "$LIVE_DATA_PATH/postgresql-backups" \
         "$BACKUP_DATA_PATH/postgresql"; do
  [[ -d "$d" ]] || { echo "ERROR: $d does not exist. Run ./deploy/setup.sh first — it creates the host paths." >&2; exit 1; }
done
echo "helm upgrade --install $RELEASE -n $NAMESPACE (password from the pre-created $RELEASE Secret)"
helm upgrade --install "$RELEASE" . -n "$NAMESPACE" "${ARGS[@]}"

echo
echo "Waiting for the postgres rollout..."
kubectl rollout status deploy/"$RELEASE" -n "$NAMESPACE" --timeout=180s

echo "Verifying the database accepts the credential from the Secret:"
# Connect over the Service IP rather than 127.0.0.1. pg_hba.conf grants `trust` to
# 127.0.0.1/32 and ::1/128, so a loopback psql accepts ANY password, including an
# empty one, and this check would pass while every real client was being rejected.
# Reaching the Service from the pod keeps the source address off loopback, which
# matches the `host all all all scram-sha-256` rule and makes the password matter.
# The password is fed on stdin and the names are passed as positional args, so no
# credential ever appears in a command line or the node's process list.
# The password is read from the pre-created Secret, base64-decoded on the host,
# and fed on stdin — no credential in a command line, the process list, or .env.
secret_pw="$(kubectl get secret "$RELEASE" -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
printf '%s\n' "$secret_pw" | kubectl exec -i -n "$NAMESPACE" deploy/"$RELEASE" -- \
  sh -c 'read -r pw
         PGPASSWORD="$pw" exec psql -h "$3" -U "$1" -d "$2" -tAc \
           "select '"'"'auth ok, tables='"'"'||count(*) from information_schema.tables where table_schema='"'"'public'"'"';"' \
  sh "$POSTGRES_USER" "$POSTGRES_DB" "$RELEASE.$NAMESPACE.svc.cluster.local" | sed 's/^/  /'

echo "OK: $RELEASE deployed and reachable with the Secret credential."
