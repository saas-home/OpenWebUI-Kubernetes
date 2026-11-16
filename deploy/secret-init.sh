#!/usr/bin/env bash
# One-time credential entry for the Open WebUI stack. Replaces the credentials
# that used to live in .env: every secret is typed once here and stored in the
# K3s datastore — encrypted at rest by K3s --secrets-encryption — and the charts
# reference the Secrets by name (existingSecret). .env keeps only site values
# and carries no credential at all.
#
#   ./deploy/secret-init.sh          # create or update the three Secrets
#   ./deploy/secret-init.sh --check  # verify existence + fingerprints; changes nothing
#
# Values never touch argv (--from-literal puts them in `ps` and shell history).
# Each one is piped from a 0600 temp file via --from-file, and every temp file
# is removed on exit. A random per-value salt and an HMAC-SHA256 fingerprint of
# each value are recorded in $REPO_ROOT/secrets.manifest (gitignored): enough to
# detect rotation drift and prove which value is live, not enough to recover it.
#
# The Secrets this creates are NOT owned by helm (they pre-date the release),
# so a helm upgrade never rewrites or deletes them, and uninstall.sh stage 2
# removes them explicitly.
#
# The durable copy of every value is the encrypted backup bundle
# (deploy/backup.sh dumps the Secrets into it). Losing this host and the bundle
# loses the credentials — the manifest cannot restore them by design.
set -euo pipefail

umask 077

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
MANIFEST="$REPO_ROOT/secrets.manifest"
NAMESPACE="default"

# ── output helpers (same style as the other deploy scripts) ──────────────────
ok()   { printf '  OK    %s\n' "$1"; }
note() { printf  '  --    %s\n' "$1"; }
ask()  { printf  '  TODO  %s\n' "$1"; }
bad()  { printf  '  FAIL  %s\n' "$1" >&2; }
section() { printf '\n== %s\n' "$1"; }

TMP=""
cleanup() {
  [[ -n "$TMP" ]] && rm -rf "$TMP" 2>/dev/null || true
  # A run that dies between the truncation and the final mv leaves the staging
  # file behind; the next run truncates it anyway, but nothing should linger.
  rm -f "$MANIFEST.tmp" 2>/dev/null || true
}
trap cleanup EXIT

case "${1:-}" in
  '') ;;
  --check) ;;
  -h|--help)
    awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "${BASH_SOURCE[0]}" >&2
    exit 0 ;;
  *) echo "ERROR: unknown argument '$1'. Usage: ./deploy/secret-init.sh [--check]" >&2; exit 2 ;;
esac

for tool in kubectl python3 openssl; do
  command -v "$tool" >/dev/null 2>&1 || { bad "$tool is not installed but is required."; exit 1; }
done
kubectl get -n "$NAMESPACE" svc >/dev/null 2>&1 \
  || { bad "cannot reach the cluster. K3s must be running (sudo ./deploy/bootstrap-root.sh)."; exit 1; }

# ── .env reader: same last-match-wins parse as the deploy scripts ────────────
env_value() {
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | tr -d '\r'
}

# ── fingerprint helpers ──────────────────────────────────────────────────────
# fingerprint <salt> <value> -> hex hmac-sha256. The salt is stored next to the
# fingerprint in the manifest, so --check recomputes from the live Secret and
# compares. The value itself is never written.
fingerprint() {
  printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" -hex | awk '{print $NF}'
}

# manifest_write <secret> <key> <salt> <fp>
# Appends to MANIFEST.tmp, which is moved over MANIFEST atomically at the end
# of the run. Writing to MANIFEST directly would let that final mv wipe the
# lines just recorded (the mv replaces the destination).
manifest_write() {
  printf '%s/%s %s %s\n' "$1" "$2" "$3" "$4" >>"$MANIFEST.tmp"
}

# For each secret, the keys this tool manages and whether a key is required for
# the stack to boot.
APP_SECRET="ai-open-webui-secrets"
PG_SECRET="postgres"
SEARX_SECRET="ai-open-webui-searxng"

# ── prompts ──────────────────────────────────────────────────────────────────
# Each prompt returns the value on stdout. Hidden input, empty stdin handled by
# the caller. A value that needs to survive the run is written straight into a
# 0600 temp file; nothing is kept in a shell variable longer than one prompt.
gen_secret() {
  python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits+'-_') for _ in range(32)))"
}

