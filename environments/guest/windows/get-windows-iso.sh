#!/usr/bin/env bash
#
# get-windows-iso.sh — Obtain a Windows 10 x64 installer ISO (idempotent).
#
# Microsoft does not publish a stable direct ISO link (the download page mints
# short-lived, JS-generated URLs), so naive wget of the page does not work. We
# use 'mido' — a small, dependency-free shell tool that fetches the OFFICIAL ISO
# straight from Microsoft's servers — fetching mido itself if not installed.
#
# Idempotent: if the ISO (or a cached copy) already exists, does nothing.
# Result is placed at $WINDOWS_ISO (see .env).
#
# Usage:
#   ./get-windows-iso.sh                 # download Win10 to $WINDOWS_ISO
#   WINDOWS_ISO=~/win10.iso ./get-windows-iso.sh
#   MIDO_EDITION=win10x64 ./get-windows-iso.sh
set -euo pipefail

cd "$(dirname "$0")"
source .env

# Which edition mido should fetch. 'win10x64' = latest Win10 x64 (English).
MIDO_EDITION="${MIDO_EDITION:-win10x64}"
MIDO_URL="${MIDO_URL:-https://raw.githubusercontent.com/ElliotKillick/Mido/main/Mido.sh}"
MIDO_CACHE="$VMDISKFOLDER/Mido.sh"

mkdir -p "$VMDISKFOLDER"

# --- idempotency -------------------------------------------------------------
if [[ -f "$WINDOWS_ISO" ]]; then
  log_info "==> Windows ISO already present: $WINDOWS_ISO (skipping)"
  exit 0
fi
# A previous mido run drops the ISO in the working dir; accept a cached one.
CACHED_ISO="$(ls -1 "$VMDISKFOLDER"/*.iso 2>/dev/null | grep -iv virtio | head -1 || true)"
if [[ -n "$CACHED_ISO" ]]; then
  log_info "==> Found cached ISO: $CACHED_ISO"
  log_info "    Using it as the Windows ISO."
  ln -sf "$CACHED_ISO" "$WINDOWS_ISO" 2>/dev/null || cp "$CACHED_ISO" "$WINDOWS_ISO"
  exit 0
fi

# --- locate or fetch mido ----------------------------------------------------
MIDO_BIN=""
if command -v mido >/dev/null 2>&1; then
  MIDO_BIN="$(command -v mido)"
elif [[ -f "$MIDO_CACHE" ]]; then
  MIDO_BIN="$MIDO_CACHE"
else
  log_info "==> Fetching mido (official-ISO downloader) to $MIDO_CACHE"
  if command -v wget >/dev/null; then
    wget -O "$MIDO_CACHE.part" "$MIDO_URL"
  else
    curl -fL -o "$MIDO_CACHE.part" "$MIDO_URL"
  fi
  mv "$MIDO_CACHE.part" "$MIDO_CACHE"
  chmod +x "$MIDO_CACHE"
  MIDO_BIN="$MIDO_CACHE"
fi

# mido needs one of these to verify the download; warn if absent (non-fatal).
command -v sha256sum >/dev/null 2>&1 || log_warn "    sha256sum not found — mido cannot verify the ISO checksum."

# --- download ----------------------------------------------------------------
log_info "==> Downloading Windows ISO via mido (edition: $MIDO_EDITION)"
log_info "    This pulls the official image from Microsoft and is several GB."
( cd "$VMDISKFOLDER" && bash "$MIDO_BIN" "$MIDO_EDITION" )

# mido names the file e.g. Win10_22H2_English_x64.iso — link it to $WINDOWS_ISO.
DOWNLOADED="$(ls -1t "$VMDISKFOLDER"/*.iso 2>/dev/null | grep -iv virtio | head -1 || true)"
if [[ -z "$DOWNLOADED" ]]; then
  log_err "mido finished but no ISO was found in $VMDISKFOLDER."
  log_err "Download a Windows 10 x64 ISO manually and set WINDOWS_ISO to it:"
  log_err "  https://www.microsoft.com/software-download/windows10"
  exit 1
fi
ln -sf "$DOWNLOADED" "$WINDOWS_ISO" 2>/dev/null || cp "$DOWNLOADED" "$WINDOWS_ISO"
log_info "==> Windows ISO ready: $DOWNLOADED"
log_info "    (linked as $WINDOWS_ISO)"
