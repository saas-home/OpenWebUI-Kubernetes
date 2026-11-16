#!/usr/bin/env bash
# Layered smoke test for the whole stack: everything verifiable without a
# browser, cheapest checks first. Safe to run any time; it changes nothing
# except creating (and deleting) two manual backup jobs.
#
#   ./deploy/smoke-test.sh              # everything, including the backup jobs
#   ./deploy/smoke-test.sh --quick      # skip --dry-run and the backup jobs
#   ./deploy/smoke-test.sh --no-backup  # skip just the backup jobs
#
# Optional, unlocks the per-user API test (a chat completion as your user):
#
#   SMOKE_API_KEY=sk-... ./deploy/smoke-test.sh
#
# The key is read from the environment and handed to curl on stdin, never on
# a command line — the same rule the rest of the repo follows for credentials.
#
# Tiers:
#   1 scripts and charts   selftest, helm lint, chart render
#   2 config contract      deploy --check, secret-init --check, setup --check
#   3 cluster shape        pods, releases, PVC binding, the no-provisioner guard
#   4 app serving          /health, /health/db, version, inference reachability
#   5 app function         SearXNG results, and with SMOKE_API_KEY: /api/models
#                          and a real chat completion through /api/chat/completions
#   6 backups prove it     manual runs of both CronJobs, judged by their gate
#                          lines and the archives on disk, not job status alone
#
# Exit 0 = every check passed (warnings allowed and listed). Exit 1 = failures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
NAMESPACE=default

QUICK=0
NO_BACKUP=0
for arg in "$@"; do
  case "$arg" in
    --quick)     QUICK=1 ;;
    --no-backup) NO_BACKUP=1 ;;
    -h|--help)
      awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "${BASH_SOURCE[0]}" >&2
      exit 0 ;;
    *) echo "ERROR: unknown argument '$arg'." >&2; exit 2 ;;
  esac
done

PASS=0; WARNINGS=0; FAILURES=0
ok()   { PASS=$((PASS+1));   printf '  OK    %s\n' "$1"; }
warn() { WARNINGS=$((WARNINGS+1)); printf '  WARN  %s\n' "$1"; }
bad()  { FAILURES=$((FAILURES+1)); printf '  FAIL  %s\n' "$1" >&2; }
note() { printf  '  --    %s\n' "$1"; }
section() {
  echo
  echo "══════════════════════════════════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════════════════════════════════"
}

env_value() {
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | tr -d '\r'
}
expand_root() { # <raw> <default>
  local v="${1:-}"; v="${v:-$2}"; v="${v/#\~/$HOME}"; printf '%s' "${v%/}"
}

