#!/usr/bin/env bash
# Portable, encrypted backup of the whole Open WebUI deployment.
#
#   ./deploy/backup.sh [--dest DIR]
#   ./deploy/backup.sh [--dest DIR] --passphrase-file FILE
#
# The bundle (after decryption with the passphrase) contains everything a new
# server needs to run the same deployment:
#   env.env                       the full .env (site values only, no credentials)
#   secrets.env                   every credential Secret, base64 per key under a
#                                 "#secret <name>" header — the durable copy of
#                                 the credentials, restore.sh rebuilds from it
#   secrets.manifest              the HMAC fingerprints secret-init.sh recorded
#                                 (used to prove the dump round-trips bit-exact)
#   manifest.txt                  versions, node name, row counts, restore notes
#   db/<name>_<stamp>.sql.gz      one pg_dump per user database
#   volumes/open-webui.tar.gz     the whole open-webui volume (uploads, vector_db, cache)
#   volumes/searxng.tar.gz        the SearXNG config and state
#
# Output: <dest>/open-webui-backup_<stamp>.tar.gz.gpg — GPG symmetric AES256.
# dest defaults to $HOME. dest must exist and must NOT be under LIVE_DATA_PATH
# (a backup inside the live data tree dies with the tree).
#
# The passphrase is entered twice at a hidden prompt by default.
# --passphrase-file reads it from a mode-0600 file for scripted runs; it is
# never printed and never appears on a command line.
#
# Before the bundle is handed over it is verified: it is decrypted again with
# the passphrase into a throwaway directory and every member is checked
# (dump trailer, gzip integrity, tar listing, manifest keys). A bundle that
# does not verify is deleted, and so is the throwaway directory on exit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

