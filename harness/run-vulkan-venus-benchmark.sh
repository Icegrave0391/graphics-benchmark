#!/usr/bin/env bash
#
# Run the current Vulkan/Venus comparison set and collect results under results/.
#
# Matrix:
#   1. native-linux: GravityMark native Vulkan on the host
#   2. venus-linux : GravityMark native Vulkan in the virtio-gpu Venus guest
#   3. venus-linux : Windows GravityMark D3D11 through Proton/DXVK in the same guest
#
# This is intentionally host-driven. The Venus guest is expected to be running
# and reachable on SSH port 2224.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKLOADS_DIR="$REPO_ROOT/workloads"
RESULTS_ROOT="${RESULTS_ROOT:-$REPO_ROOT/results}"
RUN_TAG="${RUN_TAG:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_ROOT="$RESULTS_ROOT/$RUN_TAG"

GUEST_PORT="${GUEST_PORT:-2224}"
GUEST_USER="${GUEST_USER:-user}"
GUEST_HOST="${GUEST_HOST:-localhost}"
GUEST_REPO="${GUEST_REPO:-/home/$GUEST_USER/graphics-benchmark}"
GUEST_DISPLAY="${GUEST_DISPLAY:-:0}"
GUEST_KEY="${GUEST_KEY:-$REPO_ROOT/environments/guest/linux/.ssh/guest-key}"

DISPLAY_VALUE="${DISPLAY_VALUE:-${DISPLAY:-:0}}"
RESOLUTIONS_STR="${RESOLUTIONS:-1280x720 1920x1080 2560x1440}"
GM_ASTEROIDS="${GM_ASTEROIDS:-200000}"
GM_COUNT="${GM_COUNT:-1}"
WARMUP="${WARMUP:-0}"

RUN_NATIVE="${RUN_NATIVE:-1}"
RUN_GUEST_VK="${RUN_GUEST_VK:-1}"
RUN_GUEST_DXVK="${RUN_GUEST_DXVK:-1}"

SSH_BASE=()
SCP_BASE=()

usage() {
  cat <<'EOF'
Usage: harness/run-vulkan-venus-benchmark.sh [options]

Runs GravityMark at multiple resolutions and records results in results/<RUN_TAG>/.

Options:
  --res LIST          space/comma separated resolutions (default: 1280x720 1920x1080 2560x1440)
  --guest-port PORT  SSH forwarded port for the Venus guest (default: 2224)
  --guest-user USER  guest user (default: user)
  --guest-host HOST  SSH host (default: localhost)
  --guest-repo PATH  repo path in guest (default: /home/<user>/graphics-benchmark)
  --run-tag TAG      result subdirectory name (default: UTC timestamp)
  --asteroids N      GravityMark asteroid count (default: 200000)
  --count N          GravityMark pass count (default: 1)
  --no-native        skip native host Vulkan
  --no-guest-vk      skip guest Venus native Vulkan
  --no-guest-dxvk    skip guest Venus DXVK/D3D11
  -h, --help         show this help

Environment overrides: RESULTS_ROOT, DISPLAY_VALUE, GUEST_DISPLAY, GUEST_KEY,
RESOLUTIONS, RUN_NATIVE, RUN_GUEST_VK, RUN_GUEST_DXVK, WARMUP.

Prerequisites:
  - Host GravityMark installed at workloads/gravitymark/GravityMark.
  - Venus guest running and reachable over SSH port 2224.
  - Guest has repo/workloads installed at GUEST_REPO.
  - Guest Proton + GravityMark DX installed for --guest-dxvk runs.
EOF
}

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/}
  printf '%s' "$s"
}

json_string_or_null() {
  if [[ -n "$1" ]]; then
    printf '"%s"' "$(json_escape "$1")"
  else
    printf 'null'
  fi
}

split_res() {
  local res="$1"
  [[ "$res" =~ ^([0-9]+)x([0-9]+)$ ]] || die "invalid resolution: $res"
  WIDTH="${BASH_REMATCH[1]}"
  HEIGHT="${BASH_REMATCH[2]}"
}

ssh_guest() {
  "${SSH_BASE[@]}" "$GUEST_USER@$GUEST_HOST" "$@"
}

scp_from_guest() {
  local remote="$1" local_path="$2"
  "${SCP_BASE[@]}" "$GUEST_USER@$GUEST_HOST:$remote" "$local_path"
}

