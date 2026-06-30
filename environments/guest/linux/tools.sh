#!/usr/bin/env bash
#
# tools.sh — graphics-benchmark Linux guest helpers.
#
# Two ways to use it:
#
#   1) INSIDE the guest — detect what the guest sees locally:
#        ./tools.sh                      # detect_pipeline
#        ./tools.sh detect_pipeline
#        source tools.sh && detect_pipeline
#
#   2) FROM the host — SSH into the running guest and detect remotely. The port
#      selects which scheme's VM (virgl 2223, venus 2224, pt 2225; base 2222):
#        ./tools.sh --remote                 # default port (2222 or $PORT)
#        ./tools.sh --remote -p 2224         # venus VM
#        PORT=2224 ./tools.sh --remote
#
# The key function detect_pipeline inspects the Vulkan/OpenGL device names the
# guest sees and reports which GPU virtualization path is active
# (Venus / VirGL / passthrough-or-native / software). See
# docs/benchmark-design.md §1.
#
# Configurable knobs (env vars, all overridable):
#   PORT        SSH host port to the guest        (default 2222)
#   SSH_USER    guest username                    (default user)
#   SSH_KEY     private key path                  (default ./.ssh/guest-key)
#   GUEST_HOST  guest host/addr                   (default localhost)
#   DISPLAY     X display for the glxinfo fallback only (default :0). The GL
#               probe prefers eglinfo and needs no X display.

# --- logging -----------------------------------------------------------------
if [[ -t 1 ]]; then
  _G='\033[0;32m'; _Y='\033[0;33m'; _R='\033[0;31m'; _B='\033[1m'; _N='\033[0m'
else
  _G=''; _Y=''; _R=''; _B=''; _N=''
fi
_info() { echo -e "${_G}$*${_N}"; }
_warn() { echo -e "${_Y}$*${_N}"; }
_err()  { echo -e "${_R}$*${_N}" >&2; }

# --- configurable knobs (env-overridable) ------------------------------------
PORT="${PORT:-2222}"
SSH_USER="${SSH_USER:-user}"
GUEST_HOST="${GUEST_HOST:-localhost}"
# Default key sits next to this script (.ssh/guest-key).
_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SSH_KEY="${SSH_KEY:-$_TOOLS_DIR/.ssh/guest-key}"

# --- low-level probes --------------------------------------------------------

# vulkan_device_names: one Vulkan deviceName per line (empty if none).
vulkan_device_names() {
  command -v vulkaninfo >/dev/null 2>&1 || return 0
  vulkaninfo --summary 2>/dev/null \
    | sed -n 's/.*deviceName[[:space:]]*=[[:space:]]*//p'
}

# gl_renderer: the OpenGL renderer string.
#
# Prefer EGL (eglinfo) over GLX (glxinfo). On a virtio-gpu guest the system
# Xorg is typically a software (llvmpipe) X server, so GLX over DISPLAY=:0
# reports llvmpipe even though the hardware GL path works fine. EGL via the
# GBM/surfaceless/device platforms talks straight to the DRI render node
# (/dev/dri/renderD*) and needs no X display, so it surfaces the real
# accelerated renderer (e.g. "virgl ...") whether run locally or over SSH.
#
# Strategy:
#   1) eglinfo -> first non-software renderer (the HW path), else first renderer.
#   2) fall back to glxinfo (DISPLAY) only if eglinfo is unavailable.
gl_renderer() {
  if command -v eglinfo >/dev/null 2>&1; then
    local names hw
    names="$(eglinfo 2>/dev/null | sed -n 's/.*renderer:[[:space:]]*//p')"
    if [[ -n "$names" ]]; then
      hw="$(echo "$names" | grep -viE 'llvmpipe|softpipe|swrast' | head -1)"
      echo "${hw:-$(echo "$names" | head -1)}"
      return 0
    fi
  fi
  command -v glxinfo >/dev/null 2>&1 || return 0
  local disp="${DISPLAY:-:0}"
  DISPLAY="$disp" glxinfo -B 2>/dev/null \
    | sed -n 's/.*OpenGL renderer string:[[:space:]]*//p'
}

# dri_nodes: list /dev/dri entries (card*, renderD*).
dri_nodes() {
  ls /dev/dri/ 2>/dev/null | tr '\n' ' '
}

# --- pipeline classification -------------------------------------------------

# classify_path <combined-name-string> -> echoes one of:
#   venus | virgl | passthrough-or-native | software | unknown
classify_path() {
  local s="$1"
  shopt -s nocasematch
  if [[ "$s" == *venus* ]]; then
    echo "venus"
  elif [[ "$s" == *virgl* ]]; then
    echo "virgl"
  elif [[ "$s" == *llvmpipe* || "$s" == *softpipe* || "$s" == *swrast* ]]; then
    echo "software"
  elif [[ "$s" == *amd* || "$s" == *radv* || "$s" == *radeon* ]]; then
    echo "passthrough-or-native"
  else
    echo "unknown"
  fi
  shopt -u nocasematch
}