# Jobs created by tier 6 are always removed, even on abort; SMOKE_TMP (the
# chat-request body) likewise. Both are optional, so the guards stay :- .
JOBS=()
SMOKE_TMP=""
cleanup() {
  [[ -n "$SMOKE_TMP" ]] && rm -f "$SMOKE_TMP" 2>/dev/null || true
  (( ${#JOBS[@]} )) && kubectl delete job "${JOBS[@]}" -n "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

for tool in kubectl helm curl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required."; exit 1; }
done
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found."; exit 1; }

# ── 1. scripts and charts ─────────────────────────────────────────────────────
section "Tier 1 — scripts and charts"
st_out="$("$SCRIPT_DIR/selftest.sh" 2>&1 | tail -1)" || true
if grep -qE 'all [0-9]+ checks passed' <<<"$st_out"; then
  ok "selftest: $st_out"
else
  bad "selftest: $st_out"
fi

for chart in postgresql open-webui; do
  lint="$((cd "$SCRIPT_DIR/$chart" && helm lint .) 2>&1)" || true
  if grep -q '0 chart(s) failed' <<<"$lint"; then
    if grep -q '^\[WARNING\]' <<<"$lint"; then
      warn "helm lint $chart passed with warnings:"; grep '^\[WARNING\]' <<<"$lint" | sed 's/^/          /'
    else
      ok "helm lint $chart: 0 failures, no warnings"
    fi
  else
    bad "helm lint $chart failed:"; tail -5 <<<"$lint" | sed 's/^/          /'
  fi
done

if (( ! QUICK )); then
  if (cd "$SCRIPT_DIR" && ./deploy.sh --dry-run >/dev/null 2>&1); then
    ok "deploy.sh --dry-run renders both charts cleanly"
  else
    bad "deploy.sh --dry-run failed — run it by hand to see why"
  fi
fi

# ── 2. config and credential contract ─────────────────────────────────────────
section "Tier 2 — config and credential contract"
dc="$((cd "$SCRIPT_DIR" && ./deploy.sh --check) 2>&1)" || true
if grep -qE 'DRIFT|ERROR' <<<"$dc"; then
  bad "deploy.sh --check reports drift/errors:"; grep -E 'DRIFT|ERROR' <<<"$dc" | sed 's/^/          /'
else
  ok "deploy.sh --check: $(grep -c 'OK:' <<<"$dc") checks green, .env matches both releases"
fi
if si="$("$SCRIPT_DIR/secret-init.sh" --check 2>&1)" && grep -q 'secrets check passed' <<<"$si"; then
  ok "secret-init --check: live Secrets match the recorded fingerprints"
else
  bad "secret-init --check failed:"; tail -3 <<<"$si" | sed 's/^/          /'
fi
setup_out="$((cd "$SCRIPT_DIR" && ./setup.sh --check) 2>&1)" || true
if grep -qE '^  FAIL|TODO' <<<"$setup_out"; then
  bad "setup.sh --check reports blocking findings:"; grep -E '^  FAIL|TODO' <<<"$setup_out" | sed 's/^/          /'
else
  ok "setup.sh --check: prerequisites clean"
fi

# ── 3. cluster shape ──────────────────────────────────────────────────────────
section "Tier 3 — cluster shape"
if kubectl get -n "$NAMESPACE" svc >/dev/null 2>&1; then
  ok "cluster reachable"
else
  bad "cluster unreachable — everything below this line will fail"
fi

# The four workloads, by their pod-name prefixes.
for prefix in postgres- ai-open-webui-0 ai-open-webui-redis- ai-open-webui-searxng-; do
  line="$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep "^$prefix" | head -1)" || true
  if [[ -z "$line" ]]; then bad "no pod matching $prefix*"; continue; fi
  ready=$(awk '{print $2}' <<<"$line"); status=$(awk '{print $3}' <<<"$line"); restarts=$(awk '{print $4}' <<<"$line")
  if [[ "$ready" == "1/1" && "$status" == "Running" ]]; then
    if [[ "$restarts" != "0" ]]; then
      warn "$prefix pod is Running with $restarts restart(s) (one is the known first-start config-seed race; repeats are not normal)"
    else
      ok "$prefix pod 1/1 Running, 0 restarts"
    fi
  else
    bad "$prefix pod: $ready $status (restarts $restarts)"
  fi
done

for rel in postgres ai-open-webui; do
  if helm list -q -n "$NAMESPACE" 2>/dev/null | grep -qx "$rel"; then
    ok "helm release $rel exists"
  else
    bad "helm release $rel missing"
  fi
done

for pvc in postgres open-webui ai-open-webui-searxng; do
  ph="$(kubectl get pvc "$pvc" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing)"
  if [[ "$ph" == "Bound" ]]; then ok "PVC $pvc Bound"; else bad "PVC $pvc is $ph (expect Bound — check the node name and the host path)"; fi
done

# The silent-corruption guard: local-storage must stay a no-provisioner class.
prov="$(kubectl get sc local-storage -n "$NAMESPACE" -o jsonpath='{.provisioner}' 2>/dev/null || echo missing)"
if [[ "$prov" == "kubernetes.io/no-provisioner" ]]; then
  ok "StorageClass local-storage is no-provisioner, as designed"
else
  bad "StorageClass local-storage provisioner is '$prov' — a dynamic provisioner here would bind PVCs to the wrong disk, outside every backup"
fi

kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
  | sed 's/^/          image: /'

# ── 4. the app is serving ─────────────────────────────────────────────────────
section "Tier 4 — the app is serving"
NODE_PORT="$(kubectl get svc ai-open-webui -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
NODE_PORT="${NODE_PORT:-30000}"
BASE="http://localhost:${NODE_PORT}"
for path in /health /health/db; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE$path" || true)"
  if [[ "$code" == "200" ]]; then ok "GET $path -> 200"; else bad "GET $path -> $code (expect 200)"; fi
done

ver="$(curl -s --max-time 15 "$BASE/api/config" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)"
pin="$(awk '/^open-webui:/{f=1} f && /tag:/{gsub(/["v]/,"",$2); print $2; exit}' "$SCRIPT_DIR/open-webui/values.yaml")"
if [[ -z "$ver" ]]; then
  bad "/api/config did not return a version"
elif [[ "$ver" == "$pin" ]]; then
  ok "app version $ver matches the values.yaml pin"
else
  note "app version $ver, values.yaml pin v$pin — legitimate after a fresh-install float, not drift"
fi

INFER="$(env_value OPENAI_API_BASE_URL)"
if [[ -n "$INFER" ]]; then
  icode="$(kubectl exec -n "$NAMESPACE" statefulset/ai-open-webui -c open-webui -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${INFER%/}/models" 2>/dev/null || true)"
  if [[ "$icode" == "200" ]]; then ok "inference endpoint reachable from the app pod ($INFER)"
  else warn "inference ${INFER%/}/models returned '$icode' from inside the app pod"; fi
