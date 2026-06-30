#!/usr/bin/env bash
#
# fix-ssh-key.sh — (re)install the host public key into the Windows guest so SSH
# is key-based (no password prompt). Run once after install if key auth didn't
# take during autounattend.
#
# Windows OpenSSH quirks handled here:
#   * For users in the Administrators group, sshd reads the key from
#     C:\ProgramData\ssh\administrators_authorized_keys (NOT ~/.ssh).
#   * That file's ACL must grant ONLY Administrators + SYSTEM, or sshd ignores it.
#
# Robustness: the PowerShell payload is base64-encoded and run via
# `powershell -EncodedCommand`, so no quoting/escaping survives SSH transport to
# get mangled (the previous heredoc approach silently failed to write the file).
#
# You'll be prompted once for the guest password ('$PASSWORD'); key auth works
# afterwards.
set -euo pipefail

cd "$(dirname "$0")"
source .env

[[ -f "$SSH_PUBKEY" ]] || { log_err "pubkey missing: $SSH_PUBKEY"; exit 1; }
PUB="$(cat "$SSH_PUBKEY")"

log_info "==> Installing public key into the Windows guest (password '$PASSWORD' once)"

# Build the PowerShell script. Note: PowerShell -EncodedCommand expects the
# script encoded as UTF-16LE then base64. We embed the key as a literal.
read -r -d '' PS_SCRIPT <<PSEOF || true
\$ErrorActionPreference = 'Stop'
\$key = '${PUB}'
\$f = "\$env:ProgramData\\ssh\\administrators_authorized_keys"
New-Item -Force -ItemType Directory (Split-Path \$f) | Out-Null
Set-Content -Path \$f -Value \$key -Encoding ascii
icacls \$f /inheritance:r | Out-Null
icacls \$f /grant "Administrators:F" "SYSTEM:F" | Out-Null
# Make sure pubkey auth is enabled and sshd autostarts.
Set-Service sshd -StartupType Automatic
Restart-Service sshd
# Verify
if ((Get-Content \$f) -eq \$key) { Write-Output 'KEY_OK' } else { Write-Output 'KEY_MISMATCH' }
icacls \$f
PSEOF

# Encode as UTF-16LE base64 for -EncodedCommand (transport-safe: only [A-Za-z0-9+/=]).
ENC="$(printf '%s' "$PS_SCRIPT" | iconv -t UTF-16LE | base64 -w0)"

log_info "    (sending base64-encoded PowerShell; no escaping to mangle)"
ssh -p "$SSH_HOSTFWD_PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$USERNAME@localhost" "powershell -EncodedCommand $ENC"

log_info ""
log_info "==> Done. Test it (should NOT prompt for a password):"
log_info "    ./ssh-vm.sh -- whoami"
