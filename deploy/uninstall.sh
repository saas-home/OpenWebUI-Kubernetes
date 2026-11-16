#!/usr/bin/env bash
# Staged uninstall for the Open WebUI stack. Run as your NORMAL user (stage 4
# escalates with sudo itself, after its own gate).
#
#   ./deploy/uninstall.sh                 # stages 1-4 in order; between stages
#                                         # it asks whether to continue (default: stop)
#   ./deploy/uninstall.sh 3               # run ONLY stage 3 (its predecessors
#                                         # must already be done, or it refuses)
#   ./deploy/uninstall.sh --check         # show what every stage would touch;
#                                         # changes nothing, asks nothing
#
# Before stage 1 (sequential mode only) the script offers an encrypted backup
# bundle (deploy/backup.sh) of the current settings and data — the only
# complete, portable restore. The nightly archives under BACKUP_DATA_PATH are
# not a full restore: they carry no .env, cover only 7/4 days, and an
# unencrypted archive is not something to hand to a new server.
#
# Stages:
#   1  Uninstall the Helm releases (ai-open-webui, postgres). All data survives:
#      the PVs have the Retain policy and nothing here touches the host paths.
#   2  Purge the cluster objects the releases do not own: the open-webui PV and
#      PVC and the local-storage StorageClass (plus any release-owned PV/PVC
#      left behind). The host directories are still untouched.
#   3  Purge the host data: the LIVE_DATA_PATH and BACKUP_DATA_PATH trees from
#      .env and the .env file itself.
#   4  Purge the host: K3s (official uninstall script), the helm binary, the
#      apt packages the bootstrap installed (only those nothing else uses; the
#      rest are listed with their dependents), /etc/modules-load.d/k3s.conf,
#      /etc/sysctl.d/99-k3s.conf, and swap re-enabled from the fstab backup.
#
# The run asks one small arithmetic question (a or b from 0..9) before the
# first stage that still has work to do — never per stage. A wrong answer
# aborts the run with nothing changed. There is deliberately no --yes flag:
# a destructive run always stops for a human. Stages are ordered; a stage
# refuses to run while its predecessors have not happened, so the data cannot
# be deleted out from under a running pod.
#
# This script will NOT: touch any path it does not recognise, remove an apt
# package that an installed package depends on, or re-format or unmount
# anything. A data root that is a mount point has its contents removed, never
# the mount point itself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"


LIVE_DEFAULT="$HOME/.open-webui/live-data"
BACKUP_DEFAULT="$HOME/.open-webui/backup-data"

CHECK_ONLY=0
STAGE=""
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  arg="${args[i]}"
  case "$arg" in
    -h|--help)
      awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "${BASH_SOURCE[0]}" >&2
      exit 0
      ;;
    --check)    CHECK_ONLY=1 ;;
    [1-4])
      if [[ -n "$STAGE" ]]; then
        echo "ERROR: one stage only: '$STAGE' and '$arg'." >&2; exit 2
      fi
      STAGE="$arg"
      ;;
    *)
      echo "ERROR: unknown argument '$arg'. Usage: ./deploy/uninstall.sh [--check] [1|2|3|4]" >&2
      exit 2
      ;;
  esac
  i=$(( i + 1 ))
done