fi

# ── 5. app function ───────────────────────────────────────────────────────────
section "Tier 5 — app function"
SVC="$(kubectl get svc ai-open-webui-searxng -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
if [[ -z "$SVC" ]]; then
  bad "searxng service has no clusterIP"
else
  n="$(curl -s --max-time 20 "http://$SVC:8080/search?q=smoke&format=json" | python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("results",[])))' 2>/dev/null || echo 0)"
  if (( n > 0 )); then ok "SearXNG returned $n result(s)"; else warn "SearXNG returned 0 results (engine rate limits can cause this transiently)"; fi
fi

if [[ -n "${SMOKE_API_KEY:-}" ]]; then
  # The key goes to curl via a config file on stdin, the body via a 0600 temp
  # file — neither lands on a command line where `ps` could show it.
  SMOKE_TMP="$(mktemp "${TMPDIR:-/tmp}/owui-smoke.XXXXXX")"
  chmod 600 "$SMOKE_TMP"
  models="$(curl -s --max-time 30 -K - "$BASE/api/models" <<EOF 2>/dev/null || true
header = "Authorization: Bearer $SMOKE_API_KEY"
EOF
)"
  model="$(python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)["data"]
    print(d[0]["id"] if d else "")
except Exception:
    print("")' <<<"$models")"
  if [[ -z "$model" ]]; then
    bad "SMOKE_API_KEY did not list any models from $BASE/api/models (wrong key? user without model access?)"
  else
    note "chatting as the key's user with model: $model"
    python3 -c 'import json,sys
json.dump({"model": sys.argv[1],
           "messages": [{"role": "user", "content": "Reply with exactly: SMOKE-OK"}],
           "stream": False}, open(sys.argv[2], "w"))' "$model" "$SMOKE_TMP"
    reply="$(curl -s --max-time 90 -K - "$BASE/api/chat/completions" <<EOF 2>/dev/null || true
header = "Authorization: Bearer $SMOKE_API_KEY"
header = "Content-Type: application/json"
data = "@$SMOKE_TMP"
EOF
)"
    if grep -q '"choices"' <<<"$reply"; then
      ok "per-user API key completed a chat request end to end"
    else
      bad "chat completion failed: $(head -c 200 <<<"$reply")"
    fi
  fi
else
  note "set SMOKE_API_KEY=sk-... (any user's key from Settings -> API Keys) to test per-user API auth"
fi

