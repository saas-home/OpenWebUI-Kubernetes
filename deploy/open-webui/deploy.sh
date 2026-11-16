#!/usr/bin/env bash
# Deploy the ai-open-webui release.
#
# Why this script exists: site values (node name, URLs, data roots, capacity) live
# in a single gitignored .env at the repository root — and no credential does.
# Credentials live in pre-created Kubernetes Secrets (deploy/secret-init.sh),
# encrypted at rest by K3s --secrets-encryption; the charts reference them by
# name, so helm neither renders nor rewrites them, and `helm get manifest` no
# longer prints any of them. This script verifies the Secrets exist and hold the
# required keys BEFORE helm runs: a missing credential fails here with the exact
# command that fixes it, not as CreateContainerConfigError after a rollout.
#
# This script always sources .env, refuses to run if it is missing, incomplete, or not
# gitignored, and passes the rendered secrets in a 0600 temp file that is deleted on
# exit. Nothing secret is ever written to a tracked path.
#
# Usage:
#   ./deploy.sh              # lint, then upgrade --install
#   ./deploy.sh --dry-run    # render the chart, change nothing on the cluster
#   ./deploy.sh --check      # report drift between .env and the live release
#
# An argument this script does not recognize is a hard error. The default path
# is a live deploy, so a mistyped --dry-run must not silently become one.
set -euo pipefail

cd "$(dirname "$0")"

RELEASE=ai-open-webui
NAMESPACE=default
# The upstream chart's fullname helper collapses to the release name itself when
# the release name contains the chart name ("ai-open-webui" contains
# "open-webui"), so the workload is NOT necessarily $RELEASE-open-webui. Derive
# it the way the chart does rather than assuming the suffixed form.
if [[ "$RELEASE" == *open-webui* ]]; then APP_WORKLOAD="$RELEASE"; else APP_WORKLOAD="$RELEASE-open-webui"; fi
# Two levels up from deploy/open-webui/ is the repository root, where .env lives.
REPO_ROOT="$(cd ../.. && pwd)"
ENV_FILE="$REPO_ROOT/.env"
ENV_EXAMPLE="$(cd ../.. && pwd)/.env.example"

# Variables this release cannot deploy without. The first three name machines
# rather than secrets — the node the local PVs pin to, the public URL, and the
# inference endpoint — and are here for the same reason as the credentials: they
# identify this installation, so they belong in the gitignored .env and never in
# a tracked values.yaml.
# No credential is a .env key any more: the database password, the session key,
# the Google pair and the Brave key all live in the pre-created Secrets and are
# entered through deploy/secret-init.sh. .env carries only site values.
REQUIRED_VARS=(
  K3S_NODE_NAME WEBUI_URL OPENAI_API_BASE_URL
  POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_USER
)
OPTIONAL_VARS=()

