#!/usr/bin/env bash
# Self-test for the Open WebUI deployment scripts. No cluster, no helm, no
# kubectl required: it exercises the pure-shell logic that a mistake in .env
# actually hits — the data-root validators, the wizard's field validators, the
# deploy-time shape checks, the CronJob template injection guards, and the
# .env key wiring across the five files that must agree.
#
# Everything tested is EXTRACTED from the live scripts (never re-implemented
# here), so a regression in a deploy script fails this test. It was added after
# a pre-landing review found that a BACKUP_DATA_PATH like /x$(touch${IFS}/tmp/pwned)
# passed every check of its day and ran as root inside the nightly backup pod.
#
# Usage:  ./deploy/selftest.sh    (exit 0 = all pass; non-zero = failures listed)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1   # repo root: all paths below are repo-relative

pass=0 fail=0
ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1" >&2; }
section() { printf '\n== %s\n' "$1"; }

# extract <file> <first-line-substring> <last-line-substring> [n_lines_after_end]
# Prints the inclusive line range, optionally extended past the end marker.
# Fails loudly if the markers drift, so this file breaks the moment a refactor
# moves the code it tests — which is the point.
extract() {
  local file="$1" start="$2" end="$3" after="${4:-0}" s e
  s=$(grep -nF -m1 "$start" "$file" | head -1 | cut -d: -f1) || { echo "selftest: marker not found in $file: $start" >&2; exit 2; }
  e=$(grep -nF -m1 "$end" "$file" | head -1 | cut -d: -f1) || { echo "selftest: marker not found in $file: $end" >&2; exit 2; }
  e=$((e + after))
  (( s < e )) || { echo "selftest: markers out of order in $file" >&2; exit 2; }
  sed -n "${s},${e}p" "$file"
}

# ── 1. resolve_data_root (from deploy/postgresql/deploy.sh) ─────────────────
section "resolve_data_root"
# A function definition, so `exit 1` inside it only leaves the command
# substitution — callers observe it as a failed $( ...) and abort under set -e.
# +2 lines past the last validator line picks up the function's closing brace.
eval "$(extract deploy/postgresql/deploy.sh 'resolve_data_root()' '"${v%/}"' 1)"
export HOME="${TESTHOME:-/home/testuser}"
# The extracted function uses `exit 1` (it is meant for command substitution in
# the deploy scripts); call it inside $( ) so a rejected value fails the
# substitution, not this script.
check_ok() {
  if [[ "$(resolve_data_root "$1" "$HOME/.open-webui/live-data" LIVE_DATA_PATH 2>/dev/null; echo rc=$?)" == *"rc=0" ]]; then
    ok "accept: $2"
  else
    bad "should accept: $2"
  fi
}
check_err() {
  if [[ "$(resolve_data_root "$1" "$HOME/.open-webui/live-data" LIVE_DATA_PATH 2>/dev/null; echo rc=$?)" == *"rc=0" ]]; then
    bad "should reject: $2"
  else
    ok "reject: $2"
  fi
}
check_ok  "/mnt/apps_ssd" "plain path"
check_ok  "/data/open.webui-v2_x" "dots dashes underscores"
check_ok  "" "empty falls back to the default"
check_ok  "~/live" "tilde form"
check_err '/x$(touch${IFS}/tmp/selftest-pwned)' "command substitution, no spaces (the proven exploit)"
check_err '/x;id' "semicolon"
check_err '/x`id`' "backticks"
check_err '/x${Y}' "brace expansion"
check_err '/x y' "space"
check_err '/x"y' "double quote"
check_err "/x'y"  "single quote"
check_err 'relative/x' "relative path"
[[ ! -e /tmp/selftest-pwned ]] && ok "exploit left no side effect" || { rm -f /tmp/selftest-pwned; bad "exploit executed!"; }