WEBUI_URL="$(env_value WEBUI_URL)"
if [[ -n "$WEBUI_URL" && "$WEBUI_URL" == https* ]]; then
  pcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$WEBUI_URL/health" || true)"
  if [[ "$pcode" == "200" ]]; then ok "public URL serves /health ($WEBUI_URL)"; else bad "public /health -> $pcode — the reverse proxy is not forwarding to NodePort $NODE_PORT"; fi
  ws="$(curl -s -o /dev/null -w '%{http_code}' --http1.1 -H "Connection: Upgrade" -H "Upgrade: websocket" \
        -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
        --max-time 20 "$WEBUI_URL/ws/socket.io/?EIO=4&transport=websocket" || true)"
  if [[ "$ws" == "101" ]]; then ok "WebSocket upgrade through the proxy -> 101"; else bad "WebSocket upgrade -> $ws (expect 101; test with --http1.1 as this script does)"; fi
  if [[ -n "$(kubectl get secret ai-open-webui-secrets -n "$NAMESPACE" -o jsonpath='{.data.GOOGLE_CLIENT_ID}' 2>/dev/null)" ]]; then
    oc="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$WEBUI_URL/oauth/google/callback" || true)"
    if [[ "$oc" == "307" || "$oc" == "400" ]]; then ok "OAuth callback route reached ($oc)"; else bad "OAuth callback -> $oc (expect 307/400; 404 means the proxy rewrote the path)"; fi
  fi
else
  note "WEBUI_URL is not https — skipping the public proxy checks"
fi

# ── 6. backups prove themselves ───────────────────────────────────────────────
if (( QUICK || NO_BACKUP )); then
  section "Tier 6 — backups (skipped: --quick/--no-backup)"
else
  section "Tier 6 — backups prove themselves (gate lines, not job status)"
  BACKUP_ROOT="$(expand_root "$(env_value BACKUP_DATA_PATH)" "$HOME/.open-webui/backup-data")"
  stamp="$(date +%s)"

  j="smoke-pg-$stamp"; JOBS+=("$j")
  kubectl create job "$j" --from=cronjob/postgres-backup -n "$NAMESPACE" >/dev/null
  if kubectl wait --for=condition=complete "job/$j" -n "$NAMESPACE" --timeout=600s >/dev/null 2>&1; then
    logs="$(kubectl logs -n "$NAMESPACE" "job/$j" 2>/dev/null || true)"
    grep -q 'Restore verified' <<<"$logs" && ok "pg backup: restore-into-scratch verified" || bad "pg backup: no 'Restore verified' gate line"
    grep -q 'Second-disk copy' <<<"$logs" && ok "pg backup: second-disk copy written" || bad "pg backup: no 'Second-disk copy' gate line"
    newest="$(ls -1t "$BACKUP_ROOT/postgresql/"*.sql.gz 2>/dev/null | head -1 || true)"
    [[ -n "$newest" ]] && ok "pg backup: archive on disk ($(basename "$newest"))" || bad "pg backup: no archive under $BACKUP_ROOT/postgresql"
  else
    bad "pg backup job did not complete in 600s — read: kubectl logs job/$j -n $NAMESPACE"
    JOBS=("${JOBS[@]/$j/}")   # keep the failed job for post-mortem
  fi

  j="smoke-up-$stamp"; JOBS+=("$j")
  kubectl create job "$j" --from=cronjob/ai-open-webui-uploads-backup -n "$NAMESPACE" >/dev/null
  if kubectl wait --for=condition=complete "job/$j" -n "$NAMESPACE" --timeout=600s >/dev/null 2>&1; then
    logs="$(kubectl logs -n "$NAMESPACE" "job/$j" 2>/dev/null || true)"
    grep -q 'Uploads archive' <<<"$logs" && ok "uploads backup: archive verified (members + gzip + tar listing)" || bad "uploads backup: no 'Uploads archive' gate line"
    newest="$(ls -1t "$BACKUP_ROOT/open-webui/"*.tar.gz 2>/dev/null | head -1 || true)"
    [[ -n "$newest" ]] && ok "uploads backup: archive on disk ($(basename "$newest"))" || bad "uploads backup: no archive under $BACKUP_ROOT/open-webui"
  else
    bad "uploads backup job did not complete in 600s — read: kubectl logs job/$j -n $NAMESPACE"
    JOBS=("${JOBS[@]/$j/}")
  fi
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo
echo "══════════════════════════════════════════════════════════════════════"
printf '  smoke-test: %d passed, %d warning(s), %d failure(s)\n' "$PASS" "$WARNINGS" "$FAILURES"
echo "══════════════════════════════════════════════════════════════════════"
echo
echo "Not covered here (needs a browser): sign-in, streaming chat UI, document"
echo "upload + citation, and multi-user history privacy. See 'Check that it"
echo "works' in README.md for the three-minute manual pass."
(( FAILURES == 0 )) || exit 1
