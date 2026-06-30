#!/usr/bin/env bash
#
# install-basemark-gpu.sh — L2 headline workload (Basemark GPU) on Linux.
#
# Basemark GPU is the design's primary L2 tool (real-world, CPU+GPU,
# tens-of-thousands of draw calls per frame). The current Linux build ships as a
# standalone PRECOMPILED tarball from Basemark's CDN — no source build, no
# registration form, stable direct link — so this script downloads and extracts
# it fully automatically and idempotently, the same way the GravityMark script
# does. The extracted tree lives under this layer dir (git-ignored).
#
#   Linux build (1.2.3): https://cdn.downloads.basemark.com/BasemarkGPU-linux-x64-1.2.3.tar.gz
#   (~1.16 GB). The tarball variant uses your SYSTEM Mesa/RADV — what we want —
#   unlike the .flatpak variant which bundles an old Mesa 19.08.
#
# HARD CAVEATS (design §4 "已知坑", §6) — keep using vkmark/glmark2 for automated
# L2, this tool is GUI-driven on Linux:
#   1. GUI-launcher driven; the free build has NO end-to-end CLI automation.
#   2. Mandatory online: the free version uploads every result to the Basemark
#      Power Board, so the guest MUST have network access.
#   3. AMD + RADV at High/4K crashes (drm fence timeout / X reset). Use Medium
#      quality and a non-4K resolution.
#   4. Non-commercial license; do not publish results on ad-supported sites.
#
# Run as your normal user (NOT root) so the extracted tree stays user-owned.
#
# Env overrides:
#   BASEMARK_VERSION  version to fetch (default 1.2.3)
#   BASEMARK_URL      full tarball URL (default derived from version)
#   BASEMARK_TARBALL  use a local tarball instead of downloading
#   WL_CACHE          download cache dir (default workloads/.cache)

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/common.sh"

refuse_root

BASEMARK_VERSION="${BASEMARK_VERSION:-1.2.3}"
BASEMARK_TGZ="BasemarkGPU-linux-x64-${BASEMARK_VERSION}.tar.gz"
BASEMARK_URL="${BASEMARK_URL:-https://cdn.downloads.basemark.com/${BASEMARK_TGZ}}"

LAYER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
INSTALL_DIR="$LAYER_DIR/BasemarkGPU"
TARBALL_CACHE="${BASEMARK_TARBALL:-$WL_CACHE/$BASEMARK_TGZ}"

log_info "==> Installing L2 workload: Basemark GPU ${BASEMARK_VERSION} (precompiled tarball)"

# Runtime deps to actually launch the GUI/renderer; no-op if already present
# (the guest cloud-init already installs most of these).
apt_install \
  libvulkan1 vulkan-tools \
  libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgles2 \
  libx11-6 libxext6 libxi6 libxrandr2 libxcb1 \
  curl

# The actual render binaries (resources/binaries/BasemarkGPU_{vk,gl}) are a 2020
# build linked against OpenSSL 1.1 (libssl.so.1.1 / libcrypto.so.1.1). Ubuntu
# 24.04 ships only OpenSSL 3 (libssl.so.3), so those binaries fail to load and
# the Electron launcher then reports the misleading "Benchmark asset file not
# found." We install the legacy libssl1.1 from the Ubuntu 20.04 security pocket
# (stable URL, official). Skip if it's already present.
if ! find /usr/lib /lib -name 'libssl.so.1.1' 2>/dev/null | grep -q . ; then
  if [[ "${WL_SKIP_APT:-0}" == "1" ]]; then
    log_warn "==> WL_SKIP_APT=1: not installing libssl1.1; render binaries will fail to load"
  else
    LIBSSL11_DEB="libssl1.1_${LIBSSL11_VER:-1.1.1f-1ubuntu2.24}_amd64.deb"
    LIBSSL11_URL="${LIBSSL11_URL:-http://security.ubuntu.com/ubuntu/pool/main/o/openssl/${LIBSSL11_DEB}}"
    log_info "==> Installing legacy libssl1.1 (needed by the 2020 render binaries)"
    download "$LIBSSL11_URL" "$WL_CACHE/$LIBSSL11_DEB"
    sudo apt-get install -y "$WL_CACHE/$LIBSSL11_DEB" \
      || log_warn "libssl1.1 install failed; BasemarkGPU_vk/_gl may not load"
  fi