# ── 2. wizard validators (from deploy/bootstrap-host.sh) ─────────────────────
# Site-value validators only: the credential validators (v_secret,
# v_session_key, v_google_id, v_brave_key) died with the credentials leaving
# .env — deploy/secret-init.sh owns those prompts now.
section "wizard validators"
eval "$(extract deploy/bootstrap-host.sh 'v_required()' 'v_ident()' 0)"
vok()  { if "$1" "${@:2}" >/dev/null 2>&1; then ok "$1 <$2> accepted"; else bad "$1 <$2> should accept"; fi; }
vbad() { if "$1" "${@:2}" >/dev/null 2>&1; then bad "$1 <$2> should reject"; else ok "$1 <$2> rejected"; fi; }
vok  v_path "/mnt/apps_ssd";  vbad v_path 'x/y';              vok v_path ""
vbad v_path '/x$(id)'
vok  v_ident "openwebui";     vbad v_ident 'u";x';             vbad v_ident "1abc"
vok  v_port "5432";           vbad v_port "0";                 vbad v_port "abc"
vok  v_node_name "my-ai-node"; vbad v_node_name "My Ai Node"
vok  v_webui_url "http://10.0.0.5:30000"; vbad v_webui_url "not a url"
# Capacity keys. The enum is the contract between .env and both deploy scripts:
# a fourth name here would render nothing and fall through to a default.
vok  v_scale "small"; vok v_scale "medium"; vok v_scale "large"
vbad v_scale "high"; vbad v_scale "SMALL"; vbad v_scale ""
vok  v_cores "4"; vok v_cores "32"; vbad v_cores "0"; vbad v_cores "4.5"; vbad v_cores "four"
vok  v_gb "8"; vok v_gb "1500"; vbad v_gb "0"; vbad v_gb "-8"; vbad v_gb "8G"

# ── 3. deploy-time shape checks (from deploy/open-webui/deploy.sh) ──────────
section "deploy-time identifier checks"
# These lines are inline in the script, not a function: extract and eval them
# with the variables set, mirroring how the deploy runs them after .env parsing.
checks_src=$(extract deploy/open-webui/deploy.sh \
  '# Shape checks at deploy time, not just wizard time' \
  "POSTGRES_PORT '\$POSTGRES_PORT' must be a number")
POSTGRES_BASE=(POSTGRES_USER=openwebui POSTGRES_DB=openwebui POSTGRES_HOST=postgres.default.svc.cluster.local POSTGRES_PORT=5432)
run_shape_wrap() { local k="$1" v="$2" want="$3" label="$4" out rc
  out=$( ( local pair; for pair in "${POSTGRES_BASE[@]}"; do export "$pair"; done
          export "$k=$v"; eval "$checks_src" ) 2>&1 ); rc=$?
  if [[ "$want" == ok && $rc -eq 0 ]]; then ok "accept: $label"
  elif [[ "$want" == err && $rc -ne 0 ]]; then ok "reject: $label"
  else bad "$label (expected $want, rc=$rc: ${out//$'\n'/ })"; fi; }
run_shape_wrap POSTGRES_USER 'a";x' err 'POSTGRES_USER with quote/semicolon'
run_shape_wrap POSTGRES_USER '1abc' err 'POSTGRES_USER starting with a digit'
run_shape_wrap POSTGRES_DB   'db;DROP' err 'POSTGRES_DB with semicolon'
run_shape_wrap POSTGRES_HOST 'a b.example' err 'POSTGRES_HOST with a space'
run_shape_wrap POSTGRES_PORT '5o32' err 'POSTGRES_PORT non-numeric'
run_shape_wrap POSTGRES_USER 'localai' ok 'a good extra-DB role'

# ── 4. CronJob templates: nothing .env-derived is interpolated into sh -c ───
section "backup CronJob injection guards"
guard_check() { # <file>
  local f="$1" body leaks
  if [[ ! -f "$f" ]]; then bad "$f: file missing"; return; fi
  body=$(awk '/args:/ {inb=1; next} inb && /^            (env|volumeMounts):/ {exit} inb' "$f")
  leaks=$(printf '%s\n' "$body" | grep -E '\{\{[^\}]*\.Values' | grep -vE '\{\{-? *(if|end|range|with)' || true)
  if [[ -z "$leaks" ]]; then ok "$f: sh -c body carries no .Values interpolation"
  else bad "$f: interpolated values leaked into the shell body: ${leaks//$'\n'/ }"; fi
  local opens closes
  opens=$(grep -o '{{' "$f" | wc -l); closes=$(grep -o '}}' "$f" | wc -l)
  if [[ "$opens" == "$closes" ]]; then ok "$f: template braces balanced ($opens)"
  else bad "$f: unbalanced template braces ($opens vs $closes)"; fi
}
guard_check deploy/postgresql/templates/backup-cronjob.yaml
guard_check deploy/open-webui/templates/uploads-backup-cronjob.yaml
grep -q 'retentionCount must be a plain integer' deploy/postgresql/templates/backup-cronjob.yaml \
  && ok "postgres: retentionCount numeric guard" || bad "postgres: retentionCount guard missing"
grep -q 'retentionCount must be a plain integer' deploy/open-webui/templates/uploads-backup-cronjob.yaml \
  && ok "uploads: retentionCount numeric guard" || bad "uploads: retentionCount guard missing"