prompt_secret() { # <label> <gen: 0=optional Enter-skips, 1=Enter-generates, 2=required no-skip>
  # Everything except the value itself goes to stderr: the caller captures
  # stdout, so a prompt printed there would end up inside the value.
  # A bad entry re-prompts in place, passwd-style, and never aborts the run:
  # an error late in the flow must not cost the entries made earlier.
  local label="$1" gen="$2" v1 v2
  if (( gen == 1 )); then
    echo "  $label [Enter = generate a strong random value]" >&2
  elif (( gen == 2 )); then
    echo "  $label [required — Enter re-prompts]" >&2
  else
    echo "  $label [Enter = skip]" >&2
  fi
  while :; do
    read -r -s -p '  > ' v1; echo >&2
    v1="${v1%$'\r'}"   # a pasted line can carry a CR; it is invisible and silently poisons the value
    if [[ -z "$v1" ]]; then
      if (( gen == 1 )); then
        v1="$(gen_secret)"
        echo "  generated a random value" >&2
        printf '%s' "$v1"
        return 0
      elif (( gen == 2 )); then
        # Enter must re-prompt, not skip: the caller needs a value.
        echo "  a value is required — re-enter it (Ctrl-C aborts the run)." >&2
        continue
      fi
      printf '%s' ""
      return 0
    fi
    read -r -s -p '  Confirm: ' v2; echo >&2
    v2="${v2%$'\r'}"
    if [[ "$v1" == "$v2" ]]; then
      printf '%s' "$v1"
      return 0
    fi
    echo "  the two entries do not match — re-enter the value." >&2
  done
}

prompt_visible() { # <label> — not a secret (an OAuth client id is public by design)
  local label="$1" v
  read -r -p "  $label: " v; echo >&2
  v="${v%$'\r'}"
  printf '%s' "$v"
}

# write_value <secret> <key> <value> <required:0|1> — stages into $TMP and
# returns the temp path on stdout. An empty optional value returns nothing.
stage_value() {
  local secret="$1" key="$2" value="$3" required="$4" f
  if [[ -z "$value" ]]; then
    if (( required )); then
      bad "$key is required — the $secret Secret cannot be created without it."
      exit 1
    fi
    return 0
  fi
  f="$TMP/$secret.$key"
  umask 077
  printf '%s' "$value" >"$f"
  printf '%s' "$f"
}