# manifest_check: recompute every fingerprint recorded in secrets.manifest
# (HMAC-SHA256 of the live Secret value under its stored salt) and fail loudly on
# any change. Read-only; the value never appears in output or on a command line.
# The manifest carries names, salts and hashes only — never a value.
manifest_check() {
  local ref salt expected m_secret m_key live actual drift=0
  while read -r ref salt expected || [[ -n "${ref:-}" ]]; do
    [[ -z "$ref" || "$ref" =~ ^[[:space:]]*# ]] && continue
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

# The pre-created Secrets this script depends on. The names are constants, not
# values: secret-init.sh creates exactly these, and the charts reference exactly
# these.
APP_SECRET_NAME="ai-open-webui-secrets"
SEARX_SECRET_NAME="ai-open-webui-searxng"

# Liveness of the credential contract, checked before helm runs (deploy AND
# --check paths, which both call gen_values). envFrom yields "" for a missing
# key rather than failing, so existence of the Secret alone proves nothing:
# every required key is checked by name.
require_secret() { # <secret> <key>...
  local name="$1"; shift
  if ! kubectl get secret "$name" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "ERROR: Secret $name does not exist in $NAMESPACE." >&2
    echo "       Create it with: ./deploy/secret-init.sh" >&2
    exit 1
  fi
  local k missing=()
  for k in "$@"; do
    [[ -n "$(kubectl get secret "$name" -n "$NAMESPACE" -o jsonpath="{.data.$k}" 2>/dev/null)" ]] \
      || missing+=("$k")
  done
  if (( ${#missing[@]} )); then
    echo "ERROR: Secret $name is missing key(s): ${missing[*]}." >&2
    echo "       Re-run: ./deploy/secret-init.sh" >&2
    exit 1
  fi
  echo "OK: Secret $name carries every required key."
}

# Optional site values with defaults. An empty or absent value means the
# documented default under $HOME; resolve_data_root turns every spelling into
# an absolute path, and gen_values injects the full paths into the chart.
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
  --check        compare .env against the live release; report drift
  --pinned       on a FRESH install (no such release on the cluster yet), deploy
                 the values.yaml pins instead of resolving the newest GA images

Credentials are NOT in .env: they live in pre-created Kubernetes Secrets,
entered once through deploy/secret-init.sh. The Google pair (both keys or
neither) enables Google sign-in and disables the built-in login form; the
first account to sign up becomes the admin.
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

# The app pod and its uploads backup job run as the user who invokes this script:
# gen_values injects os.getuid()/os.getgid() into podSecurityContext and the
# CronJob. Under sudo that is uid 0, and a pod with runAsNonRoot: true and
# runAsUser: 0 is rejected by the kubelet — the helm upgrade would succeed and
# leave a pod that never starts. A read-only --check/--dry-run as root is still
# allowed; it changes nothing and prints what the values would be.
if [[ "$MODE" == deploy && "$(id -u)" -eq 0 ]]; then
  echo "ERROR: run this as the user who owns the data tree, not root." >&2
  echo "       The app pod and its backup job run as the invoking user, so root" >&2
  echo "       would inject uid 0 and the kubelet would refuse to start the pod." >&2
  exit 1
fi

# ── .env handling ────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  echo "       Create it from the template and fill in real values:" >&2
  echo "         cp $ENV_EXAMPLE $ENV_FILE" >&2
  echo "         chmod 600 $ENV_FILE" >&2
  echo "         \${EDITOR:-vi} $ENV_FILE" >&2
  exit 1
fi

# A secrets file that git can see is a leak waiting to happen.
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
#  - Only REQUIRED_VARS and OPTIONAL_VARS are exported, after clearing them first,
#    so a credential can only ever come from .env (never from an inherited shell
#    variable), and a stray `RELEASE=` or `NAMESPACE=` line cannot retarget the
#    helm and kubectl calls below.
#  - Values are trimmed of CR and outer whitespace so this shell and the python
#    renderer, which strips, always compare the same bytes.
unset "${REQUIRED_VARS[@]}" "${OPTIONAL_VARS[@]}" "${PATH_VARS[@]}" "${SCALE_VARS[@]}"
while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
  [[ "$key" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${key// /}" ]] && continue
  key="${key//[[:space:]]/}"
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
  value="${value%$'\r'}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  for v in "${REQUIRED_VARS[@]}" "${OPTIONAL_VARS[@]}" "${PATH_VARS[@]}" "${SCALE_VARS[@]}"; do
    [[ "$key" == "$v" ]] && export "$key=$value"
  done
done < "$ENV_FILE"

# Validate before touching the cluster. A placeholder left in from .env.example is the
# most common mistake and would deploy broken credentials.
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

# Shape checks at deploy time, not just wizard time: the README documents
# hand-editing .env, which bypasses bootstrap-host.sh's validators. The DSN is
# URL-encoded so a password cannot corrupt it, but the identifiers, the host
# and the port are interpolated as-is. (The Brave key — expanded into
# settings.yml by the searxng init container, where a quote or newline would
# break the YAML — moved to deploy/secret-init.sh along with every other
# credential; its shape check lives there now.)
[[ "$POSTGRES_USER" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "ERROR: POSTGRES_USER '$POSTGRES_USER' must be letters, digits and underscores, starting with a letter or underscore." >&2; exit 1; }
[[ "$POSTGRES_DB"   =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "ERROR: POSTGRES_DB '$POSTGRES_DB' must be letters, digits and underscores, starting with a letter or underscore." >&2; exit 1; }
[[ "$POSTGRES_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "ERROR: POSTGRES_HOST '$POSTGRES_HOST' must be a plain hostname or IP." >&2; exit 1; }
[[ "$POSTGRES_PORT" =~ ^[0-9]+$ ]] || { echo "ERROR: POSTGRES_PORT '$POSTGRES_PORT' must be a number." >&2; exit 1; }

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

# The credential contract, checked where every path (deploy, --check) reaches:
# a missing Secret or key fails here with the fix, not after a rollout.
require_secret "$APP_SECRET_NAME" WEBUI_SECRET_KEY DATABASE_URL

# Google SSO mode comes from the pre-created Secret, not from .env — the pair
# moved out of the file. A client ID without a client secret (or the reverse) is
# a half-finished secret, not a mode: the app would advertise a Google button
# that fails on every click. Refuse here where the fix is one command.
GOOGLE_ID_LIVE="$(kubectl get secret "$APP_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.GOOGLE_CLIENT_ID}' 2>/dev/null || true)"
GOOGLE_SECRET_LIVE="$(kubectl get secret "$APP_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.GOOGLE_CLIENT_SECRET}' 2>/dev/null || true)"
if [[ -n "$GOOGLE_ID_LIVE" ]] && [[ -z "$GOOGLE_SECRET_LIVE" ]]; then
  echo "ERROR: the $APP_SECRET_NAME Secret has GOOGLE_CLIENT_ID but no GOOGLE_CLIENT_SECRET." >&2
  echo "       Re-run: ./deploy/secret-init.sh" >&2
  exit 1
fi
if [[ -z "$GOOGLE_ID_LIVE" ]] && [[ -n "$GOOGLE_SECRET_LIVE" ]]; then
  echo "ERROR: the $APP_SECRET_NAME Secret has GOOGLE_CLIENT_SECRET but no GOOGLE_CLIENT_ID." >&2
  echo "       Re-run: ./deploy/secret-init.sh" >&2
  exit 1
fi
if [[ -n "$GOOGLE_ID_LIVE" ]]; then
  GOOGLE_SSO=1
  echo "Auth mode: Google SSO (login form disabled)."
else
  GOOGLE_SSO=0
  echo "Auth mode: built-in login form (no Google SSO; the first account to sign up becomes admin)."
fi
# The python renderer reads the mode from the environment; the .env loader only
# exports its own key lists.
export GOOGLE_SSO

# Render the helm values from .env. JSON string quoting is valid YAML,
# so this needs no third-party yaml module, and it removes any chance of a value with
# a quote or newline breaking the file.
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
def opt(k):
    """An optional key: empty (or placeholder) means 'not configured'."""
    v = e.get(k, '').strip()
    return '' if v.startswith('CHANGE-ME') else v

def req_url(k):
    """A URL from .env, minus any trailing slash. A missing scheme is caught here
    rather than by the app: `WEBUI_URL=ai.example.com` makes OAuth build a
    redirect to the relative path `ai.example.com/oauth/google/callback`, which fails
    with an opaque Google error and no hint of the cause."""
    v = req(k).rstrip('/')
    if not v.startswith(('http://', 'https://')):
        raise SystemExit(f"ERROR: {k}={v!r} needs a scheme, e.g. https://{v}")
    return v

# The message-scale row selected by MESSAGE_SCALE, as key=value lines emitted by
# profile_block() in the shell above. Parsing that one block here — instead of
# repeating the numbers in Python — is what keeps the printed table, the gate
# that validated it and the rendered limits from ever disagreeing.
prof = dict(line.split('=', 1) for line in e['PROFILE_BLOCK'].splitlines() if '=' in line)

def res(pre):
    """One workload's requests/limits from the profile row."""
    return {'requests': {'cpu': prof[pre + '_cpu_req'],
                         'memory': prof[pre + '_mem_req']},
            'limits':   {'cpu': prof[pre + '_cpu_lim'],
                         'memory': prof[pre + '_mem_lim']}}

# No credential value is rendered: the Secrets are pre-created by
# deploy/secret-init.sh and referenced by name from the chart templates.
doc = {
    'searxng': {'persistence': {'nodeName': req('K3S_NODE_NAME'),
                                'localPath': req('LIVE_DATA_PATH') + '/searxng'}},
    'open-webui': {
        'openaiBaseApiUrl': req_url('OPENAI_API_BASE_URL'),
    },
    'uploadsBackup': {
        'sourcePath': req('LIVE_DATA_PATH') + '/open-webui',
        'hostPath': req('BACKUP_DATA_PATH') + '/open-webui',
        # The job runs as the deploying user so the archives it writes into the
        # backup root are owned by the same user as the rest of the tree.
        'runAsUser': os.getuid(),
        'runAsGroup': os.getgid(),
    },
}

# The app pod and its init containers run as the deploying user: the data
# directories on the host are created for that user by setup.sh, and running
# the container as root is what used to leave root-owned files inside a tree
# the operator owns. runAsNonRoot is the fail-visible guard, the same shape
# the postgres (uid 70) and SearXNG (uid 977) pods carry.
doc['open-webui']['podSecurityContext'] = {
    'runAsNonRoot': True,
    'runAsUser': os.getuid(),
    'runAsGroup': os.getgid(),
    'fsGroup': os.getgid(),
}
doc['open-webui']['containerSecurityContext'] = {
    'allowPrivilegeEscalation': False,
    'capabilities': {'drop': ['ALL']},
}

# Every CPU and memory limit in the stack comes from the profile row, so the
# numbers cannot drift apart from each other or from the database tuning the
# postgres script renders out of the same table. Helm merges maps per key, so
# these replace the values.yaml defaults without touching anything else.
doc['open-webui']['resources'] = res('app')
doc['searxng']['resources'] = res('searxng')
doc['open-webui']['websocket'] = {'redis': {'resources': res('redis')}}
doc['uploadsBackup']['resources'] = res('backup')

# SSO mode was read from the Secret in the shell above and exported here.

# Auth and cookie env vars arrive through commonEnvVars, not extraEnvVars:
# Helm replaces a list rather than merging into it, so the deploy cannot
# override a single entry in the extraEnvVars list of values.yaml — the whole
# list would have to be re-sent. These names therefore live HERE, and
# values.yaml deliberately omits them; a duplicate env name fails at the API
# server.
webui_url = req_url('WEBUI_URL')
secure = 'true' if webui_url.startswith('https://') else 'false'
doc['open-webui']['commonEnvVars'] = [
    {'name': 'WEBUI_URL', 'value': webui_url},
    # The app defaults CORS_ALLOW_ORIGIN to '*' and prints a startup warning that
    # this is not recommended for production. Pin it to this installation's own
    # public origin: the UI is same-origin, so nothing legitimate needs '*' and a
    # wildcard lets any page in the browser call the API with the session cookie.
    {'name': 'CORS_ALLOW_ORIGIN', 'value': webui_url},
    {'name': 'ENABLE_LOGIN_FORM', 'value': 'false' if e.get('GOOGLE_SSO') == '1' else 'true'},
    # Secure cookies are never sent over plain HTTP, so on an http:// WEBUI_URL
    # (no reverse proxy, no TLS) they must be false or login cannot persist.
    {'name': 'WEBUI_SESSION_COOKIE_SECURE', 'value': secure},
    {'name': 'WEBUI_AUTH_COOKIE_SECURE', 'value': secure},
    {'name': 'WEBUI_SESSION_COOKIE_SAME_SITE', 'value': 'lax'},
    # Concurrency is part of the envelope, not a hand-maintained number: workers,
    # pool size and overflow all move with MESSAGE_SCALE. They belong in this
    # generated list for the same reason WEBUI_URL does — Helm replaces a list
    # rather than merging into it, so a single entry cannot be overridden in
    # extraEnvVars, and a duplicate name fails at the API server.
    {'name': 'UVICORN_WORKERS', 'value': prof['workers']},
    {'name': 'DATABASE_POOL_SIZE', 'value': prof['pool_size']},
    {'name': 'DATABASE_POOL_MAX_OVERFLOW', 'value': prof['pool_overflow']},
]
with open(os.environ['GEN_FILE'], 'w') as f:
    json.dump(doc, f)
PY
  ARGS+=(-f "$GEN_VALUES")
}

ARGS=()

# charts/*.tgz are gitignored build artifacts, so a clean checkout has none and helm
# cannot lint, render or deploy without them. Regenerate before doing anything else.
# There is deliberately NO Chart.lock: every dependency version is an exact pin in
# Chart.yaml, so `helm dependency build` has nothing to re-resolve and no lock can
# drift out of sync behind an edited Chart.yaml (which is exactly how a stale lock
# once made ./deploy.sh refuse a correct deploy). selftest.sh guards the exact-pin
# policy the lock used to enforce by convention. build also refuses to add a missing
# repo on its own, so register every http(s) dependency declared in Chart.yaml first.
ensure_dependencies() {
  local name url
  while read -r name url; do
    [[ -z "$name" ]] && continue
    helm repo add "$name" "$url" --force-update >/dev/null
  done < <(awk '
    /^  - name:/       { gsub(/"/, "", $3); name = $3 }
    /^    repository:/ { url = $2; gsub(/["'\'']/, "", url)
                         if (url ~ /^https?:\/\//) print name, url }
  ' Chart.yaml)

  echo "helm dependency build (regenerating gitignored charts/*.tgz from the Chart.yaml pins)"
  helm dependency build .
  # `helm dependency build` also writes Chart.lock. This repo deliberately carries
  # none: Chart.yaml holds exact pins, so the lock adds nothing to resolve and would
  # only go stale behind an edited Chart.yaml. Delete it so the tree matches the
  # policy selftest.sh enforces, and so `git status` stays honest.
  rm -f Chart.lock
}

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
  echo "Comparing $ENV_FILE against the live release user-supplied values..."
  # "Cannot ask the cluster" and "release not installed" used to print the same line,
  # which sent people looking for a release nobody had deleted.
  if ! current=$(helm get values "$RELEASE" -n "$NAMESPACE" -o json 2>/dev/null); then
    echo "ERROR: cannot read the values of release $RELEASE in $NAMESPACE." >&2
    echo "       It was either never installed or the cluster is unreachable. Check:" >&2
    echo "         helm list -n $NAMESPACE" >&2
    exit 1
  fi
  [[ -n "$current" ]] || current='{}'
  # Render exactly what a deploy would write, then compare every credential by value.
  # Presence is not enough: a key rotated in .env and never deployed stays invisible
  # until the app fails to authenticate, which is how the last outage started. The DSN
  # formula stays in gen_values, so it lives in exactly one place. The live JSON comes
  # in on stdin and the rendered file by path: no credential ever reaches a command
  # line, and only key names are ever printed.
  gen_values
  drift=0
  drifted=$(printf '%s' "$current" | compare_release_values "$GEN_VALUES") || drifted_rc=$?
  drifted_rc=${drifted_rc:-0}
  case "$drifted_rc" in
    0) echo "OK: every key the deploy would write matches $ENV_FILE." ;;
    1) echo "DRIFT: the live release differs from $ENV_FILE for: $drifted" >&2
       echo "       Run ./deploy.sh to reconcile." >&2
       drift=1 ;;
    *) echo "ERROR: could not read the live values of release $RELEASE." >&2
       exit 1 ;;
  esac

  if [[ -f "$REPO_ROOT/secrets.manifest" ]]; then
    manifest_check || drift=1
  else
    echo "NOTE: no secrets.manifest — run ./deploy/secret-init.sh once to record fingerprints."
  fi
  exit "$drift"
fi

ensure_dependencies

# Select the version under the open-webui dependency by name. A bare `version:`
# match would pick up the searxng subchart entry, which is listed first. The
# quotes are stripped with tr rather than an awk gsub: the program lives inside
# single quotes, and an inner single quote is how this file got mangled once.
locked=$(awk '/^  - name: open-webui$/{f=1; next} f && /^    version:/{print $2; exit}' Chart.yaml | tr -d "\"'")

# Fresh-install policy (see deploy/postgresql/deploy.sh for the full rationale):
# no release on the cluster → float the four image pins to newest GA via --set;
# release exists, --pinned given, or a registry unreachable → the values.yaml
# pins, always with a printed line so no float happens silently. The chart
# version itself never floats: the exact version pin in Chart.yaml is what
# makes the build deterministic, so a newer GA chart is only reported, and
# taking it stays an explicit, reviewable one-line Chart.yaml edit.
if [[ "$MODE" != check ]] && (( ! USE_PINNED )) &&
   ! helm list -n "$NAMESPACE" -q 2>/dev/null | grep -qx "$RELEASE"; then
  echo "fresh install: resolving newest GA images from the registries (--pinned deploys the values.yaml pins)"

  ga_docker() { # <repo> <regex>: highest GA-looking semver tag, or empty
    curl -s --max-time 12 -H "User-Agent: openwebui-deploy/1.0" \
      "https://hub.docker.com/v2/repositories/$1/tags?page_size=100&ordering=last_updated" | \
      REGEX="$2" python3 -c '
import sys, json, re, os
try:
    tags = [t["name"] for t in json.load(sys.stdin)["results"]]
except Exception:
    raise SystemExit(0)
ga = [t for t in tags if re.fullmatch(os.environ["REGEX"], t)]
def v(t):
    m = re.match(r"v?(\d+)\.(\d+)(?:\.(\d+))?", t)
    return tuple(int(x or 0) for x in m.groups())
ga.sort(key=v, reverse=True)
print(ga[0] if ga else "")
' 2>/dev/null || true
  }

  set_image() { # <helm key> <label> <latest> <pinned>: --set only when newer
    if [[ -z "$3" ]]; then
      echo "  $2: registry unreachable; deploying the pinned $4"
    elif [[ "$3" == "$4" ]]; then
      echo "  $2: $4 is already the newest GA"
    else
      echo "  $2: $3 (values.yaml pins $4)"
      ARGS+=(--set "$1=$3")
    fi
  }

  pinned_of() { # <top-level values key to anchor on>: first tag: below it
    awk -v key="$1" '$0 ~ "^[[:space:]]*" key ":" {f=1; next} f && $1=="tag:" {gsub(/"/,"",$2); print $2; exit}' values.yaml
  }

  owui=$(curl -s --max-time 12 -H "User-Agent: openwebui-deploy/1.0" \
      "https://api.github.com/repos/open-webui/open-webui/releases?per_page=10" | \
    python3 -c '
import sys, json, re
try:
    rel = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for r in rel:
    if not r.get("prerelease") and re.fullmatch(r"v\d+\.\d+\.\d+", r.get("tag_name", "")):
        print(r["tag_name"])
        break
' 2>/dev/null || true)
  set_image open-webui.image.tag "open-webui" "$owui" "$(pinned_of open-webui)"
  # The db-migrate init container duplicates the app image inside
  # extraInitContainers (the chart renders that list verbatim), so it must float
  # with open-webui.image.tag: migrations have to run from the same build the
  # app then starts on. Same condition as set_image used above, so the two never
  # diverge.
  if [[ -n "$owui" && "$owui" != "$(pinned_of open-webui)" ]]; then
    ARGS+=(--set "open-webui.extraInitContainers[0].image=ghcr.io/open-webui/open-webui:$owui")
  fi

  set_image open-webui.websocket.redis.image.tag "redis" \
    "$(ga_docker library/redis '[0-9]+\.[0-9]+\.[0-9]+-alpine[0-9]+(\.[0-9]+)?')" \
    "$(pinned_of websocket)"

  # SearXNG publishes rolling date-sha tags and last_updated order is publish
  # order, so the first regex match is the build `latest` points at. Do NOT
  # re-sort these by date alone: several builds share a date and the newest
  # pushed is the current one.
  sx=$(curl -s --max-time 12 -H "User-Agent: openwebui-deploy/1.0" \
      "https://hub.docker.com/v2/repositories/searxng/searxng/tags?page_size=30&ordering=last_updated" | \
    python3 -c '
import sys, json, re
try:
    tags = [t["name"] for t in json.load(sys.stdin)["results"]]
except Exception:
    raise SystemExit(0)
for t in tags:
    if re.fullmatch(r"20\d{2}\.\d{1,2}\.\d{1,2}-[0-9a-f]{6,40}", t):
        print(t)
        break
' 2>/dev/null || true)
  set_image searxng.image.tag "searxng" "$sx" "$(pinned_of searxng)"

  set_image uploadsBackup.image.tag "uploads-backup base (alpine)" \
    "$(ga_docker library/alpine '[0-9]+\.[0-9]+\.[0-9]+')" \
    "$(pinned_of uploadsBackup)"

  ga_chart=$(curl -s --max-time 12 -H "User-Agent: openwebui-deploy/1.0" \
      "https://helm.openwebui.com/index.yaml" | \
    python3 -c '
import sys, re
best = None
for m in re.finditer(r"version: \x27?([0-9]+\.[0-9]+\.[0-9]+)\x27?\s*$", sys.stdin.read(), re.M):
    t = tuple(int(x) for x in m.group(1).split("."))
    if best is None or t > best:
        best = t
print(".".join(map(str, best)) if best else "")
' 2>/dev/null || true)
  if [[ -n "$ga_chart" && -n "$locked" && "$ga_chart" != "$locked" ]]; then
    echo "  chart: Chart.yaml pins open-webui $locked, newest GA is $ga_chart — take it by editing that version line; the next deploy pulls it"
  fi
fi

gen_values

# Lint once for both paths, the same shape deploy/postgresql/deploy.sh uses, so a
# dry-run reviews exactly the manifest a real deploy would produce.
echo "helm lint"
helm lint . "${ARGS[@]}"

if [[ "$MODE" == "dry-run" ]]; then
  echo
  echo "helm upgrade --dry-run=client --hide-secret"
  # --hide-secret is belt and braces: the charts no longer own credential
  # Secrets (credentials live in the pre-created ai-open-webui-secrets and
  # ai-open-webui-searxng Secrets that helm never renders), so a dry-run prints
  # nothing sensitive today — the flag keeps it that way if a Secret template
  # were ever reintroduced. Dry-run output is what gets pasted into tickets,
  # chats and CI logs. helm lint above still renders everything, and the deploy
  # path below re-reads every value from the running containers, so nothing that
  # catches a broken Secret is lost.
  # --dry-run=client is the current spelling; bare --dry-run is deprecated in helm 4.
  # No `exec` here: replacing the shell skips the EXIT trap and leaves the 0600
  # rendered values file sitting in /tmp.
  helm upgrade --install "$RELEASE" . -n "$NAMESPACE" "${ARGS[@]}" \
    --dry-run=client --hide-secret
  exit $?
fi

echo "Chart.yaml pins open-webui ${locked:-unknown}"
# The searxng PV and the uploads-backup hostPath mounts need these directories
# before the pods can schedule. setup.sh creates them with the right owners
# (uid 977 for searxng); a release installed without them fails at mount time,
# so fail here with the actionable fix instead.
for d in "$LIVE_DATA_PATH/searxng" "$LIVE_DATA_PATH/open-webui" \
         "$BACKUP_DATA_PATH/open-webui"; do
  [[ -d "$d" ]] || { echo "ERROR: $d does not exist. Run ./deploy/setup.sh first — it creates the host paths." >&2; exit 1; }
done
echo "helm upgrade --install $RELEASE -n $NAMESPACE (credentials from the pre-created Secrets)"
helm upgrade --install "$RELEASE" . -n "$NAMESPACE" "${ARGS[@]}"

echo
echo "Waiting for the searxng rollout (the init container rewrites settings.yml)..."
kubectl rollout status deploy/"$RELEASE"-searxng -n "$NAMESPACE" --timeout=180s

echo "Waiting for the open-webui rollout (probes gate readiness)..."
kubectl rollout status statefulset/"$APP_WORKLOAD" -n "$NAMESPACE" --timeout=600s

# The Brave key is optional: secret-init.sh only creates the Secret when a key
# was entered, and the chart's secretKeyRef is optional: true, so an absent
# Secret legitimately leaves `api_key: ""` in settings.yml. Verify only when the
# Secret exists; otherwise a no-Brave deploy would fail this check.
if kubectl get secret "$SEARX_SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Verifying the Brave key reached the pod..."
  # The init container writes `api_key: "$BRAVE_API_KEY"` and the shell expands
  # it at container start, so an unresolved secretKeyRef leaves the literal
  # `api_key: ""`. Read the file and inspect the value directly: kubectl exec
  # exits 1 for both "no match" and "could not run", so a bare grep -q would let
  # a failed exec pass as success.
  settings=$(kubectl exec -n "$NAMESPACE" deploy/"$RELEASE"-searxng -c searxng -- \
    cat /etc/searxng/settings.yml) || {
    echo "ERROR: could not read /etc/searxng/settings.yml from the searxng pod." >&2
    echo "       The deploy is not verified; check the pod before trusting it." >&2
    exit 1
  }
  brave_key_line=$(printf '%s\n' "$settings" | awk '
    /^[[:space:]]*- name: braveapi$/ { found = 1 }
    found && /api_key:/ { print; exit }
  ')
  if [[ -z "$brave_key_line" ]]; then
    echo "ERROR: no braveapi api_key line found in the running settings.yml." >&2
    exit 1
  fi
  if printf '%s' "$brave_key_line" | grep -qE 'api_key:[[:space:]]*["'"'"']?["'"'"']?[[:space:]]*$'; then
    echo "WARNING: braveapi api_key is empty in the running settings.yml." >&2
    echo "         The Secret exists but did not resolve into the pod." >&2
    exit 1
  fi
  echo "OK: braveapi has a key in the running settings.yml."
else
  echo "note: no $SEARX_SECRET_NAME Secret — Brave search not configured; skipping the braveapi check."
fi

echo "Verifying the Open WebUI credentials reached the container..."
# envFrom silently yields an empty string when a Secret key is missing, so check the
# values are present and non-empty rather than just checking the names exist.
# The Google keys are only in the Secret when SSO is configured, so only they are
# only checked when they are supposed to be there.
cred_list=(WEBUI_SECRET_KEY DATABASE_URL)
if (( GOOGLE_SSO )); then
  cred_list+=(GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET)
fi
kubectl exec -n "$NAMESPACE" statefulset/"$APP_WORKLOAD" -c open-webui -- \
  sh -c "for v in ${cred_list[*]}; do
           eval \"val=\\\$\$v\"
           if [ -z \"\$val\" ]; then echo \"EMPTY:\$v\"; exit 1; fi
         done; echo OK" || {
  echo "ERROR: an Open WebUI credential is empty in the running container." >&2
  echo "       Check the $APP_SECRET_NAME Secret: ./deploy/secret-init.sh --check" >&2
  exit 1
}
echo "OK: ${#cred_list[@]} expected credentials are non-empty in the container."

echo "Verifying the app answers:"
# Read the port off the live Service rather than repeating 30000 here: values.yaml
# owns the pin, and this is what k3s is actually listening on.
NODE_PORT=$(kubectl get svc "$APP_WORKLOAD" -n "$NAMESPACE" \
  -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
if [[ -z "$NODE_PORT" ]]; then
  echo "ERROR: Service $APP_WORKLOAD not found in $NAMESPACE." >&2
  exit 1
fi
# `curl -s` exits 0 for ANY HTTP status, so a plain -w '%{http_code}' probe prints
# 000 or 500 and lets the deploy declare success. Assert 200 on both endpoints and
# bound every request: an app that hangs must fail the script, not stall it.
check_http() {
  local path="$1" code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
         "http://localhost:${NODE_PORT}${path}") || {
    echo "ERROR: no answer from ${path} (curl exit $?; is NodePort ${NODE_PORT} listening?)." >&2
    exit 1
  }
  if [[ "$code" != "200" ]]; then
    echo "ERROR: GET ${path} -> ${code}, expected 200." >&2
    echo "       A pod can report 1/1 Running while the app is not serving (for" >&2
    echo "       example a database it cannot authenticate to). Check:" >&2
    echo "         kubectl logs -n $NAMESPACE statefulset/$APP_WORKLOAD" >&2
    exit 1
  fi
  echo "  GET ${path} -> ${code}"
}
check_http /health
check_http /health/db

version=$(curl -s --max-time 15 "http://localhost:${NODE_PORT}/api/config" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)
if [[ -z "$version" ]]; then
  echo "ERROR: /api/config returned no version; the app is not serving yet." >&2
  echo "       Check: kubectl logs -n $NAMESPACE statefulset/$APP_WORKLOAD" >&2
  exit 1
fi
echo "  version     -> ${version} (values.yaml pins open-webui.image.tag)"