DEST=""
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
    --dest)
      if (( i + 1 >= ${#args[@]} )); then echo "ERROR: --dest requires a value." >&2; exit 2; fi
      DEST="${args[i+1]}"; i=$(( i + 2 )); continue ;;
    --dest=*)  DEST="${arg#--dest=}"; ;;
    --passphrase-file)
      if (( i + 1 >= ${#args[@]} )); then echo "ERROR: --passphrase-file requires a value." >&2; exit 2; fi
      PASS_FILE="${args[i+1]}"; i=$(( i + 2 )); continue ;;
    --passphrase-file=*) PASS_FILE="${arg#--passphrase-file=}"; ;;
    *) echo "ERROR: unknown argument '$arg'." >&2; exit 2 ;;
  esac
  i=$(( i + 1 ))
done
DEST="${DEST:-$HOME}"

ok()   { printf '  OK    %s\n' "$1"; }
note() { printf  '  --    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1" >&2; }
section() {
  echo
  echo "══════════════════════════════════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════════════════════════════════"
}

# ── preflight ─────────────────────────────────────────────────────────────────
section "Backup preflight"
command -v gpg  >/dev/null 2>&1 || { bad "gpg is not installed (apt install gnupg)."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { bad "kubectl not found; the stack must be reachable."; exit 1; }
command -v openssl >/dev/null 2>&1 || { bad "openssl is not installed but is required to fingerprint the Secrets."; exit 1; }
[[ -f "$ENV_FILE" ]] || { bad "$ENV_FILE not found; nothing to back up."; exit 1; }
[[ -d "$DEST" ]] || { bad "destination $DEST does not exist."; exit 1; }

env_value() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | tr -d '\r'; }
LIVE_PATH="$(env_value LIVE_DATA_PATH)"; LIVE_PATH="${LIVE_PATH/#\~/$HOME}"; LIVE_PATH="${LIVE_PATH:-$HOME/.open-webui/live-data}"
if [[ "$DEST" == "$LIVE_PATH" || "$DEST" == "$LIVE_PATH"/* ]]; then
  bad "destination $DEST is under the live data root $LIVE_PATH; a backup must live elsewhere."
  exit 1
fi

# The postgres pod must be answering: the dump is the part that cannot be
# reconstructed from anything else. Prefer the chart's label; fall back to any
# running pod whose name says postgres. (kubectl get -l exits 0 on zero
# matches, so the empty-variable check below is the real selector.)
PG_POD="$(kubectl get pod -n default -l app.kubernetes.io/name=postgresql -o name 2>/dev/null | head -1 || true)"
if [[ -z "$PG_POD" ]]; then
  PG_POD="$(kubectl get pod -n default --field-selector=status.phase=Running -o name 2>/dev/null | grep -i postgres | head -1 || true)"
fi
[[ -n "$PG_POD" ]] || { bad "could not find a running postgres pod."; exit 1; }
note "postgres pod: ${PG_POD##*/}"
[[ -d "$LIVE_PATH/open-webui" ]] || { bad "$LIVE_PATH/open-webui does not exist; is this the right LIVE_DATA_PATH?"; exit 1; }
ok "preflight complete"

# ── passphrase ────────────────────────────────────────────────────────────────
PASSPHRASE=""
get_passphrase() {
  if [[ -n "$PASS_FILE" ]]; then
    # Same strict check as restore.sh: mode exactly 600. (A 644 file would pass
    # a looser "not group/other-writable" test while still being world-readable.)
    [[ -f "$PASS_FILE" && "$(stat -c '%a' "$PASS_FILE")" == 600 ]] \
      || { bad "--passphrase-file must be a regular file with mode 600 (got $(stat -c '%a' "$PASS_FILE" 2>/dev/null || echo '?'))."; exit 1; }
    PASSPHRASE="$(head -n1 "$PASS_FILE")"
  else
    [[ -t 0 ]] || { bad "no terminal for the passphrase prompt; use --passphrase-file (mode 600) for scripted runs."; exit 1; }
    read -r -s -p '  Backup passphrase:         ' PASSPHRASE; echo
    read -r -s -p '  Backup passphrase (again): ' PASSPHRASE2; echo
    [[ -n "$PASSPHRASE" ]] || { bad "empty passphrase."; exit 1; }
    [[ "$PASSPHRASE" == "$PASSPHRASE2" ]] || { bad "the two passphrases differ."; exit 1; }
  fi
  [[ ${#PASSPHRASE} -ge 8 ]] || { bad "passphrase must be at least 8 characters."; exit 1; }
}

# ── staging + cleanup ─────────────────────────────────────────────────────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/owui-backup.XXXXXX")"
VTMP=""
BUNDLE_OUT=""
VERIFIED=0
cleanup() {
  if (( ! VERIFIED )) && [[ -n "$BUNDLE_OUT" && -f "$BUNDLE_OUT" ]]; then
    rm -f "$BUNDLE_OUT" 2>/dev/null || true
  fi
  [[ -n "$VTMP" ]] && rm -rf "$VTMP" 2>/dev/null || true
  rm -rf "$TMP" 2>/dev/null || true

  PASSPHRASE=""
}
trap cleanup EXIT

section "Creating the bundle"
get_passphrase
ok "passphrase accepted"
mkdir -p "$TMP/db" "$TMP/volumes"

# .env (site values only — the credentials left the file)
cp "$ENV_FILE" "$TMP/env.env"
chmod 600 "$TMP/env.env"
ok "copied .env"

# Every credential lives in one of three pre-created Secrets. Dump each key's
# value base64-encoded under a "#secret <name>" header, so any byte (newline,
# quote, control char) survives the tar+gpg round trip and restore.sh can
# rebuild the Secret bit-exact without guessing at delimiters. A missing
# ai-open-webui-searxng is a supported state (no Brave key), not a failure;
# a missing postgres or ai-open-webui-secrets is, because both the database
# pod and the app pod refuse to boot without them.
umask 077
: > "$TMP/secrets.env"
dump_secret() { # <name> <required:0|1>
  local name="$1" required="$2"
  if ! kubectl get secret "$name" -n default -o jsonpath='{.data}' >/dev/null 2>&1; then
    if (( required )); then
      bad "Secret $name does not exist in default — the stack cannot run without it."
      exit 1
    fi
    note "Secret $name not created (optional); skipped"
    return 0
  fi
  printf '#secret %s\n' "$name" >> "$TMP/secrets.env"
  kubectl get secret "$name" -n default -o jsonpath='{.data}' 2>/dev/null | python3 -c '
import json, sys
for k, v in json.load(sys.stdin).items():
    print(f"{k} {v}")
' >> "$TMP/secrets.env"
  ok "dumped Secret $name"
}
dump_secret postgres 1
dump_secret ai-open-webui-secrets 1
dump_secret ai-open-webui-searxng 0
[[ -s "$TMP/secrets.env" ]] || { bad "no Secret was dumped."; exit 1; }

# The fingerprint manifest travels with the bundle so the verify step below can
# prove the dumped values are the live ones, and so a restored server keeps
# drift detection working. A missing manifest is noted, not fatal.
MANIFEST_IN_BUNDLE=""
if [[ -f "$REPO_ROOT/secrets.manifest" ]]; then
  cp "$REPO_ROOT/secrets.manifest" "$TMP/secrets.manifest"
  chmod 600 "$TMP/secrets.manifest"
  MANIFEST_IN_BUNDLE=1
else
  note "no $REPO_ROOT/secrets.manifest — run ./deploy/secret-init.sh --check once; the bundle will still restore, without fingerprint proof"
fi

# database dumps: every non-template user database, one archive each
stamp="$(date +%Y%m%d_%H%M%S)"
# No whitespace-stripping tr here: it would concatenate every name into one
# token (openwebui\nlocalai -> openwebuilocalai) and the loop below would try
# to dump a database that does not exist. psql prints one name per line and
# the for-loop's word splitting already separates them.
dbs="$(kubectl exec -i "${PG_POD##*/}" -n default -- psql -U "$(env_value POSTGRES_USER)" -d postgres -tAc \
  "select datname from pg_database where datistemplate = false and datname not in ('postgres')")" \
  || { bad "could not list the user databases from the postgres pod."; exit 1; }
[[ -n "$dbs" ]] || { bad "no user databases found to dump."; exit 1; }
db_manifest=""
chat_rows=""
for db in $dbs; do
  out="$TMP/db/${db}_${stamp}.sql.gz"
  # Capture pg_dump's stderr: with pipefail a failed dump would otherwise exit
  # the script with a bare code and no message.
  if ! kubectl exec -i "${PG_POD##*/}" -n default -- pg_dump -U "$(env_value POSTGRES_USER)" -d "$db" 2>"$TMP/pg_dump.err" | gzip > "$out"; then
    bad "the dump of $db failed:"
    sed 's/^/    /' "$TMP/pg_dump.err" >&2
    exit 1
  fi
  # Same two gates as the nightly job: non-empty and the dump-complete trailer.
  [[ -s "$out" ]] || { bad "dump for $db is empty."; exit 1; }
  # pg_dump appends a `-- PostgreSQL database dump complete` comment plus an
  # \unrestrict token and trailing blank lines, so grep the whole dump (the same
  # gate as the nightly CronJob), never tail -1.
  gzip -dc "$out" | grep -q "PostgreSQL database dump complete" || { bad "dump for $db is missing its trailer."; exit 1; }
  db_manifest+="  db: ${db}_${stamp}.sql.gz"
  # Row count for the manifest (restore verifies it); chat is the app's core table.
  if [[ "$db" == "$(env_value POSTGRES_DB)" ]]; then
    chat_rows="$(kubectl exec -i "${PG_POD##*/}" -n default -- psql -U "$(env_value POSTGRES_USER)" -d "$db" -tAc "select count(*) from chat" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  ok "dumped database $db"
done

# volumes
tar czf "$TMP/volumes/open-webui.tar.gz" -C "$LIVE_PATH/open-webui" .
ok "archived the open-webui volume"
searxng_pod="$(kubectl get pod -n default -o name 2>/dev/null | grep -i searxng | head -1 || true)"
if [[ -n "$searxng_pod" ]]; then
  kubectl exec -i "${searxng_pod##*/}" -n default -c searxng -- tar czf - -C /etc/searxng . > "$TMP/volumes/searxng.tar.gz"
  ok "archived the SearXNG config"
else
  note "no running SearXNG pod; the bundle has no SearXNG archive (its config regenerates on pod start)"
fi

# manifest: what this bundle is, where it came from, and how to check it back
# The chart version that matters is the pinned open-webui subchart, not the
# root umbrella chart's own version.
chart_ver="$(awk '/^  - name: open-webui$/{f=1} f && /version:/{gsub(/"/,"",$2); print $2; exit}' "$REPO_ROOT/deploy/open-webui/Chart.yaml")"
app_ver="$(awk '/^open-webui:/{f=1} f && /tag:/{gsub(/"/,"",$2); print $2; exit}' "$REPO_ROOT/deploy/open-webui/values.yaml")"
pg_ver="$(awk '/^image:/{f=1} f && /tag:/{gsub(/"/,"",$2); print $2; exit}' "$REPO_ROOT/deploy/postgresql/values.yaml")"
cat > "$TMP/manifest.txt" <<EOF
open-webui deployment backup bundle
created:       $(date -u +%Y-%m-%dT%H:%M:%SZ)
source host:   $(hostname)
k3s node:      $(env_value K3S_NODE_NAME)
message scale: $(env_value MESSAGE_SCALE)
open-webui:    chart ${chart_ver:-unknown}, app image ${app_ver:-unknown}
postgresql:    image ${pg_ver:-unknown}
chat rows:     ${chat_rows:-unknown}
contents:
$db_manifest
  volumes: open-webui.tar.gz, searxng.tar.gz
env:         env.env (site values only — credentials live in secrets.env)
secrets:     secrets.env (every credential Secret, base64 per key)
restore:     ./deploy/restore.sh <this bundle>
EOF
ok "wrote the manifest"

# bundle it
bundle_base="open-webui-backup_${stamp}"
tar czf "$TMP/$bundle_base.tar.gz" -C "$TMP" db volumes env.env secrets.env manifest.txt ${MANIFEST_IN_BUNDLE:+secrets.manifest}
ok "staged $bundle_base.tar.gz"

# encrypt
BUNDLE_OUT="$DEST/$bundle_base.tar.gz.gpg"
gpg --batch --yes --quiet --symmetric --cipher-algo AES256 \
    --pinentry-mode loopback --passphrase-fd 3 \
    --output "$BUNDLE_OUT" "$TMP/$bundle_base.tar.gz" 3<<<"$PASSPHRASE"
ok "encrypted to $BUNDLE_OUT"

# ── verify: decrypt again and check every member ─────────────────────────────
section "Verifying the bundle"
VTMP="$(mktemp -d "${TMPDIR:-/tmp}/owui-verify.XXXXXX")"
gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 \
    --output "$VTMP/bundle.tar.gz" "$BUNDLE_OUT" 3<<<"$PASSPHRASE"
tar xzf "$VTMP/bundle.tar.gz" -C "$VTMP"
[[ -f "$VTMP/manifest.txt" && -f "$VTMP/env.env" && -f "$VTMP/secrets.env" ]] \
  || { bad "decrypted bundle is missing manifest, env or secrets."; exit 1; }
grep -q '^K3S_NODE_NAME=' "$VTMP/env.env" || { bad "decrypted env.env has no K3S_NODE_NAME."; exit 1; }
grep -q '^#secret postgres' "$VTMP/secrets.env" || { bad "decrypted secrets.env has no postgres section."; exit 1; }
grep -q '^#secret ai-open-webui-secrets' "$VTMP/secrets.env" || { bad "decrypted secrets.env has no ai-open-webui-secrets section."; exit 1; }
# The strongest check available without the passphrase-independent state: if the
# fingerprint manifest is in the bundle, recompute every HMAC from the dumped
# (decoded) values and compare. This proves the credentials survived the
# tar+gpg round trip bit-exact — the same guarantee the DB dump gets from its
# trailer, which a plain "file exists" check does not give.
if [[ -f "$VTMP/secrets.manifest" ]]; then
  if ! python3 - "$VTMP/secrets.env" "$VTMP/secrets.manifest" <<'PYEOF'
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
    bad "the dumped credentials do not match secrets.manifest."
    exit 1
  fi
  ok "every dumped credential matches the fingerprint manifest"
else
  note "no fingerprint manifest in the bundle; secrets.env checked for presence only"
fi
for f in "$VTMP"/db/*.sql.gz; do
  gzip -t "$f" || { bad "gzip integrity failed: $f"; exit 1; }
  gzip -dc "$f" | grep -q "PostgreSQL database dump complete" || { bad "missing dump trailer: $f"; exit 1; }
done
# `tar -tf`, not `tar -t`: without -f the path is read as a *member name* to
# list inside the stdin archive, not as the archive itself.
gzip -t "$VTMP/volumes/open-webui.tar.gz" && tar -tf "$VTMP/volumes/open-webui.tar.gz" >/dev/null \
  || { bad "the open-webui volume archive will not extract."; exit 1; }
[[ -f "$VTMP/volumes/searxng.tar.gz" ]] && { gzip -t "$VTMP/volumes/searxng.tar.gz" && tar -tf "$VTMP/volumes/searxng.tar.gz" >/dev/null || { bad "the searxng archive will not extract."; exit 1; }; }
rm -rf "$VTMP"; VTMP=""
VERIFIED=1
ok "the bundle decrypts and every member checks out"

echo
echo "OK: backup complete."
echo "     bundle:      $DEST/$bundle_base.tar.gz.gpg"
echo "     size:        $(du -h "$DEST/$bundle_base.tar.gz.gpg" | cut -f1)"
echo "     restore:     ./deploy/restore.sh $DEST/$bundle_base.tar.gz.gpg"
echo "     passphrase:  you are the only copy of it; the bundle is useless without it."