require_file() {
  [[ -e "$1" ]] || die "$2: $1"
}

run_remote_capture() {
  local log_file="$1"
  shift
  set +e
  ssh_guest "$@" >"$log_file" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

summarize_times() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    FPS_AVG=""; FPS_MIN=""; FPS_MAX=""; FRAMETIME_AVG=""; FRAME_COUNT="0"
    return 0
  fi
  local summary
  summary="$(awk '
    function numeric(x) { return x ~ /^[-+]?[0-9]*\.?[0-9]+$/ }
    {
      for (i = 1; i <= NF; i++) {
        gsub(/,/, "", $i)
        if (numeric($i) && $i > 0) {
          v = $i + 0
          last = v
        }
      }
      if (last > 0) {
        # GravityMark -times is normally in milliseconds. If a build emits
        # seconds, convert small values to ms.
        if (last < 1) last *= 1000
        n++
        sum += last
        if (n == 1 || last < min) min = last
        if (n == 1 || last > max) max = last
        last = 0
      }
    }
    END {
      if (n == 0) {
        print "||||0"
      } else {
        avg = sum / n
        fps_avg = 1000 / avg
        fps_min = 1000 / max
        fps_max = 1000 / min
        printf "%.6f|%.6f|%.6f|%.6f|%d\n", fps_avg, fps_min, fps_max, avg, n
      }
    }
  ' "$file")"
  IFS='|' read -r FPS_AVG FPS_MIN FPS_MAX FRAMETIME_AVG FRAME_COUNT <<< "$summary"
}

extract_score() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    SCORE=""
    return 0
  fi
  SCORE="$(grep -Eio 'score[^0-9]*[0-9]+([.][0-9]+)?' "$file" | grep -Eo '[0-9]+([.][0-9]+)?' | tail -n1 || true)"
}

write_result_json() {
  local out_json="$1" env_id="$2" category="$3" transport="$4" api="$5" backend="$6" resolution="$7" rc="$8" raw_log="$9" times_rel="${10}" remote_times="${11:-}"
  summarize_times "$RUN_DIR/$times_rel"
  extract_score "$RUN_DIR/$raw_log"

  local status="ok"
  [[ "$rc" == "0" ]] || status="failed"
  local run_id="${RUN_TAG}_${env_id}_gravitymark_${backend}_${resolution}"

  cat > "$out_json" <<EOF
{
  "run_id": "$(json_escape "$run_id")",
  "status": "$(json_escape "$status")",
  "exit_code": $rc,
  "env": {
    "env_id": "$(json_escape "$env_id")",
    "category": "$(json_escape "$category")",
    "host_os": $(json_string_or_null "$(uname -srmo 2>/dev/null || true)"),
    "guest_os": null,
    "virt": $([[ "$env_id" == "native-linux" ]] && printf 'null' || printf '"virtio-gpu"'),
    "context_type": "$(json_escape "$transport")",
    "transport": "$(json_escape "$transport")",
    "guest_ssh_port": $([[ "$env_id" == "native-linux" ]] && printf 'null' || printf '%s' "$GUEST_PORT")
  },
  "workload": {
    "tool": "gravitymark",
    "api": "$(json_escape "$api")",
    "backend": "$(json_escape "$backend")",
    "scene": "asteroids",
    "asteroids": $GM_ASTEROIDS,
    "resolution": "$(json_escape "$resolution")",
    "vsync": false,
    "count": $GM_COUNT
  },
  "metrics": {
    "score": ${SCORE:-null},
    "fps_avg": ${FPS_AVG:-null},
    "fps_min": ${FPS_MIN:-null},
    "fps_max": ${FPS_MAX:-null},
    "fps_1pct_low": null,
    "fps_0p1pct_low": null,
    "frametime_avg_ms": ${FRAMETIME_AVG:-null},
    "frametime_p95_ms": null,
    "frametime_p99_ms": null,
    "frametime_stddev_ms": null,
    "frame_count": ${FRAME_COUNT:-0},
    "host_cpu_pct": null
  },
  "derived": { "baseline_id": "native-linux", "overhead_pct": null },
  "capture_layer": "gravitymark-times",
  "raw_capture": "$(json_escape "$times_rel")",
  "raw_stdout": "$(json_escape "$raw_log")",
  "remote_raw_capture": $(json_string_or_null "$remote_times")
}
EOF
}