grep -q 'name: OFFDISK_DIR' deploy/postgresql/templates/backup-cronjob.yaml \
  && ok "postgres: offdisk path arrives via env" || bad "postgres: OFFDISK_DIR env missing"
grep -q 'name: DEST_DIR' deploy/open-webui/templates/uploads-backup-cronjob.yaml \
  && ok "uploads: dest path arrives via env" || bad "uploads: DEST_DIR env missing"

# ── 4b. Postgres non-root posture ────────────────────────────────────────────
section "postgres runs without root"
# The point of these is the fail-visible chain: runAsNonRoot must stay set so
# removing runAsUser breaks the rollout instead of quietly restoring root, and
# setup.sh's HOST_PATHS must keep creating the three postgres directories for
# uid 70, not root.
for key in runAsNonRoot: true runAsUser: 70 runAsGroup: 70 fsGroup: 70; do
  n=$(grep -c "$key" deploy/postgresql/values.yaml || true)
  (( n >= 2 )) && ok "values.yaml sets $key (server + backup job)" \
               || bad "values.yaml: $key present only $n time(s); both the server pod and backup.podSecurityContext need it"
done
grep -q '.Values.podSecurityContext' deploy/postgresql/templates/deployment.yaml \
  && ok "deployment renders podSecurityContext" || bad "deployment.yaml does not render podSecurityContext"
grep -q '.Values.backup.podSecurityContext' deploy/postgresql/templates/backup-cronjob.yaml \
  && ok "backup cronjob renders podSecurityContext" || bad "backup-cronjob.yaml does not render podSecurityContext"
grep -q 'postgresql|70|70|' deploy/setup.sh \
  && ok "setup.sh creates the PGDATA dir for uid 70" || bad "setup.sh still creates postgres dirs for root while the pod is non-root"
grep -q 'postgresql-backups|70|70|' deploy/setup.sh \
  && ok "setup.sh creates the backups dir for uid 70" || bad "setup.sh backups dir owner mismatch"
grep -q 'fsGroup' deploy/postgresql/values.yaml \
  && ok "fsGroup present (hostPath group ownership at mount)" || bad "fsGroup missing — a non-root pod cannot write a root-owned hostPath"

# ── 4c. Open WebUI non-root posture ───────────────────────────────────────────
section "open-webui runs without root"
# The chain: setup.sh refuses to run as root (that is how the tree ended up
# root-owned before), it creates the data dirs for the deploying user, deploy.sh
# injects that user's uid into the app pod and the uploads CronJob, and the HF
# cache is pinned onto the data volume so the runtime embedding-model download
# works under a non-root pod.
grep -qF -- '$(id -u)" -eq 0' deploy/setup.sh \
  && ok "setup.sh refuses to run as root" || bad "setup.sh must refuse to run as root: that is how the data tree ends up root-owned"
grep -qF -- 'run this as the user who owns the data tree, not root' deploy/open-webui/deploy.sh \
  && ok "deploy.sh refuses a root deploy (uid 0 cannot back a runAsNonRoot pod)" || bad "deploy.sh would inject uid 0 under sudo and leave a pod the kubelet rejects"
grep -qF -- 'open-webui|$(id -u)|$(id -g)|' deploy/setup.sh \
  && ok "setup.sh creates the app data dir for the deploying user" || bad "setup.sh no longer creates the open-webui data dir for the deploying user"
grep -q 'podSecurityContext' deploy/open-webui/deploy.sh \
  && ok "deploy.sh injects the app podSecurityContext (deploying user's uid)" || bad "deploy.sh does not inject a podSecurityContext; the app pod would run as root"
grep -q 'containerSecurityContext' deploy/open-webui/deploy.sh \
  && ok "deploy.sh injects the container securityContext (caps dropped)" || bad "deploy.sh does not inject a containerSecurityContext"
grep -qF -- "'runAsUser': os.getuid()" deploy/open-webui/deploy.sh \
  && ok "deploy.sh injects the uploads backup uid/gid" || bad "deploy.sh does not inject uploadsBackup.runAsUser/runAsGroup"
grep -qF -- 'required "uploadsBackup.runAsUser' deploy/open-webui/templates/uploads-backup-cronjob.yaml \
  && ok "uploads CronJob refuses to render without a uid" || bad "uploads CronJob can render without runAsUser — archives would be root-owned"
grep -qF -- 'runAsNonRoot: true' deploy/open-webui/templates/uploads-backup-cronjob.yaml \
  && ok "uploads CronJob pins runAsNonRoot (fail-visible guard)" || bad "uploads CronJob is missing runAsNonRoot"
