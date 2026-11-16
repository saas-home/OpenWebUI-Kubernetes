#!/usr/bin/env bash
# Restore an encrypted backup bundle onto this server — the same stack,
# whether the deployment is absent, freshly bootstrapped, or still running
# (restoring over a running stack replaces its data).
#
#   ./deploy/restore.sh <bundle.tar.gz.gpg>
#   ./deploy/restore.sh <bundle.tar.gz.gpg> --passphrase-file FILE   # mode 600
#
# The bundle must have been made by ./deploy/backup.sh:
#   env.env, secrets.env, manifest.txt, db/<name>_<stamp>.sql.gz,
#   volumes/open-webui.tar.gz, volumes/searxng.tar.gz
#
# What it does, in order. The only confirmation is the bundle's passphrase —
# a wrong one never gets past step 1, and the bundle is the single source of
# truth for everything after it:
#   1. decrypt and verify the bundle (round-trip, same checks as backup.sh)
#   2. write the bundle's .env over the current one (the old one is kept as
#      .env.pre-restore_<stamp>; if the bundle's K3S_NODE_NAME differs from
#      this node's name, this node's name wins — local PVs pin it and the
#      field is immutable), then rebuild the credential Secrets from
#      secrets.env and install secrets.manifest
#   3. install the stack if it is absent (./deploy/setup.sh) or redeploy it if
#      it is present (./deploy/deploy.sh)
#   4. stop the app, recreate each database from its dump, extract the volumes
#   5. start the app and verify: /health, and the chat row count against the
#      manifest
#
# It will NOT: bootstrap the host. If K3s is not running, it stops and points
# at ./deploy/bootstrap-root.sh and ./deploy/bootstrap-host.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"


BUNDLE=""
PASS_FILE=""
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  arg="${args[i]}"
  case "$arg" in
    -h|--help)
      awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "${BASH_SOURCE[0]}" >&2
      exit 0
      ;;
    --passphrase-file)
      if (( i + 1 >= ${#args[@]} )); then echo "ERROR: --passphrase-file requires a value." >&2; exit 2; fi
      PASS_FILE="${args[i+1]}"; i=$(( i + 2 )); continue ;;
    --passphrase-file=*) PASS_FILE="${arg#--passphrase-file=}"; ;;
    -*) echo "ERROR: unknown argument '$arg'." >&2; exit 2 ;;
    *)
      if [[ -n "$BUNDLE" ]]; then echo "ERROR: one bundle only: '$BUNDLE' and '$arg'." >&2; exit 2; fi
      BUNDLE="$arg"
      ;;
  esac
  i=$(( i + 1 ))
done
[[ -n "$BUNDLE" ]] || { echo "Usage: ./deploy/restore.sh <bundle.tar.gz.gpg> [--passphrase-file FILE]" >&2; exit 2; }
[[ -f "$BUNDLE" ]] || { echo "ERROR: bundle not found: $BUNDLE" >&2; exit 1; }