fi

# Auto-download (cached) unless a local tarball was provided.
if [[ -n "${BASEMARK_TARBALL:-}" ]]; then
  [[ -f "$BASEMARK_TARBALL" ]] || { log_err "BASEMARK_TARBALL not found: $BASEMARK_TARBALL"; exit 1; }
  log_info "==> using local tarball: $BASEMARK_TARBALL"
else
  download "$BASEMARK_URL" "$TARBALL_CACHE"
fi

tar_extract "$TARBALL_CACHE" "$INSTALL_DIR"

# The Linux build is an Electron app. Its bundled chrome-sandbox helper must be
# root-owned and SUID (mode 4755) or the app aborts with:
#   "The SUID sandbox helper binary ... is not configured correctly".
# Fix it automatically (needs sudo). If you'd rather not, launch with
# --no-sandbox (printed below) — fine for a benchmark box.
SANDBOX="$(find "$INSTALL_DIR" -maxdepth 3 -type f -name 'chrome-sandbox' 2>/dev/null | head -n1)"
if [[ -n "$SANDBOX" ]]; then
  if [[ "${WL_SKIP_APT:-0}" == "1" ]]; then
    log_warn "==> WL_SKIP_APT=1: not fixing chrome-sandbox SUID; use --no-sandbox to run"
  else
    log_info "==> fixing chrome-sandbox SUID perms (root:root 4755)"
    sudo chown root:root "$SANDBOX" && sudo chmod 4755 "$SANDBOX" \
      || log_warn "could not set SUID on chrome-sandbox; run the launcher with --no-sandbox"
  fi
fi

# Locate the launcher binary inside the extracted tree (exclude chrome-sandbox).
LAUNCHER="$(find "$INSTALL_DIR" -maxdepth 3 -type f -iname 'basemarkgpu' -perm -u+x 2>/dev/null | head -n1)"
if [[ -z "$LAUNCHER" ]]; then
  LAUNCHER="$(find "$INSTALL_DIR" -maxdepth 3 -type f -iname 'basemarkgpu*' ! -name 'chrome-sandbox' 2>/dev/null | head -n1)"
  [[ -n "$LAUNCHER" ]] && chmod +x "$LAUNCHER" 2>/dev/null || true
fi

if [[ -z "$LAUNCHER" ]]; then
  log_warn "Could not auto-locate the launcher under $INSTALL_DIR"
  log_warn "Inspect: ls -R '$INSTALL_DIR'"
else
  log_info "==> launcher: $LAUNCHER"
fi

cat <<EOF

Done. Basemark GPU ${BASEMARK_VERSION} extracted under:
    $INSTALL_DIR

Identical on native-linux and the Linux guest. It only writes inside
workloads/, so push the repo into the guest and run it there too.

It is an Electron app. The bundled chrome-sandbox was set root:root 4755 above
so it launches normally:
    ${LAUNCHER:-$INSTALL_DIR/<launcher>}
If the SUID fix didn't run (e.g. WL_SKIP_APT=1) or you prefer not to, launch with:
    ${LAUNCHER:-$INSTALL_DIR/<launcher>} --no-sandbox

IMPORTANT caveats (design §4 / §6) — this tool is GUI-driven on Linux:
 * No CLI automation in the free build. Launch the GUI, accept the license,
   then run the test by hand. In the guest, target the desktop X display:
       DISPLAY=:0 ${LAUNCHER:-$INSTALL_DIR/<launcher>}
 * MANDATORY ONLINE: free version uploads to the Basemark Power Board. The
   guest MUST have network access (QEMU user-net provides it).
 * AMD + RADV crashes at High/4K (drm fence timeout). Use MEDIUM quality and a
   non-4K resolution (e.g. 1920x1080) via the Custom tab.
 * Non-commercial license; do not publish results on ad-supported sites.

For a fully scriptable, headless L2 instead, prefer:
    workloads/l2-real-world/install-vkmark-glmark2.sh   (vkmark + glmark2)

$(print_gpu_probe_hint)
EOF
