#!/usr/bin/env bash
set -u

# Purpose:
# - Update and install essential tools.
# - Set up a simple, safe firewall for desktop use.
# - Optionally install a few extra apps and enable sudo password feedback.
# - Continue running even if something fails, then show a clear summary.
#
# Logging:
# - All output is captured while the script runs.
# - A log file (setup.log) is only saved if something fails
#   or if --log is used.

SCRIPT_NAME="setup"
LOG_NAME="setup.log"

# ----------------------------
# Options
# ----------------------------
FLAG_LOG=0
FLAG_PWFEEDBACK=0
FLAG_BRAVE=0
FLAG_MULLVAD=0          # Mullvad VPN + Mullvad Browser
FLAG_RUSTDESK=0         # RustDesk remote desktop client
FLAG_VSCODIUM=0         # VSCodium
FLAG_DOCKER=0           # Docker Engine

DOCKER_OK=0

# ----------------------------
# Helper functions
# ----------------------------
usage() {
  cat <<'EOF'
Usage:
  sudo ./setup.sh [flags]

Flags:
  --log           Keep setup.log even if no errors occur
  --pwfeedback    Enable sudo password feedback
  --brave         Install Brave browser
  --mullvad       Install Mullvad VPN and Mullvad Browser
  --rustdesk      Install RustDesk
  --vscodium      Install VSCodium
  --docker        Install Docker Engine

Examples:
  sudo ./setup.sh
  sudo ./setup.sh --pwfeedback
  sudo ./setup.sh --brave --mullvad --vscodium
  sudo ./setup.sh --rustdesk --docker
EOF
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[$SCRIPT_NAME] ERROR: This script must be run as root (use sudo)."
    exit 1
  fi
}

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

log_banner() { echo "[$(timestamp)] [$SCRIPT_NAME] $*"; }

step_banner() {
  echo
  echo "[$(timestamp)] [STEP] $*"
}

# ----------------------------
# Error handling
# ----------------------------
FAILED_STEPS=()
FAILED_CODES=()

record_failure() {
  local step="$1"
  local code="$2"
  FAILED_STEPS+=("$step")
  FAILED_CODES+=("$code")
  log_banner "ERROR: Step failed: $step (exit $code)"
  log_banner "Continuing execution."
}

run_step() {
  local step="$1"
  shift
  step_banner "$step"
  "$@"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    record_failure "$step" "$rc"
  fi
  return 0
}

run_step_sh() {
  local step="$1"
  local cmd="$2"
  step_banner "$step"
  bash -lc "$cmd"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    record_failure "$step" "$rc"
  fi
  return 0
}

# ----------------------------
# APT lock handling
# ----------------------------
wait_for_apt_locks() {
  local timeout_secs=600
  local interval_secs=2
  local start
  start="$(date +%s)"

  local locks=(
    "/var/lib/dpkg/lock"
    "/var/lib/dpkg/lock-frontend"
    "/var/lib/apt/lists/lock"
    "/var/cache/apt/archives/lock"
  )

  if command -v fuser >/dev/null 2>&1; then
    while :; do
      local locked=0
      local lf
      for lf in "${locks[@]}"; do
        if fuser "$lf" >/dev/null 2>&1; then
          locked=1
          break
        fi
      done

      if [[ $locked -eq 0 ]]; then
        return 0
      fi

      local now
      now="$(date +%s)"
      if (( now - start >= timeout_secs )); then
        log_banner "Package manager locks held for too long."
        return 1
      fi

      log_banner "Waiting for package manager locks..."
      sleep "$interval_secs"
    done
  else
    log_banner "Lock detection utility not found... proceeding without checks."
    sleep 5
    return 0
  fi
}