# detect_pipeline: main entry. Reports the active GPU path with evidence.
detect_pipeline() {
  local vk gl dri
  vk="$(vulkan_device_names)"
  gl="$(gl_renderer | head -1)"
  dri="$(dri_nodes)"

  # Prefer the hardware-accelerated Vulkan device if present, else GL.
  local vk_hw vk_path gl_path
  vk_hw="$(echo "$vk" | grep -viE 'llvmpipe|softpipe|swrast' | head -1)"
  vk_path="$(classify_path "${vk_hw:-$vk}")"
  gl_path="$(classify_path "$gl")"

  # Decide the overall verdict: a hardware Vulkan/GL signal wins over software.
  local verdict="software"
  for p in "$vk_path" "$gl_path"; do
    case "$p" in
      venus|virgl|passthrough-or-native) verdict="$p"; break ;;
    esac
  done

  echo -e "${_B}== GPU pipeline detection ==${_N}"
  echo    "  Vulkan device : ${vk_hw:-${vk:-<none>}}"
  echo    "  OpenGL render : ${gl:-<none (no X display?)>}"
  echo    "  /dev/dri      : ${dri:-<none>}"
  echo -n "  Verdict       : "
  case "$verdict" in
    venus)                  _info  "Venus  (virtio-gpu + Venus -> RADV; Vulkan path, DX via DXVK)" ;;
    virgl)                  _info  "VirGL  (virtio-gpu + VirGL -> radeonsi; OpenGL path)" ;;
    passthrough-or-native)  _info  "Passthrough / native context (raw AMD; no Venus/VirGL prefix)" ;;
    software)               _warn  "SOFTWARE (llvmpipe) — GPU path NOT engaged; check the launch device" ;;
    *)                      _warn  "unknown — could not classify; see names above" ;;
  esac

  # Hint when only software Vulkan but a render node exists (misconfig).
  if [[ "$verdict" == "software" && "$dri" == *renderD* ]]; then
    _warn  "  note: a render node exists but no HW driver bound — driver/ICD issue?"
  fi

  # machine-readable line for scripts/harness
  echo "pipeline=$verdict"
}

# detect_pipeline_remote: run from the HOST — SSH into the guest on $PORT and
# execute detect_pipeline there by shipping this script over the connection.
detect_pipeline_remote() {
  command -v ssh >/dev/null 2>&1 || { _err "ssh not found"; return 1; }
  [[ -f "$SSH_KEY" ]] || { _err "SSH key not found: $SSH_KEY"; return 1; }
  _info "==> Detecting pipeline in guest ${SSH_USER}@${GUEST_HOST}:${PORT}"
  ssh -p "$PORT" -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=10 \
      "${SSH_USER}@${GUEST_HOST}" \
      "$(cat "${BASH_SOURCE[0]:-$0}"); detect_pipeline"
}

# --- usage -------------------------------------------------------------------
_usage() {
  cat <<EOF
tools.sh — graphics-benchmark Linux guest helpers

USAGE
  ./tools.sh [flags] [function] [args]

FLAGS
  -h, --help            show this help and exit
  -r, --remote          run over SSH against the guest (host-side use)
  -p PORT, --port=PORT  SSH host port to the guest (default: \$PORT or 2222)
                        schemes: virgl 2223, venus 2224, pt 2225

FUNCTIONS (default: detect_pipeline)
  detect_pipeline        classify the active GPU path from device names
  detect_pipeline_remote SSH in and run detect_pipeline in the guest
  vulkan_device_names    list Vulkan deviceName strings
  gl_renderer            print the OpenGL renderer string (EGL, X-less)
  dri_nodes              list /dev/dri entries

ENV (overridable)
  PORT SSH_USER SSH_KEY GUEST_HOST DISPLAY

EXAMPLES
  ./tools.sh                       # in-guest: detect pipeline
  ./tools.sh --remote -p 2224      # host: detect venus VM's pipeline
  PORT=2223 ./tools.sh --remote    # host: detect virgl VM's pipeline
EOF
}

# --- dispatch ----------------------------------------------------------------
# Parse a leading mode/flags, then call the function (default detect_pipeline).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  REMOTE=0
  # consume leading flags in any order
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)   _usage; exit 0 ;;
      --remote|-r) REMOTE=1; shift ;;
      -p)          PORT="$2"; shift 2 ;;
      --port=*)    PORT="${1#*=}"; shift ;;
      -*)          _err "unknown flag: $1"; echo; _usage; exit 1 ;;
      *)           break ;;
    esac
  done

  if [[ "$REMOTE" -eq 1 ]]; then
    detect_pipeline_remote
    exit $?
  fi

  if [[ $# -gt 0 ]]; then
    fn="$1"; shift
    if declare -F "$fn" >/dev/null; then
      "$fn" "$@"
    else
      _err "unknown function: $fn"
      _err "available: detect_pipeline, detect_pipeline_remote, vulkan_device_names, gl_renderer, dri_nodes"
      exit 1
    fi
  else
    detect_pipeline
  fi
fi