# ── CHECK mode: existence + fingerprints, changes nothing ────────────────────
if [[ "${1:-}" == "--check" ]]; then
  section "Secrets check"
  rc=0
  check_one() { # <secret> <key>...   (a key named "-" is optional)
    local secret="$1"; shift
    if ! kubectl get secret "$secret" -n "$NAMESPACE" >/dev/null 2>&1; then
      bad "$secret does not exist. Run ./deploy/secret-init.sh"
      return 1
    fi
    local missing=()
    local k
    for k in "$@"; do
      [[ "$k" == -* ]] && continue
      [[ -n "$(kubectl get secret "$secret" -n "$NAMESPACE" -o jsonpath="{.data.$k}" 2>/dev/null)" ]] \
        || missing+=("$k")
    done
    if (( ${#missing[@]} )); then
      bad "$secret is missing keys: ${missing[*]}. Run ./deploy/secret-init.sh"
      return 1
    fi
    return 0
  }
  check_one "$PG_SECRET" password || rc=1
  check_one "$APP_SECRET" WEBUI_SECRET_KEY DATABASE_URL "-GOOGLE_CLIENT_ID" "-GOOGLE_CLIENT_SECRET" || rc=1
  if kubectl get secret "$SEARX_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
    check_one "$SEARX_SECRET" brave-api-key || rc=1
  else
    note "$SEARX_SECRET not created (no Brave key) — web search off; fine if intended"
  fi

  # fingerprint drift: what the manifest recorded vs what is live now
  if [[ -f "$MANIFEST" ]]; then
    drift=0
    while read -r ref salt expected || [[ -n "${ref:-}" ]]; do
      [[ -z "$ref" || "$ref" =~ ^[[:space:]]*# ]] && continue
      m_secret="${ref%%/*}"; m_key="${ref#*/}"
      live="$(kubectl get secret "$m_secret" -n "$NAMESPACE" -o jsonpath="{.data.$m_key}" 2>/dev/null | base64 -d 2>/dev/null || true)"
      actual="$(fingerprint "$salt" "$live")"
      if [[ "$actual" != "$expected" ]]; then
        bad "$ref changed since the manifest was written (rotated? re-run ./deploy/secret-init.sh to re-record, or investigate)"
        rc=1; drift=1
      fi
    done <"$MANIFEST"
    (( drift )) || ok "fingerprints match secrets.manifest"
  else
    note "no $MANIFEST — run ./deploy/secret-init.sh once to record fingerprints"
  fi
  echo
  if (( rc )); then
    echo "secrets check: FAILURE(S)" >&2
    exit 1
  fi
  echo "OK: secrets check passed"
  exit 0
fi

# ── create/update ────────────────────────────────────────────────────────────
section "Credentials (stored encrypted in the K3s datastore, not on disk)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/owui-secrets.XXXXXX")"
: >"$MANIFEST.tmp"

# Postgres: the password is honoured only while initdb runs on an empty data
# directory (see README). On an existing database this value must match the
# live DB: rotate with ALTER USER first, then re-run this script.
# DATABASE_URL is assembled here from the non-secret POSTGRES_* values in .env
# plus the password just entered, so the DSN and the DB password can never
# drift apart. Same URL-encoding rule the deploy script used to apply.
# Fail on missing .env keys BEFORE any prompt: an error here must not strand
# entries already made.
PG_HOST="$(env_value POSTGRES_HOST)"; PG_PORT="$(env_value POSTGRES_PORT)"
PG_DB="$(env_value POSTGRES_DB)";     PG_USER="$(env_value POSTGRES_USER)"
for v in "$PG_HOST" "$PG_PORT" "$PG_DB" "$PG_USER"; do
  [[ -n "$v" ]] || { bad "POSTGRES_* site values missing in .env — run ./deploy/bootstrap-host.sh first."; exit 1; }
done

pg_pass="$(prompt_secret "Database password (POSTGRES_PASSWORD)" 1 || true)"
pg_file="$(stage_value "$PG_SECRET" password "$pg_pass" 1)"

app_key="$(prompt_secret "Session signing key (OPEN_WEBUI_SECRET_KEY)" 1 || true)"
key_file="$(stage_value "$APP_SECRET" WEBUI_SECRET_KEY "$app_key" 1)"
# The password travels on stdin (never argv — `ps` is world-readable); the
# non-secret DSN parts are positional arguments.
DSN="$(printf '%s' "$pg_pass" | python3 -c '
import sys, urllib.parse
pw = sys.stdin.read()
user, host, port, db = sys.argv[1:5]
print("postgresql://" + urllib.parse.quote(user) + ":" + urllib.parse.quote(pw, safe="") + "@" + host + ":" + port + "/" + db)
' "$PG_USER" "$PG_HOST" "$PG_PORT" "$PG_DB")"
dsn_file="$(stage_value "$APP_SECRET" DATABASE_URL "$DSN" 1)"

# Google SSO: both or neither, matching the rule the wizard and deploy.sh had.
# A skip on the secret when an ID was given is a re-prompt, not a dead run —
# the whole point of validating during entry is that nothing downstream is lost.
echo "  Google SSO [Enter on the first prompt = skip; the app serves its login form]" >&2
gcid="$(prompt_visible "Google OAuth client ID")"
gcid="${gcid//[[:space:]]/}"   # a pasted id carries no meaningful whitespace
if [[ -n "$gcid" ]]; then
  # A client ID without its secret is a half-pair the app cannot use, so this
  # uses gen=2: no Enter-to-skip — the prompt loops internally until a secret
  # is entered and confirmed. The escape is deliberate: Ctrl-C and re-run,
  # pressing Enter on the client ID prompt to skip SSO entirely.
  gcsec="$(prompt_secret "Google OAuth client secret" 2 || true)"
  gcsec="${gcsec//[[:space:]]/}"
  [[ -n "$gcsec" ]] || { bad "no client secret entered; nothing was written to the cluster."; exit 1; }
else
  gcsec=""
fi
gcid_file="$(stage_value "$APP_SECRET" GOOGLE_CLIENT_ID "$gcid" 0)"
gcsec_file="$(stage_value "$APP_SECRET" GOOGLE_CLIENT_SECRET "$gcsec" 0)"

# The Brave key is interpolated by the init container into settings.yml inside
# double quotes, so anything outside letters/digits/-/_ (a quote, a newline, a
# stray space from a paste) would break or rewrite the YAML. Real keys contain
# no whitespace at all, so it is stripped before the check; a rejection
# re-prompts in place and shows only the offending characters — never the key.
brave=""
while :; do
  brave="$(prompt_secret "Brave Search API key (web search)" 0 || true)"
  brave="${brave//[[:space:]]/}"
  [[ -z "$brave" ]] && break   # explicit skip
  [[ "$brave" =~ ^[A-Za-z0-9_-]+$ ]] && break
  offenders="$(printf '%s' "$brave" | tr -d 'A-Za-z0-9_-' | sed -e 's/\r/<CR>/g' -e 's/ /<space>/g' | head -c 40)"
  echo "  the key contains characters outside letters, digits, '-' and '_': $offenders — re-enter, or press Enter to skip web search." >&2
  brave=""
done
brave_file="$(stage_value "$SEARX_SECRET" brave-api-key "$brave" 0)"

# ── apply first, record only what applied ────────────────────────────────────
# The idempotent create-or-update. Values travel as files on this host only;
# the API server request carries them over TLS to the encrypted datastore.
apply_secret() { # <secret> <file...>
  local secret="$1"; shift
  local args=() f base
  for f in "$@"; do
    base="${f##*/}"
    args+=(--from-file="${base#*$secret.}=$f")
  done
  kubectl create secret generic "$secret" -n "$NAMESPACE" "${args[@]}" \
      --dry-run=client -o yaml 2>/dev/null | kubectl apply -f - >/dev/null
  ok "$secret created/updated in the $NAMESPACE namespace"
}
apply_secret "$PG_SECRET" "$pg_file"
if [[ -n "$brave_file" ]]; then
  apply_secret "$SEARX_SECRET" "$brave_file"
else
  note "$SEARX_SECRET not created (no Brave key) — the chart reference is optional"
fi
if [[ -n "$gcid_file" && -n "$gcsec_file" ]]; then
  apply_secret "$APP_SECRET" "$key_file" "$dsn_file" "$gcid_file" "$gcsec_file"
else
  apply_secret "$APP_SECRET" "$key_file" "$dsn_file"
fi

record() { # <secret> <key> <file>
  local secret="$1" key="$2" file="$3"
  [[ -n "$file" ]] || return 0
  local salt fp
  salt="$(openssl rand -hex 16)"
  fp="$(fingerprint "$salt" "$(cat "$file")")"
  manifest_write "$secret" "$key" "$salt" "$fp"
}
record "$PG_SECRET" password "$pg_file"
record "$APP_SECRET" WEBUI_SECRET_KEY "$key_file"
record "$APP_SECRET" DATABASE_URL "$dsn_file"
if [[ -n "$gcid_file" ]]; then record "$APP_SECRET" GOOGLE_CLIENT_ID "$gcid_file"; fi
if [[ -n "$gcsec_file" ]]; then record "$APP_SECRET" GOOGLE_CLIENT_SECRET "$gcsec_file"; fi
if [[ -n "$brave_file" ]]; then record "$SEARX_SECRET" brave-api-key "$brave_file"; fi
mv "$MANIFEST.tmp" "$MANIFEST"
chmod 600 "$MANIFEST"
note "fingerprints recorded in $MANIFEST (gitignored — names, salts, hashes; no values)"

echo
echo "OK: credentials are in the K3s datastore. .env carries no credential."
note "rotate the DB password with ALTER USER first, then re-run this script, then restart the app."
note "  Open an interactive psql so the new password never reaches a command line or the process list:"
note "    kubectl exec -it deploy/postgres -n default -- psql -U $PG_USER -d postgres"
note "  then run:  ALTER USER $PG_USER WITH PASSWORD '<new>';   (typed at the psql prompt)"
note "verify any time: ./deploy/secret-init.sh --check"
note "the durable copy lives in the encrypted bundle: ./deploy/backup.sh"