# ----------------------------
# Optional features
# ----------------------------
enable_pwfeedback() {
  local dest="/etc/sudoers.d/${SCRIPT_NAME}-pwfeedback"
  local tmp
  tmp="$(mktemp "/tmp/${SCRIPT_NAME}.sudoers.XXXXXX")" || return 1

  printf "Defaults pwfeedback\n" > "$tmp" || { rm -f "$tmp" 2>/dev/null || true; return 1; }

  if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$tmp" >/dev/null 2>&1 || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  fi

  install -m 0440 "$tmp" "$dest" || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

add_brave_repo() {
  curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
    https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg || return 1

  curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
    https://brave-browser-apt-release.s3.brave.com/brave-browser.sources || return 1

  return 0
}

add_mullvad_repo() {
  curl -fsSLo /usr/share/keyrings/mullvad-keyring.asc \
    https://repository.mullvad.net/deb/mullvad-keyring.asc || return 1

  local arch
  arch="$(dpkg --print-architecture)" || return 1

  echo "deb [signed-by=/usr/share/keyrings/mullvad-keyring.asc arch=${arch}] https://repository.mullvad.net/deb/stable stable main" \
    | tee /etc/apt/sources.list.d/mullvad.list >/dev/null || return 1

  return 0
}

install_rustdesk() {
  local arch asset_suffix api_url dl_url tmpdir deb_path

  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$arch" in
    amd64) asset_suffix="x86_64.deb" ;;
    arm64) asset_suffix="aarch64.deb" ;;
    *)
      log_banner "RustDesk install skipped: unsupported architecture '${arch}' (supported: amd64, arm64)."
      return 1
      ;;
  esac

  api_url="https://api.github.com/repos/rustdesk/rustdesk/releases/latest"

  # Pull the correct .deb URL from GitHub's latest release JSON.
  dl_url="$(
    API_URL="$api_url" ASSET_SUFFIX="$asset_suffix" python3 - <<'PY'
import json, os, sys, urllib.request
api_url = os.environ.get("API_URL", "")
suffix = os.environ.get("ASSET_SUFFIX", "")
req = urllib.request.Request(api_url, headers={"User-Agent": "setup-kali"})
with urllib.request.urlopen(req, timeout=30) as r:
    data = json.load(r)
for a in data.get("assets", []):
    name = a.get("name", "")
    if name.startswith("rustdesk-") and name.endswith(suffix):
        print(a.get("browser_download_url", ""))
        sys.exit(0)
sys.exit(1)
PY
  )" || dl_url=""

  if [[ -z "$dl_url" ]]; then
    log_banner "RustDesk install failed: could not find a matching '${asset_suffix}' asset in latest release."
    return 1
  fi

  tmpdir="$(mktemp -d "/tmp/${SCRIPT_NAME}.rustdesk.XXXXXX")" || return 1
  deb_path="${tmpdir}/rustdesk.deb"

  curl -fsSL "$dl_url" -o "$deb_path" || { rm -rf "$tmpdir" 2>/dev/null || true; return 1; }

  # Install via apt so dependencies are resolved.
  DEBIAN_FRONTEND=noninteractive apt-get install -fy "$deb_path" || { rm -rf "$tmpdir" 2>/dev/null || true; return 1; }

  rm -rf "$tmpdir" 2>/dev/null || true
  return 0
}

add_vscodium_repo() {
  install -d -m 0755 /usr/share/keyrings || return 1

  wget -qO - https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
    | gpg --dearmor \
    | dd of=/usr/share/keyrings/vscodium-archive-keyring.gpg status=none || return 1

  echo -e 'Types: deb\nURIs: https://download.vscodium.com/debs\nSuites: vscodium\nComponents: main\nArchitectures: amd64 arm64\nSigned-by: /usr/share/keyrings/vscodium-archive-keyring.gpg' \
    | tee /etc/apt/sources.list.d/vscodium.sources >/dev/null || return 1

  return 0
}

