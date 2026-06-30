#!/usr/bin/env bash
#
# ssh-vm.sh — SSH into the running guest (key auth, passwordless user).
# Any extra args are passed through to ssh (e.g. a remote command to run).
set -euo pipefail

cd "$(dirname "$0")"
source .env

exec ssh \
  -p "$SSH_HOSTFWD_PORT" \
  -i "$SSH_KEY" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  "$USERNAME@localhost" "$@"
