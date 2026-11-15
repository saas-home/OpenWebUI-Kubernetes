#!/usr/bin/env bash
# Root-side host installation for the Open WebUI stack. RUN WITH SUDO:
#
#   sudo ./deploy/bootstrap-root.sh --node-name NAME
#
# This is the only script in the repo that changes the host. It performs the
# steps the main entry point (deploy/bootstrap-host.sh, which runs as your
# normal user) cannot: apt packages, kernel modules, sysctl keys, swap
# disabling, the K3s install, and the helm v4 binary. bootstrap-host.sh
# VALIDATES that each of these is done and points here when it is not.
#
# What it DOES (all idempotent; safe to re-run):
#   1. apt packages (curl git python3 openssl)
#   2. kernel modules (overlay, br_netfilter) + /etc/modules-load.d/k3s.conf
#   3. sysctl bridge/ip_forward keys + /etc/sysctl.d/99-k3s.conf
#   4. swap: swapoff -a and comment the fstab entry. The kubelet refuses to
#      start with swap enabled (failSwapOn default), so this is a hard
#      prerequisite, not a tuning knob.
#   5. K3s with --disable traefik, --secrets-encryption and a pinned --node-name
#   6. helm v4 (the deploy scripts pass --dry-run=client and --hide-secret,
#      which helm 3 lacks; a v3 binary would print credentials in a dry run)
#
# What it will NOT do: partition disks, format, create filesystems, or mount
# anything. The data paths (LIVE_DATA_PATH and BACKUP_DATA_PATH in .env, which
# default to ~/.open-webui/live-data and ~/.open-webui/backup-data) are
# plain directories the user may provide however they like -- a second disk,
# an LVM volume, a bind mount, or even a directory on the root filesystem.
# Two separate paths are required; a single physical device is accepted with
# an advisory (see README, "Production recommendation").
#
# Usage:
#   sudo ./deploy/bootstrap-root.sh --node-name NAME
#   sudo ./deploy/bootstrap-root.sh                  # prompts; defaults to hostname -s,
#                                                    # or the existing cluster's node name
#   sudo ./deploy/bootstrap-root.sh --check          # report only; changes nothing
#   sudo ./deploy/bootstrap-root.sh --no-k3s         # skip the K3s install
#   sudo ./deploy/bootstrap-root.sh --no-helm        # skip the helm install
set -euo pipefail

NODE_NAME=""
CHECK_ONLY=0
SKIP_K3S=0
SKIP_HELM=0
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  arg="${args[i]}"
  case "$arg" in
    -h|--help)
      awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "${BASH_SOURCE[0]}" >&2
      exit 0
      ;;
    --node-name)
      if (( i + 1 >= ${#args[@]} )) || [[ "${args[i+1]}" == --* ]]; then
        echo "ERROR: --node-name requires a value." >&2
        exit 2
      fi
      if [[ -n "$NODE_NAME" ]]; then
        echo "ERROR: --node-name given twice: '$NODE_NAME' and '${args[i+1]}'." >&2
        exit 2
      fi
      NODE_NAME="${args[i+1]}"
      i=$((i + 2))
      continue
      ;;
    --node-name=*)
      if [[ -n "$NODE_NAME" ]]; then
        echo "ERROR: --node-name given twice (value: '${arg#--node-name=}')." >&2
        exit 2
      fi
      NODE_NAME="${arg#--node-name=}"
      ;;
    --check)    CHECK_ONLY=1 ;;
    --no-k3s)   SKIP_K3S=1 ;;
    --no-helm)  SKIP_HELM=1 ;;
    *)
      if [[ "$arg" == --* ]]; then
        echo "ERROR: unknown argument '$arg'." >&2
        exit 2
      fi
      if [[ -z "$NODE_NAME" ]]; then
        NODE_NAME="$arg"
      else
        echo "ERROR: two node names given: '$NODE_NAME' and '$arg'." >&2
        exit 2
      fi
      ;;
  esac
  i=$((i + 1))
done

errors=()
warnings=0
ok()   { printf '  OK    %s\n' "$1"; }
note() { printf  '  --    %s\n' "$1"; }
ask()  { printf  '  TODO  %s\n' "$1"; }
bad()  { errors+=("$1"); printf '  FAIL  %s\n' "$1" >&2; }
warn() { warnings=$((warnings + 1)); printf '  WARN  %s\n' "$1"; }

section() {
  echo
  echo "══════════════════════════════════════════════════════════════════════"
  echo "  $1"
  echo "══════════════════════════════════════════════════════════════════════"
}

run() {
  if (( CHECK_ONLY )); then
    ask "would run: $*"
    return 0
  fi
  echo "        + $*"
  "$@"
}