ok()   { printf '  OK    %s\n' "$1"; }
note() { printf  '  --    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1" >&2; }
section() {
  echo
  echo "══════════════════════════════════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════════════════════════════════"
}

# ── decrypt + verify ──────────────────────────────────────────────────────────
section "Decrypting and verifying the bundle"
command -v gpg >/dev/null 2>&1 || { bad "gpg is not installed (apt install gnupg)."; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/owui-restore.XXXXXX")"
cleanup() { rm -rf "$TMP" 2>/dev/null || true; PASSPHRASE=""; }
trap cleanup EXIT

PASSPHRASE=""
if [[ -n "$PASS_FILE" ]]; then
  [[ -f "$PASS_FILE" && "$(stat -c '%a' "$PASS_FILE")" == 600 ]] \
    || { bad "--passphrase-file must be a regular file with mode 600."; exit 1; }
  PASSPHRASE="$(head -n1 "$PASS_FILE")"
else
  [[ -t 0 ]] || { bad "no terminal for the passphrase prompt; use --passphrase-file (mode 600) for scripted runs."; exit 1; }
  read -r -s -p '  Passphrase for the bundle: ' PASSPHRASE; echo
  [[ -n "$PASSPHRASE" ]] || { bad "empty passphrase."; exit 1; }
fi

gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 \
    --output "$TMP/bundle.tar.gz" "$BUNDLE" 3<<<"$PASSPHRASE" \
  || { bad "gpg could not open the bundle — wrong passphrase or corrupt file."; exit 1; }
tar xzf "$TMP/bundle.tar.gz" -C "$TMP"
[[ -f "$TMP/manifest.txt" && -f "$TMP/env.env" && -f "$TMP/secrets.env" ]] \
  || { bad "the bundle has no manifest.txt, env.env or secrets.env; it was not made by a current backup.sh."; exit 1; }
grep -q '^#secret postgres' "$TMP/secrets.env" || { bad "the bundle's secrets.env has no postgres section."; exit 1; }
grep -q '^#secret ai-open-webui-secrets' "$TMP/secrets.env" || { bad "the bundle's secrets.env has no ai-open-webui-secrets section."; exit 1; }
for f in "$TMP"/db/*.sql.gz; do
  [[ -e "$f" ]] || continue
  gzip -t "$f" || { bad "gzip integrity failed: $f"; exit 1; }
  gzip -dc "$f" | grep -q "PostgreSQL database dump complete" || { bad "missing dump trailer: $f"; exit 1; }
done
# `tar -tf`, not `tar -t`: without -f the path is a member name, not the archive.
tar -tf "$TMP/volumes/open-webui.tar.gz" >/dev/null || { bad "the open-webui volume archive will not extract."; exit 1; }
if [[ -f "$TMP/volumes/searxng.tar.gz" ]]; then
  tar -tf "$TMP/volumes/searxng.tar.gz" >/dev/null || { bad "the searxng archive will not list."; exit 1; }
fi
# If the bundle carries secrets.manifest, the credentials are proven bit-exact
# the same way backup.sh proved them before handing the bundle over.
if [[ -f "$TMP/secrets.manifest" ]]; then
  if ! python3 - "$TMP/secrets.env" "$TMP/secrets.manifest" <<'PYEOF'
import base64, hashlib, hmac, sys

secrets_file, manifest_file = sys.argv[1], sys.argv[2]
dumped = {}
name = None
for line in open(secrets_file):
    line = line.rstrip("\n")
    if line.startswith("#secret "):
        name = line[len("#secret "):]
        dumped[name] = {}
    elif line.strip() and name:
        key, b64 = line.split(" ", 1)
        dumped[name][key] = base64.b64decode(b64)

bad = 0
for line in open(manifest_file):
    line = line.strip()
    if not line:
        continue
    ref, salt, expected = line.split()
    sec, key = ref.split("/", 1)
    value = dumped.get(sec, {}).get(key)
    if value is None:
        print(f"FAIL: {ref} is in the manifest but not in the dumped secrets", file=sys.stderr)
        bad = 1
        continue
    actual = hmac.new(salt.encode("utf-8"), value, hashlib.sha256).hexdigest()
    if actual != expected:
        print(f"FAIL: {ref} does not match the fingerprint manifest", file=sys.stderr)
        bad = 1
sys.exit(1 if bad else 0)
PYEOF
  then
    bad "the bundle's credentials do not match its fingerprint manifest."
    exit 1
  fi
  ok "credentials verify against the bundle's fingerprint manifest"
fi
ok "the bundle verifies: $(ls "$TMP"/db/*.sql.gz 2>/dev/null | wc -l) database dump(s), volumes, env, secrets"

# ── read the bundle's site values ────────────────────────────────────────────
bund_env() { sed -n "s/^$1=//p" "$TMP/env.env" | tail -1 | tr -d '\r'; }
B_NODE="$(bund_env K3S_NODE_NAME)"
B_LIVE="$(bund_env LIVE_DATA_PATH)";  B_LIVE="${B_LIVE/#\~/$HOME}";  B_LIVE="${B_LIVE:-$HOME/.open-webui/live-data}"; B_LIVE="${B_LIVE%/}"
B_BACKUP="$(bund_env BACKUP_DATA_PATH)"; B_BACKUP="${B_BACKUP/#\~/$HOME}"; B_BACKUP="${B_BACKUP:-$HOME/.open-webui/backup-data}"; B_BACKUP="${B_BACKUP%/}"
B_PUSER="$(bund_env POSTGRES_USER)"; B_PDB="$(bund_env POSTGRES_DB)"
# Same bundle-trust guard as the dump file names below: B_PUSER is interpolated
# into the CREATE DATABASE ... OWNER statement, so both identifiers must be bare
# — the shape the deploy scripts already enforce on their side.
for id in "$B_PUSER" "$B_PDB"; do
  [[ "$id" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || { bad "the bundle's POSTGRES_USER/POSTGRES_DB value '$id' is not a plain identifier."; exit 1; }
done
CHAT_ROWS="$(grep -m1 '^chat rows:' "$TMP/manifest.txt" | awk '{print $3}' || true)"
note "bundle node : $B_NODE"
note "live root   : $B_LIVE"
note "backup root : $B_BACKUP"
note "database    : $B_PDB (role $B_PUSER), chat rows at backup time: ${CHAT_ROWS:-unknown}"

# A restore onto a running stack must use the roots the stack already uses:
# local PVs pin the paths and the field is immutable. Checked before step 1,
# because after the .env is replaced the deploy scripts refuse with a pointer
# to setup.sh — which cannot move an existing PV's path.
if command -v helm >/dev/null 2>&1 && helm list -q -n default 2>/dev/null | grep -qE '^(ai-open-webui|postgres)$' && [[ -f "$ENV_FILE" ]]; then
  cur_env() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | tr -d '\r'; }
  CUR_LIVE="$(cur_env LIVE_DATA_PATH)";  CUR_LIVE="${CUR_LIVE/#\~/$HOME}";  CUR_LIVE="${CUR_LIVE:-$HOME/.open-webui/live-data}"; CUR_LIVE="${CUR_LIVE%/}"
  CUR_BACKUP="$(cur_env BACKUP_DATA_PATH)"; CUR_BACKUP="${CUR_BACKUP/#\~/$HOME}"; CUR_BACKUP="${CUR_BACKUP:-$HOME/.open-webui/backup-data}"; CUR_BACKUP="${CUR_BACKUP%/}"
  if [[ "$CUR_LIVE" != "$B_LIVE" || "$CUR_BACKUP" != "$B_BACKUP" ]]; then
    bad "this host runs the stack under LIVE=$CUR_LIVE / BACKUP=$CUR_BACKUP,"
    bad "but the bundle was made under LIVE=$B_LIVE / BACKUP=$B_BACKUP."
    bad "Local PVs are immutable, so the roots cannot move. Restore onto a host"
    bad "without the releases, or make a fresh backup with this host's roots."
    exit 1
  fi
fi

# K3s must be running; this script deploys into it but never installs it.
# bootstrap-root.sh returns before the API server finishes booting, so an
# instant check misreads "still starting" as "not installed" — poll for up to
# two minutes before refusing.
if ! command -v kubectl >/dev/null 2>&1; then
  bad "kubectl not found — K3s is not installed. Bootstrap first:"
  echo "       sudo $SCRIPT_DIR/bootstrap-root.sh --node-name <name>"
  echo "       $SCRIPT_DIR/bootstrap-host.sh --node-name <name>"
  exit 1
fi
for _ in $(seq 1 24); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 5
done
if ! kubectl get nodes >/dev/null 2>&1; then
  bad "K3s is not answering (waited 120s). Bootstrap first:"
  echo "       sudo $SCRIPT_DIR/bootstrap-root.sh --node-name <name>"
  echo "       $SCRIPT_DIR/bootstrap-host.sh --node-name <name>"
  exit 1
fi
LOCAL_NODE="$(kubectl get nodes -o name | head -1 | sed 's|^node/||')"
NODE="$B_NODE"
if [[ "$LOCAL_NODE" != "$B_NODE" ]]; then
  note "this node is '$LOCAL_NODE' but the bundle was made on '$B_NODE'."
  note "Local PVs pin the node name and the field is immutable, so the bundle's"
  note "name would leave every volume Pending — only this node's name can be used."
  if [[ -t 0 ]]; then
    read -r -p "  Press Enter to restore under '$LOCAL_NODE' (anything else aborts): " ans
    [[ -z "$ans" ]] || { bad "aborted on request."; exit 1; }
  else
    note "no terminal; using $LOCAL_NODE"
  fi
  NODE="$LOCAL_NODE"
fi

# ── 1: .env ───────────────────────────────────────────────────────────────────
section "Step 1 — install the bundle's .env"
if [[ -f "$ENV_FILE" ]]; then
  keep="${ENV_FILE}.pre-restore_$(date +%Y%m%d_%H%M%S)"
  cp -p "$ENV_FILE" "$keep"
  note "replacing $ENV_FILE; the current one is kept as $keep"
else
  note "no current .env; a fresh one comes from the bundle"
fi
cp "$TMP/env.env" "$ENV_FILE"
chmod 600 "$ENV_FILE"
sed -i.bak "s/^K3S_NODE_NAME=.*/K3S_NODE_NAME=$NODE/" "$ENV_FILE"
rm -f "$ENV_FILE.bak"
# Keep the site values honest: the node name is the one local PVs pin.
ok ".env installed (K3S_NODE_NAME=$NODE)"

# The credentials: rebuild every Secret the bundle carries, before any deploy —
# setup.sh and both component deploy.sh scripts refuse to run without them.
# Values are decoded from base64 into 0600 temp files and handed to kubectl via
# --from-file, never --from-literal (argv is world-readable through `ps`).
section "Step 1b — rebuild the credential Secrets"
umask 077
restore_one_secret() { # <name>
  local name="$1" secfile key b64 valfile
  secfile="$TMP/.sec.$name"
  awk -v s="$name" '$0 == "#secret " s {on=1; next} /^#secret /{on=0} on && NF {print}' \
      "$TMP/secrets.env" > "$secfile"
  [[ -s "$secfile" ]] || { bad "no section for $name in secrets.env."; exit 1; }
  local args=()
  while read -r key b64; do
    valfile="$TMP/.val.$name.$key"
    printf '%s' "$b64" | base64 -d > "$valfile"
    chmod 600 "$valfile"
    args+=(--from-file="$key=$valfile")
  done < "$secfile"
  kubectl create secret generic "$name" -n default "${args[@]}" \
      --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null
  rm -f "$TMP/.val.$name."* "$secfile"
  ok "rebuilt Secret $name"
}
restore_one_secret postgres
restore_one_secret ai-open-webui-secrets
if grep -q '^#secret ai-open-webui-searxng' "$TMP/secrets.env"; then
  restore_one_secret ai-open-webui-searxng
else
  note "the bundle carries no ai-open-webui-searxng (no Brave key at backup time)"
fi
# The bundle's manifest describes the restored values: install it so
# --check keeps detecting drift against the credentials now in the cluster.
if [[ -f "$TMP/secrets.manifest" ]]; then
  cp "$TMP/secrets.manifest" "$REPO_ROOT/secrets.manifest"
  chmod 600 "$REPO_ROOT/secrets.manifest"
  ok "installed $REPO_ROOT/secrets.manifest"
fi

# ── 2: install or redeploy the stack ─────────────────────────────────────────
section "Step 2 — install / redeploy the stack"
if command -v helm >/dev/null 2>&1 && helm list -q -n default 2>/dev/null | grep -qE '^(ai-open-webui|postgres)$'; then
  note "releases exist — re-deploying, then restoring data over them"
  "$SCRIPT_DIR/deploy.sh"
else
  note "no releases found — running first-time setup (host paths, cluster objects, deploy)"
  "$SCRIPT_DIR/setup.sh"
fi
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n default --timeout=300s
ok "the stack is up"

# ── 3: stop the app so the volume is not written while it is replaced ───────
section "Step 3 — stop the app, restore the databases and volumes"
kubectl scale statefulset/ai-open-webui -n default --replicas=0
# --for=delete, not --for=condition=delete: the condition form never succeeds
# (it errors NotFound once the pod is gone), and `|| true` on it would have
# turned this gate into a no-op — the volume extract below would race the still
# running app. The component label, not app.kubernetes.io/name: the Redis pod
# carries name=open-webui too and never scales down.
if ! kubectl wait --for=delete pod -l app.kubernetes.io/component=open-webui -n default --timeout=120s; then
  bad "the app pod did not stop within 120s; refusing to replace the volume under a running app."
  echo "       Investigate (kubectl get pods -n default), then re-run." >&2
  exit 1
fi
ok "app stopped"

restored_dbs=()
for f in "$TMP"/db/*.sql.gz; do
  [[ -e "$f" ]] || continue
  # the name is <db>_<YYYYmmdd>_<HHMMSS>.sql.gz; strip the stamp
  db="$(basename "$f" | sed -E 's/_[0-9]{8}_[0-9]{6}\.sql\.gz$//')"
  # The name arrives inside a bundle. It is interpolated into the DROP/CREATE
  # below and used as a -d argument, so it must be a bare identifier: anything
  # else (quotes, semicolons, spaces) is a corrupt or hostile bundle.
  [[ "$db" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || { bad "unexpected database file name '$(basename "$f")' — refusing to run SQL from it."; exit 1; }
  # Two separate psql calls on purpose: a multi-statement -c arrives as one
  # implicit transaction, and DROP/CREATE DATABASE refuse to run inside one
  # ("cannot run inside a transaction block"), so the combined form never works.
  kubectl exec -i deploy/postgres -n default -- psql -U "$B_PUSER" -d postgres -c \
    "DROP DATABASE IF EXISTS $db;"
  kubectl exec -i deploy/postgres -n default -- psql -U "$B_PUSER" -d postgres -c \
    "CREATE DATABASE $db OWNER $B_PUSER;"
  gunzip -c "$f" | kubectl exec -i deploy/postgres -n default -- psql -U "$B_PUSER" -d "$db" -v ON_ERROR_STOP=1
  restored_dbs+=("$db")
  ok "restored $db"
done

tar xzf "$TMP/volumes/open-webui.tar.gz" -C "$B_LIVE/open-webui"
ok "extracted the open-webui volume to $B_LIVE/open-webui"
if [[ -f "$TMP/volumes/searxng.tar.gz" ]]; then
  searxng_pod="$(kubectl get pod -n default -o name 2>/dev/null | grep -i searxng | head -1 || true)"
  if [[ -n "$searxng_pod" ]]; then
    kubectl exec -i "${searxng_pod##*/}" -n default -c searxng -- tar xzf - -C /etc/searxng < "$TMP/volumes/searxng.tar.gz"
    ok "restored the SearXNG config (in-pod, so ownership stays uid 977)"
  else
    note "no SearXNG pod to restore into; its config regenerates on pod start"
  fi
fi

# ── 4: start and verify ───────────────────────────────────────────────────────
section "Step 4 — start the app and verify"
kubectl scale statefulset/ai-open-webui -n default --replicas=1
kubectl rollout status statefulset/ai-open-webui -n default --timeout=300s
NODE_PORT=$(kubectl get svc ai-open-webui -n default -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
NODE_PORT="${NODE_PORT:-30000}"
health="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "http://localhost:${NODE_PORT}/health")"
[[ "$health" == "200" ]] || { bad "/health returned $health, not 200."; exit 1; }
ok "/health: 200"
if [[ -n "$CHAT_ROWS" && "$CHAT_ROWS" != "unknown" ]]; then
  now="$(kubectl exec -i deploy/postgres -n default -- psql -U "$B_PUSER" -d "$B_PDB" -tAc 'select count(*) from chat' | tr -d '[:space:]')"
  if [[ "$now" == "$CHAT_ROWS" ]]; then
    ok "chat rows: $now (matches the manifest)"
  else
    bad "chat rows: $now, but the manifest says $CHAT_ROWS — investigate before trusting the restore."
    exit 1
  fi
fi
echo
echo "OK: restore complete."
echo "     databases restored: ${restored_dbs[*]:-none}"
echo "     volume:            $B_LIVE/open-webui"
echo "     the bundle still holds the only complete copy — keep it until you are sure."