grep -q 'HF_HOME' deploy/open-webui/values.yaml \
  && ok "HF_HOME pins the embedding model cache on the data volume" || bad "HF_HOME missing: a non-root pod cannot write the default HF cache and first RAG use breaks"

# ── 4d. pip-preload trio: env vars and init container must agree ─────────────
section "runtime pip stays on the PVC"
# PIP_TARGET and PYTHONPATH must name the same directory, and the copyAppData
# override must install into the PVC-visible path and keep the upstream cp.
PIP_T=$(python3 -c "import yaml,re,sys; d=yaml.safe_load(open('deploy/open-webui/values.yaml')); ev=d['open-webui']['extraEnvVars']; print(next((e['value'] for e in ev if e['name']=='PIP_TARGET'),''))")
PIP_P=$(python3 -c "import yaml,re,sys; d=yaml.safe_load(open('deploy/open-webui/values.yaml')); ev=d['open-webui']['extraEnvVars']; print(next((e['value'] for e in ev if e['name']=='PYTHONPATH'),''))")
if [[ -n "$PIP_T" && "$PIP_T" == "$PIP_P" ]]; then ok "PIP_TARGET == PYTHONPATH ($PIP_T)"
else bad "PIP_TARGET ('$PIP_T') and PYTHONPATH ('$PIP_P') must be set and equal"; fi
if grep -q 'cp -R -n /app/backend/data/\* /tmp/app-data/' deploy/open-webui/values.yaml; then
  ok "copyAppData keeps the upstream copy step"
else bad "copyAppData override dropped the upstream cp — the init container would break app data seeding"; fi
if grep -q 'pip install --no-cache-dir --target /tmp/app-data/pip-extras' deploy/open-webui/values.yaml; then
  ok "copyAppData prewarms the PVC-visible path"
else bad "copyAppData does not install into /tmp/app-data/pip-extras (the PVC mount path of the same volume PIP_TARGET names)"; fi

# ── 4e. db-migrate init container stays on the app image ─────────────────────
section "db-migrate init container tracks the app pin"
# The chart renders extraInitContainers verbatim (no templating), so its image is
# a duplicate of open-webui.image.tag. When the pin moves, the init container
# would silently stay on the old image — a migration run against the old schema
# layout is exactly the divergence the init container is supposed to prevent.
MIG_TAG=$(python3 -c "import yaml; d=yaml.safe_load(open('deploy/open-webui/values.yaml')); tag=d['open-webui']['image']['tag']; img=next((c.get('image','') for c in (d['open-webui'].get('extraInitContainers') or []) if c.get('name')=='db-migrate'),''); print(tag if img.endswith(tag) else '')")
if [[ -n "$MIG_TAG" ]]; then ok "db-migrate init image ends in the app pin ($MIG_TAG)"
else bad "db-migrate init image does not track open-webui.image.tag"; fi
MIG_ON=$(python3 -c "import yaml; d=yaml.safe_load(open('deploy/open-webui/values.yaml')); print(next((e['value'] for e in d['open-webui']['extraEnvVars'] if e['name']=='ENABLE_DB_MIGRATIONS'),''))")
if [[ "$MIG_ON" == "false" ]]; then ok "workers skip auto-migration (ENABLE_DB_MIGRATIONS=false)"
else bad "ENABLE_DB_MIGRATIONS must be false: N workers racing alembic at import is the failure the init container removes"; fi

# ── 4f. exact pins replace Chart.lock ────────────────────────────────────────
section "dependency pins are exact (no Chart.lock)"
# The repo deliberately carries no Chart.lock: determinism comes from exact
# `version:` pins in Chart.yaml, which helm dependency build resolves with
# nothing to re-decide. Without the lock there is nothing to stop a loosened
# range from silently floating, so the exact-pin policy is enforced here.
if [[ -e deploy/open-webui/Chart.lock ]]; then
  bad "Chart.lock exists — the repo policy is no lock file (git rm it); Chart.yaml pins are the single source of truth"
else
  ok "Chart.lock absent, as designed"
fi
pin_out=$(python3 - <<'PY' 2>&1
import re, sys
s = open('deploy/open-webui/Chart.yaml').read()
deps = re.findall(r'^  - name: (\S+)\n    version: "?([^"\n]+)"?', s, re.M)
assert deps, "no dependencies parsed — this guard's regex went stale against a Chart.yaml reformat"
bad = [(n, v) for n, v in deps if not re.fullmatch(r'\d+\.\d+\.\d+', v)]
if bad:
    print("non-exact pins:", bad); sys.exit(1)
print("every Chart.yaml dependency pins an exact version: " + ", ".join(f"{n} {v}" for n, v in deps))
PY
)
if [[ $? == 0 ]]; then ok "$pin_out"; else bad "$pin_out"; fi