run_native_vulkan() {
  local resolution="$1"
  split_res "$resolution"
  RUN_DIR="$RUN_ROOT/native-linux/gravitymark-vulkan/$resolution"
  mkdir -p "$RUN_DIR"
  TIMES_FILE="$RUN_DIR/times.txt"
  local log_file="$RUN_DIR/stdout.log"

  log "native-linux Vulkan $resolution"
  if [[ "$WARMUP" == "1" ]]; then
    env DISPLAY="$DISPLAY_VALUE" "$WORKLOADS_DIR/gravitymark/GravityMark/run_windowed_vk.sh" \
      -width "$WIDTH" -height "$HEIGHT" -asteroids "$GM_ASTEROIDS" \
      -count 1 -benchmark 1 -close 1 -vsync 0 >/dev/null 2>&1 || true
  fi
  set +e
  env DISPLAY="$DISPLAY_VALUE" "$WORKLOADS_DIR/gravitymark/GravityMark/run_windowed_vk.sh" \
    -width "$WIDTH" -height "$HEIGHT" -asteroids "$GM_ASTEROIDS" \
    -count "$GM_COUNT" -benchmark 1 -close 1 -vsync 0 -times "$TIMES_FILE" \
    >"$log_file" 2>&1
  local rc=$?
  set -e
  write_result_json "$RUN_DIR/result.json" native-linux native native vulkan vulkan "$resolution" "$rc" stdout.log times.txt
  [[ "$rc" -eq 0 ]] || log "native-linux Vulkan $resolution failed, see $log_file"
}

run_guest_vulkan() {
  local resolution="$1"
  split_res "$resolution"
  RUN_DIR="$RUN_ROOT/venus-linux/gravitymark-vulkan/$resolution"
  mkdir -p "$RUN_DIR"
  local remote_dir="/tmp/graphics-benchmark-results/$RUN_TAG/venus-vulkan/$resolution"
  local remote_times="$remote_dir/times.txt"
  local log_file="$RUN_DIR/stdout.log"

  log "venus-linux Vulkan $resolution over SSH:$GUEST_PORT"
  local remote_cmd="set -euo pipefail; mkdir -p '$remote_dir'; cd '$GUEST_REPO'; DISPLAY='$GUEST_DISPLAY' workloads/gravitymark/GravityMark/run_windowed_vk.sh -width '$WIDTH' -height '$HEIGHT' -asteroids '$GM_ASTEROIDS' -count '$GM_COUNT' -benchmark 1 -close 1 -vsync 0 -times '$remote_times'"
  run_remote_capture "$log_file" "$remote_cmd"
  local rc=$?
  if [[ "$rc" -eq 0 ]]; then
    scp_from_guest "$remote_times" "$RUN_DIR/times.txt" || true
  else
    scp_from_guest "$remote_times" "$RUN_DIR/times.txt" >/dev/null 2>&1 || true
    log "venus-linux Vulkan $resolution failed, see $log_file"
  fi
  write_result_json "$RUN_DIR/result.json" venus-linux virtualization venus vulkan vulkan "$resolution" "$rc" stdout.log times.txt "$remote_times"
}

