#!/usr/bin/env bash
set -u

# Purpose:
# - Remove unnecessary packages from Kali Linux to free disk space.
# - Safe defaults that won't break core functionality.
# - Optionally remove old Linux kernels.
# - Optionally remove Firefox.
#
# Logging:
# - All output is captured while the script runs.
# - A log file (debloat.log) is only saved if something fails
#   or if --log is used.

SCRIPT_NAME="debloat"
LOG_NAME="debloat.log"

# ----------------------------
# Options
# ----------------------------
FLAG_LOG=0
FLAG_KERNELS=0
FLAG_FIREFOX=0

# ----------------------------
# Packages to remove
# ----------------------------
# Format: "human-readable name|package1 package2 ..."

REMOVE_LIST=(
  "GNOME Videos player|totem totem-plugins totem-common"
  "Screen reader|orca"
  "Media streaming server|rygel"
  "Thunderbolt manager|bolt"
  "GNOME help documentation|gnome-user-docs"
  "Help viewer app|yelp"
  "Parental controls|malcontent malcontent-gui"
  "GNOME remote desktop|gnome-remote-desktop"
  "Software center backend|packagekit"
)

# ----------------------------
# Helper functions
# ----------------------------
usage() {
  cat <<'EOF'
Usage:
  sudo ./debloat [flags]

Flags:
  --log       Keep debloat.log even if no errors occur
  --kernels   Also remove old Linux kernels (keeps current running kernel)
  --firefox   Remove Firefox ESR and replace with stub package

Examples:
  sudo ./debloat
  sudo ./debloat --kernels
  sudo ./debloat --firefox
  sudo ./debloat --log --kernels --firefox
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
# Package detection
# ----------------------------
is_package_installed() {
  dpkg -l "$1" 2>/dev/null | grep -q '^ii'
}

get_installed_packages() {
  # Return only installed packages
  local pkgs="$1"
  local installed=""
  local pkg

  for pkg in $pkgs; do
    if is_package_installed "$pkg"; then
      installed="$installed $pkg"
    fi
  done

  echo "$installed" | xargs
}

get_old_kernels() {
  local running
  running="$(uname -r)"

  dpkg -l 'linux-image-*' 2>/dev/null \
    | grep '^ii' \
    | awk '{print $2}' \
    | grep -Fv "$running" \
    | grep -Ev '^linux-image-(amd64|[0-9]+-amd64)$' \
    | xargs
}

# ----------------------------
# Display and confirmation
# ----------------------------
show_removal_list() {
  local old_kernels="$1"
  local show_firefox="$2"
  local found_any=0

  echo
  echo "The following will be removed:"
  echo

  local entry
  for entry in "${REMOVE_LIST[@]}"; do
    local name="${entry%%|*}"
    local pkgs="${entry##*|}"
    local installed
    installed="$(get_installed_packages "$pkgs")"

    if [[ -n "$installed" ]]; then
      echo "  * $name ($installed)"
      found_any=1
    fi
  done

  if [[ "$show_firefox" -eq 1 ]] && is_package_installed "firefox-esr"; then
    echo "  * Firefox browser (firefox-esr)"
    found_any=1
  fi

  if [[ -n "$old_kernels" ]]; then
    echo "  * Old Linux kernel(s) ($old_kernels)"
    found_any=1
  fi

  echo

  if [[ $found_any -eq 0 ]]; then
    return 1
  fi

  return 0
}

confirm_proceed() {
  local response
  read -r -p "Proceed? [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# ----------------------------
# Removal functions
# ----------------------------
remove_packages() {
  local entry
  for entry in "${REMOVE_LIST[@]}"; do
    local name="${entry%%|*}"
    local pkgs="${entry##*|}"
    local installed
    installed="$(get_installed_packages "$pkgs")"

    if [[ -n "$installed" ]]; then
      run_step_sh "Remove $name" "DEBIAN_FRONTEND=noninteractive apt-get purge -y $installed"
    fi
  done
}

remove_old_kernels() {
  local kernels="$1"

  if [[ -z "$kernels" ]]; then
    log_banner "No old kernels to remove."
    return 0
  fi

  # Also find and remove corresponding headers
  local headers=""
  local kern
  for kern in $kernels; do
    local ver="${kern#linux-image-}"
    if is_package_installed "linux-headers-$ver"; then
      headers="$headers linux-headers-$ver"
    fi
  done

  local all_kernel_pkgs="$kernels $headers"
  run_step_sh "Remove old kernel(s)" "DEBIAN_FRONTEND=noninteractive apt-get purge -y $all_kernel_pkgs"
}

remove_firefox() {
  # Skip if firefox is not installed
  if ! is_package_installed "firefox-esr"; then
    log_banner "Firefox ESR is not installed. Skipping."
    return 0
  fi

  # Skip if stub is already installed
  if is_package_installed "debloat-firefox-stub"; then
    log_banner "Firefox stub package already installed. Skipping."
    return 0
  fi

  # Install equivs if needed
  if ! command -v equivs-build >/dev/null 2>&1; then
    step_banner "Install equivs"
    DEBIAN_FRONTEND=noninteractive apt-get install -y equivs || return 1
  fi

  # Create temporary directory for building the stub package
  local tmpdir
  tmpdir="$(mktemp -d "/tmp/${SCRIPT_NAME}.firefox-stub.XXXXXX")" || return 1

  # Create the equivs control file
  cat > "$tmpdir/debloat-firefox-stub" <<'CTRL'
Section: web
Priority: optional
Standards-Version: 4.6.2

Package: debloat-firefox-stub
Architecture: all
Maintainer: debloat
Provides: firefox, firefox-esr, gnome-www-browser, www-browser
Description: Stub package to satisfy Firefox dependencies
 This package provides firefox and firefox-esr virtual packages
 to satisfy dependencies without installing the actual browser.
 Created by the debloat script.
CTRL

  # Build the stub package
  step_banner "Build Firefox stub package"
  (cd "$tmpdir" && equivs-build debloat-firefox-stub) || {
    rm -rf "$tmpdir" 2>/dev/null || true
    return 1
  }

  # Install the stub package
  step_banner "Install Firefox stub package"
  dpkg -i "$tmpdir"/debloat-firefox-stub_*.deb || {
    rm -rf "$tmpdir" 2>/dev/null || true
    return 1
  }

  # Clean up temp directory
  rm -rf "$tmpdir" 2>/dev/null || true

  # Remove firefox-esr
  run_step_sh "Purge Firefox ESR package" "DEBIAN_FRONTEND=noninteractive apt-get purge -y firefox-esr"

  # Remove leftover Mozilla directory from user's home
  local target_user="${SUDO_USER:-root}"
  local home_dir
  home_dir="$(getent passwd "$target_user" | cut -d: -f6)"

  if [[ -n "$home_dir" && -d "$home_dir/.mozilla" ]]; then
    step_banner "Remove Firefox user data"
    rm -rf "$home_dir/.mozilla"
  fi

  # Set Brave as default browser if installed
  if is_package_installed "brave-browser"; then
    step_banner "Set Brave as default browser"
    sudo -u "$target_user" xdg-settings set default-web-browser brave-browser.desktop 2>/dev/null || true
  fi

  return 0
}

# ----------------------------
# Reading user options
# ----------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --log) FLAG_LOG=1 ;;
      --kernels) FLAG_KERNELS=1 ;;
      --firefox) FLAG_FIREFOX=1 ;;
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

  # Detect old kernels if flag is used
  local old_kernels=""
  if [[ $FLAG_KERNELS -eq 1 ]]; then
    old_kernels="$(get_old_kernels)"
  fi

  # Show what will be removed and confirm
  if ! show_removal_list "$old_kernels" "$FLAG_FIREFOX"; then
    echo "Nothing to remove. System is already debloated."
    exit 0
  fi

  if ! confirm_proceed; then
    echo "Aborted."
    exit 0
  fi

  # Start logging
  local tmp_log
  tmp_log="$(mktemp "/tmp/${SCRIPT_NAME}.XXXXXX.log")"

  exec > >(tee -a "$tmp_log") 2>&1

  log_banner "Starting execution"
  log_banner "Flags: log=$FLAG_LOG kernels=$FLAG_KERNELS firefox=$FLAG_FIREFOX"

  run_step "Wait for package manager locks" wait_for_apt_locks

  # Remove packages
  remove_packages

  # Remove Firefox if requested
  if [[ $FLAG_FIREFOX -eq 1 ]]; then
    run_step "Remove Firefox ESR" remove_firefox
  fi

  # Remove old kernels if requested
  if [[ $FLAG_KERNELS -eq 1 ]]; then
    remove_old_kernels "$old_kernels"
  fi

  # Cleanup
  run_step_sh "Remove unused dependencies" "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y"
  run_step_sh "Clean APT cache" "apt-get clean"

  # Summary
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

  # Save or discard log
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
