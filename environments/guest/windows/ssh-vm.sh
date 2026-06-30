#!/usr/bin/env bash
#
# ssh-vm.sh — SSH into the running Windows guest (OpenSSH Server, key or password).
#
#   ./ssh-vm.sh                  # default port from .env (2322)
#   ./ssh-vm.sh -p 2322 -- <cmd> # override port
# Remaining args pass through to ssh. Key auth is configured by the install;
# password ('user') also works.
set -euo pipefail

cd "$(dirname "$0")"
source .env

if [[ "${1:-}" == "-p" ]]; then
  SSH_HOSTFWD_PORT="$2"; shift 2
fi

exec ssh \
  -p "$SSH_HOSTFWD_PORT" \
  -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  "$USERNAME@localhost" "$@"