# ── 0. Root ──────────────────────────────────────────────────────────────────
# This script is the root half of the bootstrap; everything it does needs uid 0.
# bootstrap-host.sh is the non-root half and never calls sudo. --check only
# reads, so it is allowed without root.
if [[ "$(id -u)" != 0 ]] && (( ! CHECK_ONLY )); then
  echo "ERROR: this script changes the host and must run as root." >&2
  echo "       Run: sudo $0 ${NODE_NAME:+--node-name $NODE_NAME}" >&2
  exit 1
fi

# ── 1. Node name ─────────────────────────────────────────────────────────────
section "Node name"
# Every local PV pins nodeAffinity to the K3s node name, which is NOT necessarily
# what `hostname` prints. If K3s is already installed, the cluster's answer is
# authoritative and overriding it here would mean recreating the PVs later.
if [[ -z "$NODE_NAME" ]]; then
  if systemctl is-active --quiet k3s 2>/dev/null && command -v kubectl >/dev/null 2>&1; then
    existing=$(kubectl get nodes -o name 2>/dev/null | sed 's|^node/||' | head -1 || true)
    if [[ -n "$existing" ]]; then
      NODE_NAME="$existing"
      note "K3s is already installed; using its node name '$NODE_NAME' (from the cluster)."
    fi
  fi
  if [[ -z "$NODE_NAME" ]]; then
    suggested=$(hostname -s)
    if (( CHECK_ONLY )); then
      ask "no --node-name given; would default to '$suggested'."
      NODE_NAME="$suggested"
    elif [[ -t 0 ]]; then
      read -r -p "  K3s node name [${suggested}]: " NODE_NAME || true
      NODE_NAME=${NODE_NAME:-$suggested}
    else
      NODE_NAME="$suggested"
      note "no terminal; defaulting node name to '$NODE_NAME'. Pass --node-name to choose."
    fi
  fi
