#!/usr/bin/env bash
#
# ssh-vm.sh — SSH into the running guest (key auth, passwordless user).
#
# Port selection (so it works with the virtualization scheme launchers that use
# their own host port — virgl 2223, venus 2224, pt 2225):
#   ./ssh-vm.sh                       # default port from .env (2222)
#   ./ssh-vm.sh -p 2224 -- <cmd>      # override port
#   SSH_HOSTFWD_PORT=2224 ./ssh-vm.sh # via env
# Any remaining args are passed through to ssh (e.g. a remote command).
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
