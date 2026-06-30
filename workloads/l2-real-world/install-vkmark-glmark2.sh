#!/usr/bin/env bash
#
# install-vkmark-glmark2.sh — L2 open-source fallback workloads on Linux.
#
# L2 is the real-world, CPU+GPU layer (design §3.3/§4): tens of thousands of
# draw calls per frame, so it exercises the command-submission / transport path.
# Basemark GPU is the headline L2 tool, but its Linux free build is GUI-only and
# can't be automated (see install-basemark-gpu.sh), so the design (§4 "L2 补充",
# §6) keeps vkmark (Vulkan) + glmark2 (OpenGL) as the scriptable, headless
# replacement that cleanly covers both routed paths:
#
#   * vkmark  -> Vulkan  -> Venus path   (design §2.1)
#   * glmark2 -> OpenGL  -> VirGL path
#
# BOTH are PRECOMPILED in the Ubuntu 24.04 universe repo — pure apt, no source
# build, no configuration. Same install on native-linux and inside the guest.
#
# Ubuntu 24.04 packaging notes (non-obvious):
#   * There is no plain `glmark2` package anymore; it is split by window system.
#     We install glmark2-x11 (desktop GL on X11 — the guest is GNOME/Xorg,
#     DISPLAY=:0) AND glmark2-drm (KMS/DRM, renders with NO X/Wayland session,
#     for true headless automation). glmark2-es2-* are GLES, not desktop GL.
#   * vkmark ships as a single `vkmark` package (universe).
#
# Run as your normal user; it sudo's only for apt.

source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../lib" && pwd)/common.sh"

refuse_root

log_info "==> Installing L2 open-source workloads: vkmark (Vk) + glmark2 (GL)"

# `universe` carries vkmark/glmark2; ensure it is enabled (no-op if already on).
if ! grep -Rqs 'universe' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
  log_info "==> enabling 'universe' component"
  sudo add-apt-repository -y universe || log_warn "could not auto-enable universe; vkmark/glmark2 may be unavailable"
fi

# All precompiled — no building. glmark2-data is pulled in as a dependency but
# list it explicitly for clarity.
apt_install \
  vkmark \
  glmark2-x11 glmark2-drm glmark2-data \
  vulkan-tools mesa-utils

VKMARK="$(command -v vkmark || true)"
GLMARK_X11="$(command -v glmark2 || true)"
GLMARK_DRM="$(command -v glmark2-drm || true)"

log_info "==> Installed:"
log_info "    vkmark      : ${VKMARK:-MISSING}"
log_info "    glmark2(x11): ${GLMARK_X11:-MISSING}"
log_info "    glmark2-drm : ${GLMARK_DRM:-MISSING}"

cat <<EOF

Done. vkmark + glmark2 (L2 fallback) installed from apt (precompiled).

Identical on native-linux and the Linux guest. In the guest, run GL apps
against the autologin X display (DISPLAY=:0) or use the DRM variant headless.

Run examples:
    # Vulkan (Venus path), headless off-screen:
    vkmark --winsys headless

    # OpenGL (VirGL path), onscreen via the guest desktop:
    DISPLAY=:0 glmark2 --off-screen

    # OpenGL with NO desktop session (pure KMS/DRM headless automation):
    glmark2-drm --off-screen

Notes:
 * Per design §2.1 routing: vkmark = Vulkan/Venus, glmark2 = OpenGL/VirGL.
   Do not cross-translate.
 * Normalize frame metrics through MangoHud for cross-tool consistency
   (design §3); glmark2 also emits its own score per scene.

$(print_gpu_probe_hint)
EOF