purge_docker_repo_entries() {
  # Remove any existing Docker repo entries so APT isn't blocked by stale suites like kali-rolling.
  local f
  for f in /etc/apt/sources.list.d/*docker* /etc/apt/sources.list.d/*Docker*; do
    [[ -e "$f" ]] || continue
    if grep -qi "download.docker.com" "$f" 2>/dev/null; then
      rm -f "$f" 2>/dev/null || true
    fi
  done
  return 0
}

get_docker_suite_trixie_or_bookworm() {
  # Kali reports VERSION_CODENAME=kali-rolling which doesn't work with Docker's Debian repo.
  # Only Debian 13 (trixie) and Debian 12 (bookworm) are supported for Docker in this script.
  local libc_ver
  libc_ver="$(apt-cache policy libc6 2>/dev/null | awk '/Candidate:/ {print $2}' | cut -d- -f1)"

  case "$libc_ver" in
    2.42) echo "trixie" ;;
    2.36) echo "bookworm" ;;
    *)
      echo ""
      return 1
      ;;
  esac
}

install_docker_repo_and_key() {
  # Docker official Debian APT repo setup:
  # https://docs.docker.com/engine/install/debian/
  local suite="$1"

  apt-get update || return 1
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl || return 1

  install -m 0755 -d /etc/apt/keyrings || return 1
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc || return 1
  chmod a+r /etc/apt/keyrings/docker.asc || return 1

  tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${suite}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  return 0
}

remove_docker_repo_files() {
  rm -f /etc/apt/sources.list.d/docker.sources 2>/dev/null || true
  rm -f /etc/apt/keyrings/docker.asc 2>/dev/null || true
  return 0
}

install_docker() {
  DOCKER_OK=0
  purge_docker_repo_entries
  local suite=""
  suite="$(get_docker_suite_trixie_or_bookworm)" || {
    log_banner "Docker install: unable to infer Debian base suite (expected trixie or bookworm)."
    log_banner "Docker install skipped."
    return 1
  }

  # Remove conflicting unofficial packages if present (safe even if none are installed).
  DEBIAN_FRONTEND=noninteractive apt-get remove -y \
    docker.io docker-compose docker-doc podman-docker containerd runc \
    >/dev/null 2>&1 || true

  install_docker_repo_and_key "$suite" || { remove_docker_repo_files; return 1; }

  if ! apt-get update; then
    local alt=""
    if [[ "$suite" == "trixie" ]]; then alt="bookworm"; else alt="trixie"; fi

    log_banner "Docker repo suite '${suite}' failed. Trying '${alt}' once..."
    remove_docker_repo_files
    install_docker_repo_and_key "$alt" || { remove_docker_repo_files; return 1; }

    if ! apt-get update; then
      log_banner "Docker repo setup failed for both trixie and bookworm."
      remove_docker_repo_files
      return 1
    fi
  fi

  # Install Docker packages from Docker repo.
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
      remove_docker_repo_files
      return 1
    }

  local target_user="${SUDO_USER:-}"
  if [[ -n "$target_user" && "$target_user" != "root" ]]; then
    usermod -aG docker "$target_user" || return 1
  else
    log_banner "Docker installed. Skipping docker group change because no non-root invoking user was detected."
  fi

  DOCKER_OK=1
  return 0
}

cleanup_thumbnails() {
  local target_user="${SUDO_USER:-root}"
  local home_dir
  home_dir="$(getent passwd "$target_user" | cut -d: -f6)"

  if [[ -z "$home_dir" || ! -d "$home_dir" ]]; then
    return 0
  fi

  rm -rf "$home_dir/.cache/thumbnails" "$home_dir/.thumbnails"
  return 0
}

# ----------------------------
# Reading user options
# ----------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log) FLAG_LOG=1 ;;
      --pwfeedback) FLAG_PWFEEDBACK=1 ;;
      --brave) FLAG_BRAVE=1 ;;
      --mullvad) FLAG_MULLVAD=1 ;;
      --rustdesk) FLAG_RUSTDESK=1 ;;
      --vscodium) FLAG_VSCODIUM=1 ;;
      --docker) FLAG_DOCKER=1 ;;
      -h|--help) usage; exit 0 ;;
      *)
        echo "[$SCRIPT_NAME] ERROR: Unknown flag: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

# ----------------------------
# Script execution
# ----------------------------
main() {
  need_root
  parse_args "$@"

  local tmp_log
  tmp_log="$(mktemp "/tmp/${SCRIPT_NAME}.XXXXXX.log")"

  exec > >(tee -a "$tmp_log") 2>&1

  log_banner "Starting execution"
  log_banner "Flags: log=$FLAG_LOG pwfeedback=$FLAG_PWFEEDBACK brave=$FLAG_BRAVE mullvad=$FLAG_MULLVAD rustdesk=$FLAG_RUSTDESK vscodium=$FLAG_VSCODIUM docker=$FLAG_DOCKER"

  run_step "Wait for package manager locks" wait_for_apt_locks
  run_step "Remove old Docker repo entries" purge_docker_repo_entries
  run_step_sh "APT update" "apt-get update"

  run_step_sh "APT upgrade" "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y"

  local pkgs=(
    curl wget git vlc
    ca-certificates gnupg software-properties-common
    btop net-tools ufw
    zip unzip p7zip-full
    vim timeshift
  )

  run_step_sh "Install baseline packages" "DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs[*]}"

  run_step_sh "Configure firewall defaults" "ufw default deny incoming && ufw default allow outgoing"
  run_step_sh "Enable firewall" "ufw --force enable"

  if [[ $FLAG_PWFEEDBACK -eq 1 ]]; then
    run_step "Enable sudo password feedback" enable_pwfeedback
  fi

  if [[ $FLAG_DOCKER -eq 1 ]]; then
    run_step "Install Docker Engine" install_docker
    if [[ $DOCKER_OK -eq 1 && -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
      log_banner "Note: Log out and back in (or reboot) to use docker without sudo (user: ${SUDO_USER})."
    fi
  fi

  local need_repo_update=0

  if [[ $FLAG_BRAVE -eq 1 ]]; then
    run_step "Add Brave repository" add_brave_repo
    need_repo_update=1
  fi

  if [[ $FLAG_MULLVAD -eq 1 ]]; then
    run_step "Add Mullvad repository" add_mullvad_repo
    need_repo_update=1
  fi

  if [[ $FLAG_VSCODIUM -eq 1 ]]; then
    run_step "Add VSCodium repository" add_vscodium_repo
    need_repo_update=1
  fi

  if [[ $need_repo_update -eq 1 ]]; then
    run_step_sh "APT update after repository changes" "apt-get update"
  fi

  if [[ $FLAG_BRAVE -eq 1 ]]; then
    run_step_sh "Install Brave browser" "apt-get install brave-browser"
  fi

  if [[ $FLAG_MULLVAD -eq 1 ]]; then
    run_step_sh "Install Mullvad VPN" "apt-get install mullvad-vpn"
    run_step_sh "Install Mullvad Browser" "apt-get install mullvad-browser"
  fi

  if [[ $FLAG_RUSTDESK -eq 1 ]]; then
    run_step "Install RustDesk" install_rustdesk
  fi
  
  if [[ $FLAG_VSCODIUM -eq 1 ]]; then
    run_step_sh "Install VSCodium" "apt-get install codium"
  fi

  run_step_sh "Remove unused packages" "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y"
  run_step_sh "Clean APT cache" "apt-get clean"
  run_step_sh "Clean temporary files" "systemd-tmpfiles --clean"
  run_step "Clean thumbnail cache" cleanup_thumbnails

  local had_errors=0
  if [[ ${#FAILED_STEPS[@]} -gt 0 ]]; then had_errors=1; fi

  echo
  if [[ $had_errors -eq 0 ]]; then
    log_banner "Finished successfully"
  else
    log_banner "Finished with errors"
    log_banner "${#FAILED_STEPS[@]} step(s) failed:"
    local i
    for i in "${!FAILED_STEPS[@]}"; do
      echo "  $((i+1))) ${FAILED_STEPS[$i]} (exit ${FAILED_CODES[$i]})"
    done
  fi

  if [[ $FLAG_LOG -eq 1 || $had_errors -eq 1 ]]; then
    mv -f "$tmp_log" "./$LOG_NAME" 2>/dev/null || {
      cp -f "$tmp_log" "./$LOG_NAME" 2>/dev/null || true
      rm -f "$tmp_log" 2>/dev/null || true
    }
    log_banner "Log saved: ./$LOG_NAME"
  else
    rm -f "$tmp_log" 2>/dev/null || true
  fi
}

main "$@"