run_guest_dxvk() {
  local resolution="$1"
  split_res "$resolution"
  RUN_DIR="$RUN_ROOT/venus-linux/gravitymark-dxvk-d3d11/$resolution"
  mkdir -p "$RUN_DIR"
  local remote_dir="/tmp/graphics-benchmark-results/$RUN_TAG/venus-dxvk-d3d11/$resolution"
  local remote_times="$remote_dir/times.txt"
  local log_file="$RUN_DIR/stdout.log"

  log "venus-linux DXVK/D3D11 $resolution over SSH:$GUEST_PORT"
  local remote_cmd="set -euo pipefail; mkdir -p '$remote_dir'; cd '$GUEST_REPO'; DISPLAY='$GUEST_DISPLAY' GM_WIDTH='$WIDTH' GM_HEIGHT='$HEIGHT' GM_ASTEROIDS='$GM_ASTEROIDS' workloads/gravitymark/dx/run.sh --d3d11 -- -count '$GM_COUNT' -vsync 0 -times '$remote_times'"
  run_remote_capture "$log_file" "$remote_cmd"
  local rc=$?
  : > "$RUN_DIR/times.txt"
  scp_from_guest "$remote_times" "$RUN_DIR/times.txt" >/dev/null 2>&1 || true
  [[ "$rc" -eq 0 ]] || log "venus-linux DXVK/D3D11 $resolution failed, see $log_file"
  write_result_json "$RUN_DIR/result.json" venus-linux virtualization venus directx d3d11-dxvk "$resolution" "$rc" stdout.log times.txt "$remote_times"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --res) RESOLUTIONS_STR="$2"; shift 2 ;;
    --res=*) RESOLUTIONS_STR="${1#*=}"; shift ;;
    --guest-port) GUEST_PORT="$2"; shift 2 ;;
    --guest-port=*) GUEST_PORT="${1#*=}"; shift ;;
    --guest-user) GUEST_USER="$2"; shift 2 ;;
    --guest-user=*) GUEST_USER="${1#*=}"; shift ;;
    --guest-host) GUEST_HOST="$2"; shift 2 ;;
    --guest-host=*) GUEST_HOST="${1#*=}"; shift ;;
    --guest-repo) GUEST_REPO="$2"; shift 2 ;;
    --guest-repo=*) GUEST_REPO="${1#*=}"; shift ;;
    --run-tag) RUN_TAG="$2"; RUN_ROOT="$RESULTS_ROOT/$RUN_TAG"; shift 2 ;;
    --run-tag=*) RUN_TAG="${1#*=}"; RUN_ROOT="$RESULTS_ROOT/$RUN_TAG"; shift ;;
    --asteroids) GM_ASTEROIDS="$2"; shift 2 ;;
    --asteroids=*) GM_ASTEROIDS="${1#*=}"; shift ;;
    --count) GM_COUNT="$2"; shift 2 ;;
    --count=*) GM_COUNT="${1#*=}"; shift ;;
    --no-native) RUN_NATIVE=0; shift ;;
    --no-guest-vk) RUN_GUEST_VK=0; shift ;;
    --no-guest-dxvk) RUN_GUEST_DXVK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

RESOLUTIONS_STR="${RESOLUTIONS_STR//,/ }"
read -r -a RESOLUTIONS_ARR <<< "$RESOLUTIONS_STR"
[[ "${#RESOLUTIONS_ARR[@]}" -gt 0 ]] || die "no resolutions configured"

SSH_BASE=(
  ssh -p "$GUEST_PORT" -i "$GUEST_KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
)
SCP_BASE=(
  scp -P "$GUEST_PORT" -i "$GUEST_KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

mkdir -p "$RUN_ROOT"

if [[ "$RUN_NATIVE" == "1" ]]; then
  require_file "$WORKLOADS_DIR/gravitymark/GravityMark/run_windowed_vk.sh" "install host GravityMark first with workloads/gravitymark/install.sh"
fi
if [[ "$RUN_GUEST_VK" == "1" || "$RUN_GUEST_DXVK" == "1" ]]; then
  require_file "$GUEST_KEY" "guest SSH key missing"
  ssh_guest "test -d '$GUEST_REPO'" || die "cannot access guest repo at $GUEST_REPO over SSH port $GUEST_PORT"
fi

cat > "$RUN_ROOT/manifest.json" <<EOF
{
  "run_tag": "$(json_escape "$RUN_TAG")",
  "started_utc": "$(date -u +%FT%TZ)",
  "resolutions": "$(json_escape "${RESOLUTIONS_ARR[*]}")",
  "guest": {
    "host": "$(json_escape "$GUEST_HOST")",
    "port": $GUEST_PORT,
    "user": "$(json_escape "$GUEST_USER")",
    "repo": "$(json_escape "$GUEST_REPO")",
    "display": "$(json_escape "$GUEST_DISPLAY")"
  },
  "workload": "gravitymark",
  "asteroids": $GM_ASTEROIDS,
  "count": $GM_COUNT
}
EOF

log "results -> $RUN_ROOT"
for res in "${RESOLUTIONS_ARR[@]}"; do
  split_res "$res"
  [[ "$RUN_NATIVE" == "1" ]] && run_native_vulkan "$res"
  [[ "$RUN_GUEST_VK" == "1" ]] && run_guest_vulkan "$res"
  [[ "$RUN_GUEST_DXVK" == "1" ]] && run_guest_dxvk "$res"
done

log "done. Result JSON files:"
find "$RUN_ROOT" -name result.json -print | sort
