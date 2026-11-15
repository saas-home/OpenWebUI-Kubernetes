#!/usr/bin/env bash
# Deploy the AI stack on this node. This is the script to run.
#
# It deploys PostgreSQL first, because Open WebUI connects to the database during
# startup, then deploys Open WebUI, and finishes with one status block for the whole
# stack. The helm work lives in each component's own deploy.sh; this script decides
# what to run, in which order, and reports the result.
#
# Usage:
#   ./deploy/deploy.sh                      # postgresql, then open-webui
#   ./deploy/deploy.sh postgresql           # one component
#   ./deploy/deploy.sh open-webui           # one component
#   ./deploy/deploy.sh --dry-run            # lint and render both; changes nothing
#                                           # on the cluster; Secrets withheld
#   ./deploy/deploy.sh --check              # report .env drift for both
#   ./deploy/deploy.sh open-webui --check   # one component, one mode
#   ./deploy/deploy.sh --pinned            # no GA float even on a fresh install
#
# Target and mode may be given in either order. An unknown argument, or two
# different targets or modes, is a hard error: the default path is a live deploy, so
# a mistyped --dry-run must not silently become one.
#
# In deploy mode the run stops at the first component that fails, because deploying
# the app against a broken database only produces confusing errors downstream.
# --check and --dry-run cover every selected component and exit 1 if any of them
# failed, so one run shows the state of the whole stack.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
ENV_EXAMPLE="$REPO_ROOT/.env.example"

# Deploy order. The app authenticates against the database at startup.
TARGETS=(postgresql open-webui)

# Pinned release names: deploy/postgresql/templates/_helpers.tpl returns
# .Release.Name verbatim, and the app Service is named after its release.
APP_RELEASE=ai-open-webui
NAMESPACE=default
# The upstream chart's fullname helper collapses to the release name itself when
# the release name contains the chart name, so the app Service (like the
# StatefulSet) is $APP_RELEASE, not $APP_RELEASE-open-webui. Derive it the same
# way deploy/open-webui/deploy.sh does.
if [[ "$APP_RELEASE" == *open-webui* ]]; then APP_SERVICE="$APP_RELEASE"; else APP_SERVICE="$APP_RELEASE-open-webui"; fi

usage() {
  cat >&2 <<'MSG'
Usage: ./deploy/deploy.sh [target] [mode]

  target   all (default) | postgresql | open-webui
  mode     (none = live deploy) | --dry-run | --check
  flag     --pinned   fresh installs deploy the values.yaml pins instead of
                      floating the image tags to the newest GA

  ./deploy/deploy.sh                      # postgresql then open-webui
  ./deploy/deploy.sh postgresql           # database only
  ./deploy/deploy.sh --check              # drift for both components
  ./deploy/deploy.sh open-webui --dry-run # render the app chart only
MSG
}

TARGET=""
MODE=deploy
PINNED=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    all|postgresql|open-webui)
      # An explicit target, however given, conflicts with a different one. `all` counts:
      # `all postgresql` used to fall through to a live deploy of postgresql alone, which
      # is the opposite of what asking for everything means.
      if [[ -n "$TARGET" && "$TARGET" != "$arg" ]]; then
        echo "ERROR: two targets given: $TARGET and $arg." >&2
        usage
        exit 2
      fi
      TARGET="$arg"
      ;;
    --dry-run|--check)
      if [[ "$MODE" != deploy && "$MODE" != "${arg#--}" ]]; then
        echo "ERROR: two modes given: --$MODE and $arg." >&2
        usage
        exit 2
      fi
      MODE="${arg#--}"
      ;;
    --pinned)
      PINNED=1
      ;;
    *)
      echo "ERROR: unknown argument '$arg'." >&2
      usage
      exit 2
      ;;
  esac
done

selected=()
if [[ -z "$TARGET" || "$TARGET" == all ]]; then selected=("${TARGETS[@]}"); else selected=("$TARGET"); fi

# Preflight everything cheap and local, so a missing binary or file fails here rather
# than inside the second component after the first has already been applied.
for cmd in helm kubectl curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: $cmd is not on PATH; $cmd is required." >&2
    exit 1
  }
done

for t in "${selected[@]}"; do
  script="$SCRIPT_DIR/$t/deploy.sh"
  [[ -f "$script" ]] || { echo "ERROR: $script not found." >&2; exit 1; }
  [[ -x "$script" ]] || { echo "ERROR: $script is not executable. Fix with: chmod +x $script" >&2; exit 1; }
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found." >&2
  echo "       Create it from the template and fill in real values:" >&2
  echo "         cp $ENV_EXAMPLE $ENV_FILE" >&2
  echo "         chmod 600 $ENV_FILE" >&2
  echo "         \${EDITOR:-vi} $ENV_FILE" >&2
  exit 1
fi

mode_args=()
case "$MODE" in
  dry-run) mode_args=(--dry-run) ;;
  check)   mode_args=(--check) ;;
esac
if (( PINNED )); then mode_args+=(--pinned); fi

failed=()
for t in "${selected[@]}"; do
  echo
  echo "══════════════════════════════════════════════════════════════════════"
  echo "  $t   [$MODE]"
  echo "══════════════════════════════════════════════════════════════════════"
  if ! "$SCRIPT_DIR/$t/deploy.sh" "${mode_args[@]}"; then
    failed+=("$t")
    if [[ "$MODE" == deploy ]]; then
      echo "ERROR: $t failed; the remaining components were not deployed." >&2
      break
    fi
  fi
done

if (( ${#failed[@]} )); then
  echo "ERROR: failed: ${failed[*]}" >&2
  exit 1
fi

echo
echo "OK: ${selected[*]} [$MODE]"

# Informational only: each component already gated its own deploy on real checks.
# Nothing here is allowed to turn a successful deploy into a failure, so every
# pipeline ends in `|| true` -- under `set -o pipefail` a transient `helm list` or
# `kubectl get pods` error would otherwise become this script's exit status after
# both components had deployed cleanly.
if [[ "$MODE" == deploy ]]; then
  echo
  echo "Stack status"
  helm list -n "$NAMESPACE" | sed 's/^/  /' || true
  kubectl get pods -n "$NAMESPACE" --no-headers \
    | awk '{printf "  %-46s %s %-10s restarts %s\n", $1, $2, $3, $4}' || true
  node_port=$(kubectl get svc "$APP_SERVICE" -n "$NAMESPACE" \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
  if [[ -z "$node_port" ]]; then
    echo "  app Service $APP_SERVICE not found; skipped the HTTP checks."
  else
    for path in /health /health/db; do
      printf "  GET %-12s -> %s\n" "$path" \
        "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://localhost:${node_port}${path}")"
    done
    printf "  version        -> %s\n" \
      "$(curl -s --max-time 15 "http://localhost:${node_port}/api/config" \
         | python3 -c 'import sys,json; print(json.load(sys.stdin).get("version","?"))' 2>/dev/null || echo '?')"
  fi
fi