# ── 5. message-scale profile ─────────────────────────────────────────────────
section "message-scale profile"
# The table is duplicated in the two component scripts on purpose: each directory
# stays self-contained, with no cross-folder include. That makes this check the
# only thing keeping the two halves of the stack in agreement — a value edited in
# one copy and not the other would size the app and the database differently.
tbl_owui=$(extract deploy/open-webui/deploy.sh '# BEGIN PROFILE TABLE' '# END PROFILE TABLE')
tbl_pg=$(extract deploy/postgresql/deploy.sh '# BEGIN PROFILE TABLE' '# END PROFILE TABLE')
if [[ "$tbl_owui" == "$tbl_pg" ]]; then
  ok "the profile table is byte-identical in both component scripts"
else
  bad "the profile tables differ: $(diff <(printf '%s\n' "$tbl_owui") <(printf '%s\n' "$tbl_pg") | head -4 | tr '\n' ' ')"
fi
# Extract the real functions rather than re-implementing them.
eval "$tbl_owui"
eval "$(extract deploy/postgresql/deploy.sh 'load_profile()' 'done < <(profile_block "$1")' 1)"

to_mi() { # 4Gi | 256Mi | 1GB | 512MB -> MiB (MB is decimal, rounded down)
  case "$1" in
    *Gi) echo $(( ${1%Gi} * 1024 )) ;;
    *Mi) echo "${1%Mi}" ;;
    *GB) echo $(( ${1%GB} * 1024 )) ;;
    *MB) echo $(( ${1%MB} * 1000 / 1024 )) ;;
    *)   echo 0 ;;
  esac
}
to_milli() { # 500m -> 500, 2 -> 2000
  case "$1" in *m) echo "${1%m}" ;; *) echo $(( $1 * 1000 )) ;; esac
}

PROFILE_FIELDS="messages db_gb cpu ram_gb disk_gb workers pool_size pool_overflow
  max_connections app_cpu_req app_cpu_lim app_mem_req app_mem_lim pg_cpu_req pg_cpu_lim
  pg_mem_req pg_mem_lim shared_buffers effective_cache_size work_mem maintenance_work_mem
  max_wal_size searxng_cpu_req searxng_cpu_lim searxng_mem_req searxng_mem_lim
  redis_cpu_req redis_cpu_lim redis_mem_req redis_mem_lim backup_cpu_req backup_cpu_lim
  backup_mem_req backup_mem_lim"
