#!/usr/bin/env bash
#
# common.sh — shared idempotent helpers for host setup scripts.
#
# Source this from a script: . "$(dirname "$0")/lib/common.sh"
# Provides: apt_update_cached, apt_need, git_sync, target_user, user_has_cargo,
#           cargo_env_for, have_lib.

# ---- apt: only run `apt-get update` once per ~24h (cached by timestamp) ------
apt_update_cached() {
  local stamp="/var/lib/apt/periodic/update-success-stamp"
  local now age
  now="$(date +%s)"
  if [[ -f "${stamp}" ]]; then
    age=$(( now - $(stat -c %Y "${stamp}" 2>/dev/null || echo 0) ))
    if (( age < 86400 )); then
      echo "==> apt index is fresh (updated ${age}s ago), skipping apt-get update"
      return 0
    fi
  fi
  echo "==> apt-get update"
  apt-get update -y
}

# ---- apt: install only the packages that are not already installed ----------
# usage: apt_need pkg1 pkg2 ...
apt_need() {
  local missing=()
  local p
  for p in "$@"; do
    if ! dpkg-query -W -f='${Status}' "${p}" 2>/dev/null | grep -q "ok installed"; then
      missing+=("${p}")
    fi
  done
  if (( ${#missing[@]} == 0 )); then
    echo "==> all apt deps already installed: $*"
    return 0
  fi
  apt_update_cached
  echo "==> installing missing apt deps: ${missing[*]}"
  apt-get install -y --no-install-recommends "${missing[@]}"
}

# ---- git: clone if absent, otherwise fetch/checkout/fast-forward -------------
# usage: git_sync <url> <dest_dir> [ref]
git_sync() {
  local url="$1" dest="$2" ref="${3:-}"
  if [[ ! -d "${dest}/.git" ]]; then
    echo "==> cloning ${url} -> ${dest}"
    git clone "${url}" "${dest}"
  else
    echo "==> ${dest} already cloned, fetching updates"
    git -C "${dest}" fetch --all --tags --prune
  fi
  if [[ -n "${ref}" ]]; then
    git -C "${dest}" checkout "${ref}"
    # fast-forward only if on a branch (no-op on a detached tag)
    git -C "${dest}" pull --ff-only 2>/dev/null || true
  fi
}

# ---- user / cargo helpers (scripts run as root via sudo) ---------------------
target_user() { echo "${SUDO_USER:-root}"; }

target_home() {
  local u; u="$(target_user)"
  if [[ "${u}" == "root" ]]; then echo "/root"; else echo "/home/${u}"; fi
}

# True if the *target* user already has a usable cargo (rustup or system).
user_has_cargo() {
  local home; home="$(target_home)"
  [[ -x "${home}/.cargo/bin/cargo" ]] && return 0
  command -v cargo >/dev/null 2>&1 && return 0
  return 1
}

# Prefix to run cargo/rustc as the target user with their cargo on PATH.
# usage: $(cargo_env_for) cargo build --release
cargo_env_for() {
  local u home; u="$(target_user)"; home="$(target_home)"
  echo "sudo -u ${u} env PATH=${home}/.cargo/bin:${PATH}"
}

# ---- misc --------------------------------------------------------------------
# True if a shared library matching the glob exists under common lib dirs.
# usage: have_lib 'libclang.so*'
have_lib() {
  local pat="$1"
  find /usr/lib /usr/local/lib -name "${pat}" 2>/dev/null | grep -q . && return 0
  return 1
}