ok()   { printf '  OK    %s\n' "$1"; }
note() { printf  '  --    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1" >&2; }
section() {
  echo
  echo "══════════════════════════════════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════════════════════════════════"
}

# ── the gate (asked once per run, before the first pending stage) ────────────
# A random one-digit sum or difference. Answer it correctly and the run
# proceeds; anything else stops it before the first stage changes anything.
# Three attempts, each with a fresh question: a slip of the finger gets a
# retry, but a scripted or inattentive caller still cannot get through.
arith_gate() { # <stage label>
  local a b op target ans t attempt
  [[ -t 0 ]] || { bad "no interactive terminal; destructive stages need one."; exit 1; }
  for attempt in 1 2 3; do
    a=$(( RANDOM % 10 )); b=$(( RANDOM % 10 ))
    if (( RANDOM % 2 )); then
      op="+"; target=$(( a + b ))
    else
      op="-"
      if (( a < b )); then t="$a"; a="$b"; b="$t"; fi
      target=$(( a - b ))
    fi
    (( attempt > 1 )) && printf '  (attempt %d of 3)\n' "$attempt"
    printf '  To proceed with %s, answer:   %d %s %d = ?\n' "$1" "$a" "$op" "$b"
    read -r ans || { bad "no answer. Stopping — this stage changed nothing."; exit 1; }
    [[ "$ans" == "$target" ]] && return 0
    printf '  wrong answer.\n'
  done
  bad "three wrong answers. Stopping — this stage changed nothing."
  exit 1
}

# ── .env: resolve the two data roots the same way the deploy scripts do ─────
env_value() {
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | tr -d '\r'
}
resolve_data_root() { # <raw> <default> <label>
  local raw="${1-}" def="$2" label="$3" out
  out="${raw:-$def}"
  out="${out/#\~/$HOME}"
  [[ "$out" == /* ]] || { bad "$label='$out' is not an absolute path."; return 1; }
  [[ "$out" =~ ^[A-Za-z0-9._/-]+$ ]] || { bad "$label contains characters a data root may not ($out)."; return 1; }
  printf '%s' "$out"
}

# ── state probes (read-only) ─────────────────────────────────────────────────
stage1_done() {
  command -v helm >/dev/null 2>&1 || return 0
  helm list -q -n default 2>/dev/null | grep -qE '^(ai-open-webui|postgres)$' && return 1
  return 0
}
# The credential Secrets are helm-unowned (pre-created by secret-init.sh), so
# they survive every helm uninstall and must be purged here explicitly.
SECRET_NAMES=(postgres ai-open-webui-secrets ai-open-webui-searxng)
stage2_done() {
  command -v kubectl >/dev/null 2>&1 || return 0
  kubectl get pv -o name 2>/dev/null | grep -qE '^persistentvolume/(postgres-pv|ai-open-webui-searxng-pv|open-webui-pv-local)$' && return 1
  kubectl get pvc -n default -o name 2>/dev/null | grep -qE '^persistentvolumeclaim/(postgres|ai-open-webui-searxng|open-webui)$' && return 1
  kubectl get sc local-storage >/dev/null 2>&1 && return 1
  local s
  for s in "${SECRET_NAMES[@]}"; do
    kubectl get secret "$s" -n default >/dev/null 2>&1 && return 1
  done
  return 0
}
stage3_paths() {
  LIVE_PATH="$(resolve_data_root "$(env_value LIVE_DATA_PATH)" "$LIVE_DEFAULT" LIVE_DATA_PATH)"
  BACKUP_PATH="$(resolve_data_root "$(env_value BACKUP_DATA_PATH)" "$BACKUP_DEFAULT" BACKUP_DATA_PATH)"
}
stage3_done() {
  stage3_paths
  [[ -e "$LIVE_PATH" || -e "$BACKUP_PATH" || -f "$ENV_FILE" ]] && return 1
  return 0
}
stage4_done() {
  [[ -f /usr/local/bin/k3s || -f /usr/local/bin/helm ]] && return 1
  [[ -f /etc/modules-load.d/k3s.conf || -f /etc/sysctl.d/99-k3s.conf ]] && return 1
  return 0
}

# ── package scan for stage 4 (read-only, used by --check too) ────────────────
BOOTSTRAP_PKGS=(curl git python3 openssl)
# Packages the repo's own host scripts need (deploy/open-webui/deploy.sh renders
# its values file and does --check drift comparisons with python3;
# bootstrap-root.sh parses release tags with it). apt cannot see script
# dependencies, so these are kept unconditionally — removing them would leave
# the repo on disk but unable to deploy again until the bootstrap is re-run.
REPO_TOOLING_PKGS=(python3)
pkg_cascade() { # <pkg> — what apt would remove ALONGSIDE it; empty if it stands alone
  # apt's own simulation is the authority: Recommends edges do not cascade,
  # hard Depends do. Works without root (dry-run).
  apt-get remove --dry-run -y "$1" 2>/dev/null | awk '/^Remv /{print $2}' | grep -vx "$1" || true
}

cascade_summary() { # <cascade-list> — first few names + count, for display
  # The list is apt's reverse-dependency cascade: host packages that DEPEND
  # on the candidate, not packages this deployment installed. A big list is
  # the point (it's why we keep the pkg), so show a few names and the count.
  local n
  [[ -n "$1" ]] || { echo ""; return; }
  n=$(echo "$1" | wc -l)
  echo "$(echo "$1" | head -5 | paste -sd, | sed 's/,/, /g')$(
    (( n > 5 )) && printf ' (+%d more)' "$((n - 5))")"
}

backup_count() {
  [[ -d "$BACKUP_PATH" ]] || { printf 'none'; return; }
  local n s
  n=$(find "$BACKUP_PATH" -type f 2>/dev/null | wc -l)
  s=$(du -sh "$BACKUP_PATH" 2>/dev/null | cut -f1)
  printf '%s files, %s' "${n:-0}" "${s:-0}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Plan
# ═══════════════════════════════════════════════════════════════════════════
section "Uninstall plan"
stage3_paths
note "LIVE data root : $LIVE_PATH"
note "BACKUP root    : $BACKUP_PATH (previous backups: $(backup_count))"
  note ".env           : $ENV_FILE"
if [[ -f "$ENV_FILE" ]] && ! stage1_done; then
  note "safety backup  : offered before stage 1 — encrypted bundle via deploy/backup.sh"
else
  note "safety backup  : skipped (no .env or stack already uninstalled — nothing to bundle)"
fi

if (( CHECK_ONLY )); then
  echo
  stage1_done && note "stage 1: releases ai-open-webui and postgres — already uninstalled" \
              || note "stage 1: would helm-uninstall ai-open-webui and postgres (data KEPT)"
  stage2_done && note "stage 2: PV/PVC/StorageClass/credential Secrets — already purged" \
              || note "stage 2: would delete PV open-webui-pv-local, PVC open-webui, StorageClass local-storage, Secrets ${SECRET_NAMES[*]} (+ leftovers)"
  stage3_done && note "stage 3: host data — already gone" \
              || { note "stage 3: would delete $LIVE_PATH"; note "stage 3: would delete $BACKUP_PATH"; note "stage 3: would delete $ENV_FILE"; }
  if stage4_done; then
    note "stage 4: host — already purged (no k3s, helm, or bootstrap files found)"
  else
    note "stage 4: would uninstall K3s, remove /usr/local/bin/helm, remove /etc/modules-load.d/k3s.conf and /etc/sysctl.d/99-k3s.conf"
    for p in "${BOOTSTRAP_PKGS[@]}"; do
      if dpkg -s "$p" >/dev/null 2>&1; then
        if [[ " ${REPO_TOOLING_PKGS[*]} " == *" $p "* ]]; then
          note "stage 4: package $p — KEPT, the repo's own scripts need it"
          continue
        fi
        cascade="$(pkg_cascade "$p")"
        if [[ -n "$cascade" ]]; then
          note "stage 4: package $p — KEPT, other host packages depend on it (removing it would take: $(cascade_summary "$cascade"))"
        else
          note "stage 4: package $p — would remove (it stands alone)"
        fi
      else
        note "stage 4: package $p — not installed; nothing to do"
      fi
    done
  fi
  echo
  echo "OK: --check shows the plan. Nothing was changed, nothing was asked."
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
#  Stage 1 — Helm releases
# ═══════════════════════════════════════════════════════════════════════════
run_stage1() {
  section "Stage 1/4 — uninstall the Helm releases"
  local rel missing=0 present=()
  for rel in ai-open-webui postgres; do
    if helm list -q -n default 2>/dev/null | grep -qx "$rel"; then
      present+=("$rel")
    else
      note "release $rel: not present; nothing to do"
      missing=1
    fi
  done
  if (( ${#present[@]} )); then
    for rel in "${present[@]}"; do
      helm uninstall "$rel" -n default
      ok "uninstalled $rel"
    done
  fi
  if (( missing )) && stage1_done; then
    ok "stage 1 complete: no stack releases left"
  else
    ok "stage 1 complete. Data under $LIVE_PATH and $BACKUP_PATH is untouched."
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Stage 2 — cluster objects the releases do not own
# ═══════════════════════════════════════════════════════════════════════════
run_stage2() {
  section "Stage 2/4 — purge the cluster objects"
  # Decide the whole stage first, gate once, then execute.
  local pv pvs=() leftovers=() sc=0 s
  if kubectl get pvc open-webui -n default >/dev/null 2>&1; then
    pvs+=("pvc/open-webui (default)"); note "will delete PVC open-webui (default)"
  fi
  for pv in open-webui-pv-local postgres-pv ai-open-webui-searxng-pv; do
    if kubectl get pv "$pv" >/dev/null 2>&1; then
      pvs+=("$pv"); note "will delete PV $pv"
    fi
  done
  if kubectl get pvc -n default -o name 2>/dev/null | grep -qE '^persistentvolumeclaim/(postgres|ai-open-webui-searxng)$'; then
    leftovers=(postgres ai-open-webui-searxng); note "will delete leftover PVCs: ${leftovers[*]}"
  fi
  if kubectl get sc local-storage >/dev/null 2>&1; then
    sc=1; note "will delete StorageClass local-storage"
  fi
  for s in "${SECRET_NAMES[@]}"; do
    if kubectl get secret "$s" -n default >/dev/null 2>&1; then
      note "will delete Secret $s (the credentials it holds leave this host)"
    fi
  done
  local have_secret=0
  for s in "${SECRET_NAMES[@]}"; do
    kubectl get secret "$s" -n default >/dev/null 2>&1 && have_secret=1
  done
  if (( ${#pvs[@]} == 0 && ${#leftovers[@]} == 0 && sc == 0 && have_secret == 0 )); then
    ok "stage 2 complete: nothing left to remove"
    return
  fi
  # PVC before PV: deleting a bound PV first would leave the claim Lost.
  if kubectl get pvc open-webui -n default >/dev/null 2>&1; then
    kubectl delete pvc open-webui -n default
  fi
  if (( ${#leftovers[@]} )); then
    kubectl delete pvc "${leftovers[@]}" -n default 2>/dev/null || true
  fi
  for pv in open-webui-pv-local postgres-pv ai-open-webui-searxng-pv; do
    if kubectl get pv "$pv" >/dev/null 2>&1; then
      kubectl delete pv "$pv"
    fi
  done
  if (( sc )); then
    kubectl delete sc local-storage
  fi
  local s
  for s in "${SECRET_NAMES[@]}"; do
    if kubectl get secret "$s" -n default >/dev/null 2>&1; then
      kubectl delete secret "$s" -n default
      ok "deleted Secret $s"
    fi
  done
  ok "stage 2 complete: PVs, PVCs, the StorageClass and the credential Secrets are gone"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Stage 3 — host data
# ═══════════════════════════════════════════════════════════════════════════
guard_root() { # <path> — refuse anything a data root should never be
  local p="$1"
  [[ "$p" == /* ]] || { bad "$p is not absolute; refusing."; exit 1; }
  local n=1
  local s="$p"
  while [[ "$s" == */* ]]; do s="${s#*/}"; n=$(( n + 1 )); done
  (( n >= 3 )) || { bad "$p is too shallow to be a data root; refusing."; exit 1; }
  case "$p" in
    /|/home|/root|/tmp|/var|/etc|/usr|/opt|/boot|/mnt|/run|/lib|/lib64|/bin|/sbin|/dev|/proc|/sys)
      bad "$p is a system path; refusing."; exit 1 ;;
  esac
  # /home/<user> is never a data root; /home/<user>/<root> (the default layout) is.
  # if/then, not `[[ ]] && { …; }`: as the function's last statement a short-
  # circuited && list would return 1 and set -e would kill the caller.
  if [[ "$p" == /home/* && "${p#/home/}" != */* ]]; then
    bad "$p is a home directory itself; refusing."
    exit 1
  fi
}
purge_root() { # <path> — guarded delete; the stage gate is asked by the caller
  local p="$1"
  guard_root "$p"
  if [[ ! -d "$p" ]]; then
    note "$p: not present; nothing to delete"
    return 0
  fi
  # Parts of the tree belong to the container users (postgresql runs as 70,
  # SearXNG as 977): a normal user cannot unlink their contents, so the
  # removal itself must escalate. Doing it unprivileged would half-delete the
  # tree and leave the rest behind. An ARRAY on purpose: a quoted empty
  # string ("$su") would be executed as a command name and fail with 127.
  local su=()
  if [[ "$(id -u)" != 0 ]]; then
    command -v sudo >/dev/null 2>&1 \
      || { bad "$p holds files owned by the container users; removing them needs sudo, which is not available."; exit 1; }
    su=(sudo)
    # Authenticate up front so the password prompt has an obvious cause, and a
    # failure is reported by name instead of as a failed rm three prompts later.
    sudo -v || { bad "sudo authentication failed; cannot remove $p."; exit 1; }
  fi
  if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$p"; then
    note "$p is a mount point: removing its contents only, not the mount point"
    "${su[@]}" find "$p" -mindepth 1 -delete \
      || { bad "the removal of $p failed — see the output above."; exit 1; }
  else
    "${su[@]}" rm -rf -- "$p" \
      || { bad "the removal of $p failed — see the output above."; exit 1; }
  fi
  # Never trust the exit status alone: prove the tree is actually gone.
  if [[ -e "$p" ]] || { command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$p" \
       && [[ -n "$(ls -A "$p" 2>/dev/null)" ]]; }; then
    bad "$p still exists after the removal — refusing to continue."
    exit 1
  fi
  ok "removed $p"
}
run_stage3() {
  section "Stage 3/4 — purge the host data"
  note "this deletes ALL previous backups: $(backup_count) under $BACKUP_PATH"
  if [[ -e "$LIVE_PATH" && -e "$BACKUP_PATH" ]]; then
    if [[ "$LIVE_PATH" == "$BACKUP_PATH"/* || "$BACKUP_PATH" == "$LIVE_PATH"/* ]]; then
      bad "the two data roots overlap; refusing to delete either."
      exit 1
    fi
  fi
  # Decide the whole stage first, gate once, then execute.
  local targets=() parent=""
  if [[ -e "$LIVE_PATH" ]]; then targets+=("$LIVE_PATH"); note "will delete: $LIVE_PATH"; fi
  if [[ -e "$BACKUP_PATH" ]]; then targets+=("$BACKUP_PATH"); note "will delete: $BACKUP_PATH"; fi
  # If both roots were the defaults, the parent ~/.open-webui is ours too.
  if [[ "$LIVE_PATH" == "$HOME/.open-webui/live-data" && "$BACKUP_PATH" == "$HOME/.open-webui/backup-data" \
        && -d "$HOME/.open-webui" && -z "$(ls -A "$HOME/.open-webui" 2>/dev/null)" ]]; then
    parent="$HOME/.open-webui"
    note "will delete the empty parent: $parent"
  fi
  if [[ -f "$ENV_FILE" ]]; then
    targets+=("$ENV_FILE")
    note "will delete: $ENV_FILE (site values for this stack)"
  fi
  if [[ -f "$REPO_ROOT/secrets.manifest" ]]; then
    targets+=("$REPO_ROOT/secrets.manifest")
    note "will delete: $REPO_ROOT/secrets.manifest (Secret fingerprints)"
  fi
  if (( ${#targets[@]} == 0 && -z "$parent" )); then
    ok "stage 3 complete: nothing left to remove"
    return
  fi
  purge_root "$LIVE_PATH"
  purge_root "$BACKUP_PATH"
  if [[ -n "$parent" ]]; then
    rmdir -- "$parent"
    ok "removed the empty $parent"
  fi
  if [[ -f "$ENV_FILE" ]]; then
    rm -f -- "$ENV_FILE"
    ok "removed $ENV_FILE"
  fi
  if [[ -f "$REPO_ROOT/secrets.manifest" ]]; then
    rm -f -- "$REPO_ROOT/secrets.manifest"
    ok "removed $REPO_ROOT/secrets.manifest"
  fi
  ok "stage 3 complete: the host data is gone"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Stage 4 — the host itself (sudo)
# ═══════════════════════════════════════════════════════════════════════════
SUDO=()   # array on purpose: a quoted empty string would be executed as a command name (exit 127)
run_stage4() {
  section "Stage 4/4 — purge the host (K3s, helm, packages, files, swap)"
  if [[ "$(id -u)" == 0 ]]; then
    ok "already running as root; no sudo step"
  else
    command -v sudo >/dev/null 2>&1 || { bad "not root and no sudo available; stage 4 needs root."; exit 1; }
    SUDO=(sudo)
  fi

  # Decide the whole stage first, gate once, then execute everything.
  local k3s="" f p
  if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
    k3s=script
  elif systemctl list-unit-files 2>/dev/null | grep -q '^k3s\.service'; then
    k3s=unit
  fi
  local files=()
  if [[ -f /usr/local/bin/k3s ]]; then files+=(/usr/local/bin/k3s); fi
  if [[ -d /etc/rancher ]]; then files+=(/etc/rancher); fi
  if [[ -f /usr/local/bin/helm ]]; then files+=(/usr/local/bin/helm); fi
  # The bootstrap's config drop-ins. Modules stay loaded until the next reboot;
  # the sysctl values stay at 1 until `sysctl --system` or a reboot — both are
  # harmless without K3s, so this script does not fight the kernel.
  for f in /etc/modules-load.d/k3s.conf /etc/sysctl.d/99-k3s.conf; do
    if [[ -f "$f" ]]; then files+=("$f"); fi
  done

  # apt packages: remove only what nothing installed depends on; list the rest.
  local remove=()
  for p in "${BOOTSTRAP_PKGS[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
      note "package $p: not installed; nothing to do"
      continue
    fi
    if [[ " ${REPO_TOOLING_PKGS[*]} " == *" $p "* ]]; then
      note "package $p: KEPT — the repo's own scripts need it"
      continue
    fi
    local cascade; cascade="$(pkg_cascade "$p")"
    if [[ -n "$cascade" ]]; then
      note "package $p: KEPT — other host packages depend on it (removing it would take: $(cascade_summary "$cascade"))"
    else
      remove+=("$p")
    fi
  done

  # Swap: the bootstrap commented the fstab lines (as `#/dev/... swap sw` — the
  # # sticks to the path, no space) and left /etc/fstab.bak. Re-enable only when
  # a commented swap line is present.
  local swap=0
  if [[ -f /etc/fstab ]] && ! swapon --noheadings 2>/dev/null | grep -q .; then
    if grep -qE '^[[:space:]]*#.*[[:space:]]+swap[[:space:]]' /etc/fstab; then
      swap=1
    else
      note "no commented swap line in fstab; swap was never on this host"
    fi
  else
    note "swap is active or already off-without-a-commented-line; left as is"
  fi

  if [[ -z "$k3s" ]] && (( ${#files[@]} == 0 && ${#remove[@]} == 0 && swap == 0 )); then
    ok "stage 4 complete: nothing left to remove"
    return
  fi
  case "$k3s" in
    script) note "will run the official K3s uninstall (stops the cluster, removes /var/lib/rancher)" ;;
    unit)   note "will remove the K3s service (no official uninstall script found)" ;;
  esac
  (( ${#files[@]} )) && note "will remove: ${files[*]}"
  (( ${#remove[@]} )) && note "will apt-remove: ${remove[*]}"
  (( swap )) && note "will re-enable swap (uncomment the fstab line and swapon)"
  if (( ${#SUDO[@]} )); then sudo -v; ok "sudo ready"; fi

  # Execute. K3s: the official uninstall script stops the service and removes
  # /var/lib/rancher/{k3s,k10}, the systemd unit and the CNI config.
  case "$k3s" in
    script)
      "${SUDO[@]}" /usr/local/bin/k3s-uninstall.sh
      ok "K3s uninstalled" ;;
    unit)
      "${SUDO[@]}" systemctl disable --now k3s
      "${SUDO[@]}" rm -rf /var/lib/rancher/k3s /var/lib/rancher/k10 /etc/systemd/system/k3s.service
      "${SUDO[@]}" rm -f /etc/cni/net.d/10-k3s.conflist
      "${SUDO[@]}" systemctl daemon-reload
      ok "K3s service removed" ;;
  esac
  if (( ${#files[@]} )); then
    "${SUDO[@]}" rm -rf -- "${files[@]}"
    ok "removed: ${files[*]}"
  fi
  if (( ${#remove[@]} )); then
    "${SUDO[@]}" apt-get remove -y "${remove[@]}"
    ok "removed: ${remove[*]}"
    note "auto-installed dependencies of the kept packages were left in place"
  fi
  if (( swap )); then
    # `[^#]` (not `[[:space:]]`) so the bootstrap's own no-space form matches;
    # only claim success if swap is actually active afterwards.
    "${SUDO[@]}" sed -E -i 's|^#([^#].*\s+swap\s)|\1|' /etc/fstab
    if "${SUDO[@]}" swapon -a && swapon --noheadings 2>/dev/null | grep -q .; then
      [[ -f /etc/fstab.bak ]] && "${SUDO[@]}" rm -f /etc/fstab.bak
      ok "swap re-enabled"
    else
      bad "the fstab line is uncommented but swapon did not activate swap — check the swap device manually (/etc/fstab.bak is kept)"
      exit 1
    fi
  fi

  ok "stage 4 complete: the host is back to how it was before the bootstrap"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Drive
# ═══════════════════════════════════════════════════════════════════════════
require_predecessors() { # <stage>
  local s="$1"
  if (( s == 2 )) && ! stage1_done; then
    bad "stage 1 is not done: the releases are still installed. Run ./deploy/uninstall.sh first (or stage 1)."
    exit 1
  fi
  if (( s >= 3 )) && ! stage1_done; then
    bad "stage 1 is not done: the releases are still installed, so the data is still in use."
    exit 1
  fi
  if (( s == 3 )) && ! stage2_done; then
    bad "stage 2 is not done: the cluster objects still exist."
    exit 1
  fi
  if (( s == 4 )) && ! stage3_done; then
    bad "stage 3 is not done: the host data still exists. Deleting K3s while the data tree lives is not a cleanup."
    exit 1
  fi
}

if [[ -n "$STAGE" ]]; then
  require_predecessors "$STAGE"
  # if/else, not `&& ... || run_stageN`: a stage called on the right of && or
  # || runs with errexit disabled, so a failed deletion inside it would print
  # "complete" anyway.
  case "$STAGE" in
    1) if stage1_done; then echo "Stage 1 already done."; exit 0; else arith_gate "stage 1 — the release uninstall (data KEPT, Retain PVs)"; run_stage1; fi ;;
    2) if stage2_done; then echo "Stage 2 already done."; exit 0; else arith_gate "stage 2 — the cluster objects (PVs, PVCs, StorageClass)"; run_stage2; fi ;;
    3) if stage3_done; then echo "Stage 3 already done."; exit 0; else arith_gate "stage 3 — the host data (both data roots and the .env)"; run_stage3; fi ;;
    4) if stage4_done; then echo "Stage 4 already done."; exit 0; else arith_gate "stage 4 — the host itself (K3s, helm, packages, files, swap)"; run_stage4; fi ;;
  esac
  echo
  echo "OK: stage $STAGE complete."
  exit 0
fi

# ── Stage 0 — the safety backup offer (sequential mode) ─────────────────────
run_preamble() {
  section "Stage 0/4 — safety backup before uninstalling (optional)"
  # A bundle only makes sense while there is a deployment to capture.
  if [[ ! -f "$ENV_FILE" ]]; then
    note "no .env to bundle (already removed, or never created) — skipping the offer"
    note "the remaining stages need nothing from it; they work from defaults"
    return 0
  fi
  if stage1_done; then
    note "the stack is already uninstalled — a bundle now would miss the live"
    note "cluster anyway; skipping the offer. Run ./deploy/backup.sh directly if"
    note "you still want one before the remaining stages run."
    return 0
  fi
  note "This is the only complete, portable restore of the current deployment:"
  note "it carries .env (every credential and site value) and is encrypted with"
  note "a passphrase. The nightly archives under $BACKUP_PATH"
  note "hold $(backup_count) and are unencrypted and older than today."
  printf '  Create a backup bundle before uninstalling? [Y/n] '
  local ans dest
  read -r ans
  case "${ans,,}" in
    n|no)
      note "proceeding WITHOUT a bundle: after stage 3 the only backups left are"
      note "the nightly archives (no .env), and after stage 4 nothing at all."
      return 0
      ;;
  esac
  printf '  Destination directory for the bundle [%s]: ' "$HOME"
  read -r dest
  dest="${dest:-$HOME}"
  dest="${dest/#\~/$HOME}"   # [[ -d ]] does not expand a typed tilde
  [[ -d "$dest" ]] || { bad "destination $dest does not exist."; exit 1; }
  "$SCRIPT_DIR/backup.sh" --dest "$dest"
  ok "stage 0 complete: the bundle is the only thing standing between you and a clean host"
}

# Sequential mode is interactive by design: the preamble, the between-stage
# questions and every gate read stdin. Fail with a message instead of dying
# silently on the first read when stdin is not a terminal.
[[ -t 0 ]] || { bad "no interactive terminal; the staged uninstall needs one. See --check for the plan."; exit 1; }

# Sequential mode: after each stage, a plain yes/no decides whether to continue.
# Default is stop, so a lost terminal cannot cascade into stage 4.
stage_summary() { # <stage number> — what the next stage WILL do, kept in step
  # with run_stage1..4 below; the y/N is only meaningful if it names the blast
  # radius before asking.
  case "$1" in
    1) printf '     helm-uninstall the releases ai-open-webui and postgres.\n'
       printf '     Nothing is deleted: the PVs are Retain and no host path is touched.\n' ;;
    2) printf '     delete the cluster objects the releases do not own: the open-webui\n'
       printf '     PV + PVC, the postgres/searxng PVs and PVCs, the local-storage\n'
       printf '     StorageClass, and the THREE CREDENTIAL SECRETS (postgres,\n'
       printf '     ai-open-webui-secrets, ai-open-webui-searxng).\n'
       printf '     Host directories are still untouched.\n' ;;
    3) printf '     DELETE HOST DATA: the LIVE_DATA_PATH and BACKUP_DATA_PATH trees\n'
       printf '     (database, uploads, vector store, AND every nightly archive), the\n'
       printf '     .env file, and secrets.manifest. Needs sudo. After this, the only\n'
       printf '     recovery is an encrypted backup bundle.\n' ;;
    4) printf '     RETURN THE HOST TO PRE-BOOTSTRAP: uninstall K3s and helm, remove\n'
       printf '     /etc/rancher, the k3s module/sysctl drop-ins, and the bootstrap apt\n'
       printf '     packages nothing else depends on, and re-enable swap. Needs sudo.\n'
       printf '     The repository files on disk are left alone.\n' ;;
  esac
}
continue_to() { # <next stage number>
  local ans
  printf '\n  Continue to stage %s (of 4)? It will:\n' "$1"
  stage_summary "$1"
  printf '  Continue to stage %s? [y/N] ' "$1"
  read -r ans
  case "${ans,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}
stopped() { # <stage just finished>
  note "stopped after stage $1; the rest are available: ./deploy/uninstall.sh $(( $1 + 1 ))"
  echo
  echo "OK: uninstall finished where you stopped it."
  exit 0
}
# A rerun after a partial run continues where it left off: a stage whose work
# is already done is skipped, and no continue question is wasted on it.
run_preamble

# One gate per run, before the first stage that still has work to do.
first_pending() {
  if stage1_done; then :; else echo 1; return; fi
  if stage2_done; then :; else echo 2; return; fi
  if stage3_done; then :; else echo 3; return; fi
  if stage4_done; then :; else echo 4; return; fi
  echo 5
}
FP="$(first_pending)"
case "$FP" in
  1) arith_gate "the full uninstall — stages 1-4 (releases, cluster objects, host data, the host itself)" ;;
  2) arith_gate "the remaining uninstall — stages 2-4 (cluster objects, host data, the host itself)" ;;
  3) arith_gate "the remaining uninstall — stages 3-4 (host data, then the host itself)" ;;
  4) arith_gate "the remaining uninstall — stage 4 (the host itself)" ;;
  5) ok "all four stages are already complete — nothing to do"; exit 0 ;;
esac

if stage1_done; then
  note "stage 1 already complete — skipping"
else
  run_stage1
  continue_to 2 || stopped 1
fi
if stage2_done; then
  note "stage 2 already complete — skipping"
else
  run_stage2
  continue_to 3 || stopped 2
fi
if stage3_done; then
  note "stage 3 already complete — skipping"
else
  run_stage3
  continue_to 4 || stopped 3
fi
if stage4_done; then
  note "stage 4 already complete — skipping"
else
  run_stage4
fi
echo
echo "OK: uninstall finished: all four stages complete."