for scale in small medium large; do
  load_profile "$scale"
  # Every field present and of the shape the renderer and Postgres both accept:
  # a memory value is <n>Mi/Gi/MB/GB, a CPU value is <n> or <n>m. A typo here
  # would otherwise reach a manifest as an invalid quantity and fail at the API.
  miss=""; badfmt=""
  for f in $PROFILE_FIELDS; do
    v="P_$f"; val="${!v:-}"
    [[ -n "$val" ]] || { miss+=" $f"; continue; }
    case "$f" in
      *mem_*)  [[ "$val" =~ ^[0-9]+(Mi|Gi|MB|GB)$ ]] || badfmt+=" $f=$val" ;;
      *cpu_*)  [[ "$val" =~ ^[0-9]+m?$ ]] || badfmt+=" $f=$val" ;;
    esac
  done
  [[ -z "$miss" ]] && ok "$scale: every profile field is present" \
                  || { bad "$scale: missing$miss"; continue; }
  [[ -z "$badfmt" ]] && ok "$scale: memory and CPU values are valid quantities" \
                     || bad "$scale: not a valid quantity:$badfmt"

  # The invariants that make the table coherent. These are the whole point of a
  # profile: the numbers are only safe as a set.
  ram_mi=$(( P_ram_gb * 1024 ))
  mem_lim=$(( $(to_mi "$P_app_mem_lim") + $(to_mi "$P_pg_mem_lim") + $(to_mi "$P_searxng_mem_lim") \
            + $(to_mi "$P_redis_mem_lim") + $(to_mi "$P_backup_mem_lim") ))
  mem_req=$(( $(to_mi "$P_app_mem_req") + $(to_mi "$P_pg_mem_req") + $(to_mi "$P_searxng_mem_req") \
            + $(to_mi "$P_redis_mem_req") + $(to_mi "$P_backup_mem_req") ))
  cpu_lim=$(( $(to_milli "$P_app_cpu_lim") + $(to_milli "$P_pg_cpu_lim") \
            + $(to_milli "$P_searxng_cpu_lim") + $(to_milli "$P_redis_cpu_lim") \
            + $(to_milli "$P_backup_cpu_lim") ))
  cpu_req=$(( $(to_milli "$P_app_cpu_req") + $(to_milli "$P_pg_cpu_req") \
            + $(to_milli "$P_searxng_cpu_req") + $(to_milli "$P_redis_cpu_req") \
            + $(to_milli "$P_backup_cpu_req") ))
  conns=$(( P_workers * (P_pool_size + P_pool_overflow) ))

  (( mem_lim <= ram_mi )) && ok "$scale: memory limits ${mem_lim}Mi fit ${P_ram_gb} GB" \
    || bad "$scale: memory limits ${mem_lim}Mi exceed ${P_ram_gb} GB"
  (( mem_req <= ram_mi )) && ok "$scale: memory requests ${mem_req}Mi fit ${P_ram_gb} GB" \
    || bad "$scale: memory requests ${mem_req}Mi exceed ${P_ram_gb} GB"
  (( cpu_lim <= P_cpu * 1000 )) && ok "$scale: CPU limits ${cpu_lim}m fit ${P_cpu} cores" \
    || bad "$scale: CPU limits ${cpu_lim}m exceed ${P_cpu} cores"
  (( cpu_req <= P_cpu * 1000 )) && ok "$scale: CPU requests ${cpu_req}m fit ${P_cpu} cores" \
    || bad "$scale: CPU requests ${cpu_req}m exceed ${P_cpu} cores"
  (( conns <= P_max_connections )) \
    && ok "$scale: $P_workers workers x 20 = $conns connections fit max_connections $P_max_connections" \
    || bad "$scale: $P_workers workers x 20 = $conns connections exceed max_connections $P_max_connections"
  (( $(to_mi "$P_effective_cache_size") < $(to_mi "$P_pg_mem_lim") )) \
    && ok "$scale: effective_cache_size $P_effective_cache_size fits the $P_pg_mem_lim database limit" \
    || bad "$scale: effective_cache_size $P_effective_cache_size is larger than the $P_pg_mem_lim database limit — a planner hint the cgroup can never honour"
  (( $(to_mi "$P_shared_buffers") < $(to_mi "$P_pg_mem_lim") )) \
    && ok "$scale: shared_buffers $P_shared_buffers fits the $P_pg_mem_lim database limit" \
    || bad "$scale: shared_buffers $P_shared_buffers does not fit the $P_pg_mem_lim database limit"
  # 20 kB per stored message is the measured cost, and disk must also hold a week
  # of compressed dumps (~3x the database) before uploads are counted.
  (( P_db_gb * 50000 >= P_messages )) \
    && ok "$scale: ${P_db_gb} GB database covers $P_messages messages at 20 kB each" \
    || bad "$scale: ${P_db_gb} GB database cannot hold $P_messages messages at 20 kB each"
  (( P_disk_gb >= P_db_gb * 3 )) \
    && ok "$scale: ${P_disk_gb} GB disk holds the database plus a week of dumps" \
    || bad "$scale: ${P_disk_gb} GB disk cannot hold a ${P_db_gb} GB database plus a week of compressed dumps"
done