fi
# Reject names the kubelet would refuse or that would break the PV template.
# Exit before any change: section 5 interpolates the name into a shell command.
if [[ ! "$NODE_NAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
  bad "node name '$NODE_NAME' is not a valid lowercase RFC 1123 hostname; use lowercase letters, digits, '-' and '.'."
  echo "Stopped before any change." >&2
  exit 1
fi
ok "node name: $NODE_NAME"

# ── 2. Packages ──────────────────────────────────────────────────────────────
section "Packages"
missing_pkgs=()
for pkg in curl git python3 openssl; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then missing_pkgs+=("$pkg"); fi
done
if (( ${#missing_pkgs[@]} )); then
  run apt-get update
  run apt-get install -y "${missing_pkgs[@]}"
else
  ok "curl, git, python3, openssl already installed"
fi

# ── 3. Kernel modules + sysctl ───────────────────────────────────────────────
section "Kernel modules and sysctl"
for mod in overlay br_netfilter; do
  # Built-in modules (CONFIG_...=y) are absent from lsmod but present in
  # /sys/module. modprobe on one succeeds as a no-op, so both branches are safe;
  # checking sysfs first just avoids a misleading "modprobe" line in the plan.
  if lsmod | grep -q "^${mod} " || [[ -d "/sys/module/$mod" ]]; then
    ok "$mod is available (loaded or built into the kernel)"
  else
    run modprobe "$mod"
  fi
done
# Make them survive a reboot.
run install -d -m 0755 /etc/modules-load.d /etc/sysctl.d
if [[ -f /etc/modules-load.d/k3s.conf ]] && grep -q overlay /etc/modules-load.d/k3s.conf; then
  ok "/etc/modules-load.d/k3s.conf exists"
else
  run tee /etc/modules-load.d/k3s.conf >/dev/null <<< $'overlay\nbr_netfilter'
fi

sysctl_missing=0
for key in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward; do
  [[ "$(sysctl -n "$key" 2>/dev/null)" == "1" ]] || sysctl_missing=1
done
if [[ -f /etc/sysctl.d/99-k3s.conf ]] && (( ! sysctl_missing )); then
  ok "/etc/sysctl.d/99-k3s.conf present and keys are 1"
else
  run tee /etc/sysctl.d/99-k3s.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  run sysctl --system
fi

# ── 4. Swap ──────────────────────────────────────────────────────────────────
section "Swap"
# The kubelet refuses to start with swap enabled unless failSwapOn is turned
# off, which this stack does not do. Disabling is idempotent and reversible:
# the fstab line is commented, not deleted, and the swapon command that
# re-enables it is printed.
if swapon --noheadings 2>/dev/null | grep -q .; then
  if (( CHECK_ONLY )); then
    ask "swap is active; would run swapoff -a and comment the fstab entries."
  else
    run swapoff -a
    # Comment every active (uncommented, non-noauto) swap fstab line.
    # The .bak suffix is not ceremony: a botched expression here leaves the host
    # without a usable fstab after the next reboot, and the backup is the way back.
    if [[ -f /etc/fstab ]] && grep -vE '^\s*#' /etc/fstab | grep -qE '[^ ]+\s+none\s+swap|\s+swap\s'; then
      run sed -i.bak -E 's|^([^#].*\s+swap\s)|#\1|' /etc/fstab
    fi
    ok "swap disabled and commented out of /etc/fstab"
    echo "        (to re-enable: sudo swapon /swap/img, or uncomment the fstab line)"
  fi
else
  ok "swap is off"
fi
if [[ -f /etc/fstab ]] && grep -vE '^\s*#' /etc/fstab | grep -qE '\s+swap\s'; then
  warn "fstab still has an active swap entry; swap will return after a reboot and the kubelet will refuse to start."
fi

# ── 5. K3s ───────────────────────────────────────────────────────────────────
section "K3s"
if (( SKIP_K3S )); then
  note "--no-k3s given; skipping the K3s install."
elif systemctl is-active --quiet k3s 2>/dev/null; then
  ok "k3s service is already running"
  if [[ -f /etc/rancher/k3s/k3s.yaml ]] && (( $(stat -c '%a' /etc/rancher/k3s/k3s.yaml 2>/dev/null || echo 0) == 600 )); then
    run chmod 644 /etc/rancher/k3s/k3s.yaml
  fi
  # `k3s secrets-encrypt status` prints "Encryption Status: Enabled" or
  # "Encryption Status: Disabled" (plus ", no configuration file found" when the
  # flag was never passed) and exits 0 either way, so the text is what decides.
  # It reads the root-only server token, so a non-root --check gets nothing back
  # and must not report encryption as off.
  if enc_status=$(k3s secrets-encrypt status 2>/dev/null); then
    case "$enc_status" in
      "Encryption Status: Enabled"*)
        ok "K3s secrets encryption at rest is enabled" ;;
      *)
        warn "K3s secrets encryption is not active. Enabling it on an existing cluster is a multi-step procedure: k3s secrets-encrypt enable, add --secrets-encryption to the server args, restart k3s, then k3s secrets-encrypt rotate-keys (https://docs.k3s.io/security/secrets-encryption)." ;;
    esac
  else
    note "could not read K3s secrets-encryption status (needs root and a running server); re-run with sudo to check it."
  fi
  if ! kubectl get nodes -l "kubernetes.io/hostname=$NODE_NAME" -o name 2>/dev/null | grep -q .; then
    warn "k3s is running but no node is labelled kubernetes.io/hostname=$NODE_NAME. The node registered under a different name; either pass --node-name matching 'kubectl get nodes', or recreate the cluster with this name — PV nodeAffinity is immutable."
  fi
else
  if command -v k3s >/dev/null 2>&1 || [[ -x /usr/local/bin/k3s ]]; then
    ask "k3s binary exists but the service is not active. Inspect: systemctl status k3s"
  else
    # --disable traefik: nothing here uses in-cluster ingress; TLS is external.
    # --write-kubeconfig-mode 644: lets unprivileged users on the host run kubectl.
    # --secrets-encryption: encrypts Kubernetes Secrets with AES-256 at rest in the datastore.
    # --node-name: becomes the kubernetes.io/hostname label every local PV matches.
    # NODE_NAME is regex-validated above, so interpolating it here is safe; the
    # inner pipefail is not cosmetic — without it a failed curl leaves sh reading
    # empty stdin, the pipeline exits 0, and the script proceeds with no K3s.
    run bash -c "set -o pipefail; curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server --disable traefik --write-kubeconfig-mode 644 --secrets-encryption --node-name $NODE_NAME' sh -"
  fi
fi

# ── 5b. kubeconfig sync ──────────────────────────────────────────────────────
# The official K3s installer creates ~/.kube/config only when the file does
# not exist. A K3s REinstall mints a new cluster CA, so the stale kubeconfig
# left behind makes helm (which reads the default ~/.kube/config) fail every
# command with "certificate signed by unknown authority" — while kubectl in
# this repo still works, because it is pointed at /etc/rancher/k3s/k3s.yaml.
# When the CAs differ, the stale file is kept aside, never edited: it may
# hold contexts for other clusters.
if systemctl is-active --quiet k3s 2>/dev/null && [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
  section "kubeconfig"
  kube_user="${SUDO_USER:-root}"
  kube_home="$(getent passwd "$kube_user" | cut -d: -f6)"
  if [[ -z "$kube_home" ]]; then
    note "could not resolve the home of user '$kube_user'; sync ~/.kube/config from /etc/rancher/k3s/k3s.yaml manually if helm cannot reach the cluster"
  else
    new_ca="$(grep 'certificate-authority-data' /etc/rancher/k3s/k3s.yaml | head -1)"
    cur_ca=""
    [[ -f "$kube_home/.kube/config" ]] && cur_ca="$(grep 'certificate-authority-data' "$kube_home/.kube/config" | head -1)"
    if [[ "$new_ca" != "$cur_ca" ]]; then
      if [[ -n "$cur_ca" ]]; then
        note "the existing ~/.kube/config belongs to a previous cluster (its CA no longer matches); keeping it aside"
        run mv "$kube_home/.kube/config" "$kube_home/.kube/config.pre-k3s-reinstall.$(date +%Y%m%d_%H%M%S)"
      fi
      run install -m 600 -o "$kube_user" -g "$(id -gn "$kube_user")" /etc/rancher/k3s/k3s.yaml "$kube_home/.kube/config"
      ok "installed $kube_user/.kube/config from /etc/rancher/k3s/k3s.yaml"
    else
      ok "$kube_user/.kube/config matches the running cluster"
    fi
  fi
fi

# ── 6. Helm ──────────────────────────────────────────────────────────────────
section "Helm (must be v4)"
if (( SKIP_HELM )); then
  note "--no-helm given; skipping the helm install."
else
  helm_ver=$(helm version --short 2>/dev/null | sed -E 's/^v?([0-9]+).*/\1/' || true)
  if [[ -n "$helm_ver" ]] && (( helm_ver >= 4 )); then
    ok "helm $(helm version --short 2>/dev/null) found"
  elif [[ -n "$helm_ver" ]]; then
    bad "helm ${helm_ver}.x is installed but the deploy scripts pass --dry-run=client and --hide-secret, which need helm 4. Upgrade manually: sudo snap refresh helm, or replace the binary in /usr/local/bin."
  else
    latest=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])' 2>/dev/null || true)
    if [[ -z "$latest" ]]; then
      bad "could not determine the latest helm release from GitHub. Install helm 4 manually and re-run."
    elif [[ "$latest" != v4* ]]; then
      bad "the latest helm release is $latest, not v4. The deploy scripts need v4 flags; install the v4 binary manually."
    elif [[ ! "$latest" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      # The tag comes from an unauthenticated API response and is about to be
      # embedded in a download URL and two file names — anything but a plain
      # version is rejected before it reaches curl.
      bad "the GitHub API returned an unexpected helm tag: '$latest'. Install helm 4 manually and re-run."
    else
      if (( CHECK_ONLY )); then
        ask "would download and install helm $latest to /usr/local/bin (sha256-verified)"
      else
        echo "        installing helm $latest to /usr/local/bin"
        # The digest ships next to the tarball. Piping curl straight into tar
        # left no file to verify, so a CDN or mirror swap would have installed
        # unchecked bytes as root into /usr/local/bin.
        helm_tmp=$(mktemp -d)
        if ! ( cd "$helm_tmp" \
             && curl -fsSL -O "https://get.helm.sh/helm-${latest}-linux-amd64.tar.gz" \
             && curl -fsSL -O "https://get.helm.sh/helm-${latest}-linux-amd64.tar.gz.sha256sum" \
             && sha256sum --check --quiet "helm-${latest}-linux-amd64.tar.gz.sha256sum" ); then
          rm -rf "$helm_tmp"
          bad "the helm $latest tarball failed its sha256 check (or the digest could not be fetched). Nothing was installed; do not work around this — install helm 4 manually from a source you trust."
        else
          tar -xz -C /usr/local/bin --strip-components=1 -f "$helm_tmp/helm-${latest}-linux-amd64.tar.gz" linux-amd64/helm
          rm -rf "$helm_tmp"
          ok "helm $latest installed (sha256 verified)"
        fi
      fi
    fi
  fi
fi

# ── 7. Report ────────────────────────────────────────────────────────────────
echo
if (( warnings )); then
  echo "$warnings warning(s) recorded above. They do not block, but read them."
fi
if (( ${#errors[@]} )); then
  echo
  echo "Stopped: ${#errors[@]} blocking problem(s):" >&2
  for e in "${errors[@]}"; do echo "  - $e" >&2; done
  exit 1
fi

if (( CHECK_ONLY )); then
  echo
  echo "OK: --check found no blocking problems. Nothing was changed."
  exit 0
fi

echo
echo "OK: host installation complete. Continue as your normal user:"
echo "    ./deploy/bootstrap-host.sh --node-name $NODE_NAME"