# ── 6. .env key wiring across the files that must agree ─────────────────────
section ".env key consistency"
keys_check() {
  python3 - <<'PY'
import re, sys
example = set(re.findall(r'^([A-Z0-9_]+)=', open('.env.example').read(), re.M))
src = open('deploy/bootstrap-host.sh').read()
wizard = set(re.findall(r'ask_key ([A-Z0-9_]+)', src))
m = re.search(r'for key in (K3S_NODE_NAME[^;]+); do', src)
gate = {k for k in m.group(1).replace('\\', '').split()}
owui = open('deploy/open-webui/deploy.sh').read()
req = set(re.findall(r'[A-Z0-9_]+', re.search(r'REQUIRED_VARS=\(([^)]*)\)', owui).group(1)))
opt = set(re.findall(r'[A-Z0-9_]+', re.search(r'OPTIONAL_VARS=\(([^)]*)\)', owui).group(1)))
pv = set(re.findall(r'[A-Z0-9_]+', re.search(r'PATH_VARS=\(([^)]*)\)', owui).group(1)))
scale = set(re.findall(r'[A-Z0-9_]+', re.search(r'SCALE_VARS=\(([^)]*)\)', owui).group(1)))
pg = open('deploy/postgresql/deploy.sh').read()
pscale = set(re.findall(r'[A-Z0-9_]+', re.search(r'SCALE_VARS=\(([^)]*)\)', pg).group(1)))
setup = open('deploy/setup.sh').read()
sreq = set(re.findall(r'[A-Z0-9_]+', re.search(r'REQUIRED_KEYS=\(([^)]*)\)', setup).group(1)))
paths = {'LIVE_DATA_PATH', 'BACKUP_DATA_PATH'}
allk = req | opt | paths | scale
fails = []
if example != allk: fails.append(f".env.example {sorted(example ^ allk)}")
if wizard != allk: fails.append(f"wizard {sorted(wizard ^ allk)}")
if gate != req: fails.append(f"final gate {sorted(gate ^ req)}")
if sreq != req: fails.append(f"setup REQUIRED_KEYS {sorted(sreq ^ req)}")
if pv != paths: fails.append(f"PATH_VARS {sorted(pv ^ paths)}")
if pscale != scale: fails.append(f"postgres SCALE_VARS {sorted(pscale ^ scale)}")
# The credential keys left .env for good: none of these files may name one as
# a .env key. (WEBUI_SECRET_KEY, DATABASE_URL, password, brave-api-key and the
# GOOGLE_CLIENT_* names are Secret keys, not .env keys.)
CRED_ENV_KEYS = {'POSTGRES_PASSWORD', 'OPEN_WEBUI_SECRET_KEY', 'BRAVE_SEARCH_API_KEY'}
for label, keys in ((".env.example", example), ("wizard", wizard), ("final gate", gate),
                    ("open-webui REQUIRED_VARS", req), ("setup REQUIRED_KEYS", sreq)):
    hit = CRED_ENV_KEYS & keys
    if hit: fails.append(f"{label} still names .env credential keys {sorted(hit)}")
if fails:
    print("MISMATCH: " + "; ".join(fails)); sys.exit(1)
PY
}
if keys_check; then ok "example == wizard == gate == REQUIRED/OPTIONAL/PATH/SCALE_VARS; no credential is a .env key"
else bad ".env key wiring drifted between files"; fi

# ── 6a. credential architecture: Secrets hold the credentials, .env never does ─
section "credential Secrets architecture"
arc_ok()   { ok "$1"; }
arc_bad()  { bad "$1"; }
arc_grep() { # <want: found|absent> <pattern> <file...> <label>
  # Comment-only lines do not count: the checks assert what the code does, and
  # prose that explains the design names the same strings the design forbids.
  local want="$1" pat="$2"; shift 2
  local label="${!#}"
  local files=("${@:1:$#-1}")
  local hits=0 f n
  for f in "${files[@]}"; do
    # grep -c, not grep -q: -q exits on the first match, the upstream grep -v
    # then dies with SIGPIPE, and pipefail turns that match into a failure.
    n="$(grep -vE '^[[:space:]]*(#.*)?$' "$f" 2>/dev/null | grep -cE -- "$pat" || true)"
    [[ "${n:-0}" -gt 0 ]] && hits=1
  done
  if [[ "$want" == found && $hits -eq 1 ]]; then arc_ok "$label"
  elif [[ "$want" == absent && $hits -eq 0 ]]; then arc_ok "$label"
  else arc_bad "$label"; fi
}
# prompt_secret must print everything but the value to stderr: its stdout is
# captured into the value variable, so a prompt printed there would corrupt it.
si_prompts=$(awk '/^prompt_secret\(\) \{/{on=1} on{print} on && /^\}/{exit}' deploy/secret-init.sh)
if grep -q '>&2' <<<"$si_prompts"; then arc_ok "secret-init.sh prompts on stderr (stdout carries the value)"
else arc_bad "secret-init.sh prompts on stderr (stdout carries the value)"; fi

# A variable a component script references must be defined in that same script:
# --check once crashed on an undefined $REPO_ROOT (only the parent deploy.sh
# defined it), and set -u turned that into a failure that only surfaced once a
# live release existed to reach the manifest-drift code.
for f in deploy/open-webui/deploy.sh deploy/postgresql/deploy.sh deploy/deploy.sh; do
  if grep -qE '\$\{?REPO_ROOT\}?' "$f" && ! grep -q '^REPO_ROOT=' "$f"; then
    arc_bad "$f references \$REPO_ROOT but never defines it"
  else
    arc_ok "$f defines the \$REPO_ROOT it references"
  fi
done

# 1. The three chart-side secret templates are gone; the charts reference the
#    pre-created Secrets by name.
for f in deploy/open-webui/templates/secret.yaml deploy/postgresql/templates/secret.yaml \
         deploy/open-webui/charts/searxng/templates/secret.yaml; do
  if [[ -e "$f" ]]; then arc_bad "$f still exists (chart must not own a credential Secret)"; else arc_ok "$f removed"; fi
done
arc_grep found 'existingSecret: "postgres"' deploy/postgresql/values.yaml \
  "postgres chart references the pre-created Secret (auth.existingSecret)"
arc_grep found 'name: ai-open-webui-secrets' deploy/open-webui/values.yaml \
  "app chart pulls credentials from ai-open-webui-secrets (extraEnvFrom)"
arc_grep found 'existingSecret: "ai-open-webui-searxng"' deploy/open-webui/charts/searxng/values.yaml \
  "searxng chart references the pre-created Secret (existingSecret)"
arc_grep absent 'auth\.password' deploy/postgresql/values.yaml \
  "postgres values.yaml carries no password value"

# 2. No deploy script may pass a credential on a command line (--from-literal
#    lands in `ps` and shell history) or generate one into .env.
arc_grep absent '--from-literal' deploy/secret-init.sh deploy/backup.sh deploy/restore.sh \
  "Secrets are built with --from-file, never --from-literal"
arc_grep absent 'gen_secret.*set_env_key|set_env_key.*POSTGRES_PASSWORD' deploy/bootstrap-host.sh \
  "the wizard generates nothing into .env"
arc_grep absent 'POSTGRES_PASSWORD|OPEN_WEBUI_SECRET_KEY|BRAVE_SEARCH_API_KEY' \
  deploy/postgresql/deploy.sh \
  "postgres deploy.sh never touches a credential .env key"

# 3. SSO mode is read from the Secret, not from .env.
arc_grep found "GOOGLE_SSO.*export|export GOOGLE_SSO" deploy/open-webui/deploy.sh \
  "SSO mode reaches the renderer through GOOGLE_SSO"
arc_grep absent 'GOOGLE_CLIENT_ID:-' deploy/open-webui/deploy.sh \
  "login mode is not derived from a .env GOOGLE_CLIENT_ID"

# 4. secret-init.sh: fingerprints recorded only after apply.
apply_line="$(grep -n 'kubectl apply' deploy/secret-init.sh | head -1 | cut -d: -f1)"
record_line="$(grep -n 'record "\$PG_SECRET"' deploy/secret-init.sh | head -1 | cut -d: -f1)"
# Numeric compare: the string operator < would invert the verdict once the two
# line counts differ in digit length (e.g. 99 vs 100).
if [[ "$apply_line" =~ ^[0-9]+$ && "$record_line" =~ ^[0-9]+$ ]] && (( apply_line < record_line )); then
  arc_ok "fingerprints are recorded after the Secrets apply"
else
  arc_bad "fingerprints are recorded after the Secrets apply"
fi

# 5. backup/restore carry the credentials; uninstall purges the Secrets.
arc_grep found 'secrets\.env' deploy/backup.sh deploy/restore.sh \
  "backup and restore both handle the secrets.env bundle member"
arc_grep found 'ai-open-webui-secrets' deploy/uninstall.sh \
  "uninstall stage 2 deletes the credential Secrets"

# 6. setup.sh checks the Secrets in-cluster, not .env.
arc_grep found 'secret-init.sh' deploy/setup.sh \
  "setup.sh points missing credentials at secret-init.sh"
arc_grep found 'kubectl get secret' deploy/setup.sh \
  "setup.sh verifies the credential Secrets against the cluster"

# ── 6b. concurrency env vars live in exactly one place ───────────────────────
section "concurrency env vars are rendered, not duplicated"
# They moved out of extraEnvVars into the generated commonEnvVars, because the
# profile owns them now. A leftover copy in values.yaml would be a duplicate env
# name, which the API server rejects — and the failure only appears at deploy.
for name in UVICORN_WORKERS DATABASE_POOL_SIZE DATABASE_POOL_MAX_OVERFLOW; do
  if grep -q "name: $name\$" deploy/open-webui/values.yaml; then
    bad "$name is still in values.yaml extraEnvVars; the profile renders it into commonEnvVars and a duplicate name fails the deploy"
  elif grep -q "'name': '$name'" deploy/open-webui/deploy.sh; then
    ok "$name comes only from the profile (commonEnvVars)"
  else
    bad "$name is not rendered by deploy.sh; the app would run on the image default"
  fi
done

# ── report ────────────────────────────────────────────────────────────────────
echo
if (( fail )); then
  echo "selftest: $fail FAILURE(S), $pass passed" >&2
  exit 1
fi
echo "selftest: all $pass checks passed"
