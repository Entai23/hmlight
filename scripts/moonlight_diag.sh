#!/usr/bin/env bash
# Moonlight HarmonyOS port diagnostic harness.
#
# Usage:
#   ./scripts/moonlight_diag.sh devices
#   ./scripts/moonlight_diag.sh start [--serial SN] [--host HOST_IP]
#   ./scripts/moonlight_diag.sh collect [--serial SN]
#   ./scripts/moonlight_diag.sh summarize <session-dir|tar.gz>
#   ./scripts/moonlight_diag.sh hostcap --ip HOST_IP
#
# `start` launches the app (optional), clears hilog and streams device logs
# into the session directory. `collect` stops streaming, pulls the app
# sandbox JSONL written by the native bridge, packs everything and prints
# an analysis summary.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIAG_ROOT="$ROOT/diagnostics"
BUNDLE="${BUNDLE:-com.entai23.hmlight}"
LATEST="$DIAG_ROOT/.latest"

find_hdc() {
  if command -v hdc >/dev/null 2>&1; then command -v hdc; return; fi
  local candidates=(
    "${DEVECO_HOME:-}/sdk/default/openharmony/toolchains/hdc"
    "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
    "$HOME/Library/Huawei/Sdk/openharmony/toolchains/hdc"
    "$HOME/Library/OpenHarmony/Sdk/openharmony/toolchains/hdc"
  )
  local c
  for c in "${candidates[@]}"; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return; fi
  done
  echo ""
}

HDC="$(find_hdc)"
if [ -z "$HDC" ]; then
  echo "hdc not found. Set DEVECO_HOME or add the SDK toolchains dir to PATH." >&2
  exit 1
fi

SERIAL=""
parse_serial() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --serial) SERIAL="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}
parse_serial "$@"

HDC_ARGS=()
if [ -n "$SERIAL" ]; then HDC_ARGS=(-t "$SERIAL"); fi

hdc_shell() { "$HDC" "${HDC_ARGS[@]}" shell "$@"; }

require_device() {
  local targets
  targets="$("$HDC" list targets 2>/dev/null | grep -v '^\s*$' | grep -v 'Empty')"
  if [ -z "$targets" ]; then
    echo "No connected device. Connect the phone and enable USB debugging." >&2
    exit 1
  fi
  if [ -z "$SERIAL" ]; then
    local count
    count="$(echo "$targets" | wc -l | tr -d ' ')"
    if [ "$count" -gt 1 ]; then
      echo "Multiple devices connected, pass --serial:" >&2
      echo "$targets" >&2
      exit 1
    fi
    SERIAL="$(echo "$targets" | head -1)"
    HDC_ARGS=(-t "$SERIAL")
  fi
}

cmd_devices() {
  echo "hdc: $HDC"
  "$HDC" list targets
}

cmd_start() {
  local host=""
  local args=("$@")
  local i=0
  while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
      --host) host="${args[$((i+1))]}"; i=$((i+2)) ;;
      *) i=$((i+1)) ;;
    esac
  done

  require_device
  mkdir -p "$DIAG_ROOT"
  local dir="$DIAG_ROOT/session-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  echo "$dir" > "$LATEST"

  echo "session: $dir"
  echo "device : $SERIAL"

  {
    echo "serial=$SERIAL"
    echo "started_at=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "bundle=$BUNDLE"
    echo "host=$host"
    echo "--- device ---"
    hdc_shell "param get const.product.model" 2>/dev/null
    hdc_shell "param get const.product.brand" 2>/dev/null
    hdc_shell "param get const.ohos.fullname" 2>/dev/null
    hdc_shell "param get const.ohos.apiversion" 2>/dev/null
    hdc_shell "uname -a" 2>/dev/null
  } > "$dir/device.txt"

  hdc_shell "hilog -r" >/dev/null 2>&1 || true
  echo "streaming hilog..."
  ( "$HDC" "${HDC_ARGS[@]}" hilog > "$dir/hilog.txt" 2>&1 ) &
  echo $! > "$dir/.hilog_pid"

  echo "starting $BUNDLE..."
  hdc_shell "aa start -a EntryAbility -b $BUNDLE" 2>&1 | tail -2 || true
  sleep 2
  local pid
  pid="$(hdc_shell "pidof $BUNDLE" 2>/dev/null | tr -d '\r')"
  echo "pid=$pid" | tee -a "$dir/device.txt"

  echo
  echo "Run the app test now (probe / stream). Then execute:"
  echo "  ./scripts/moonlight_diag.sh collect${SERIAL:+ --serial $SERIAL}"
  if [ -n "$host" ]; then
    echo
    echo "Optional host-side capture (run on the Sunshine PC, not on the Mac):"
    hostcap_hint "$host"
  fi
}

hostcap_hint() {
  local ip="$1"
  cat <<EOF
  Windows (Sunshine PC, admin PowerShell):
    Install Wireshark + Npcap, then:
      dumpcap -i 1 -f "host $ip and udp portrange 47998-48010" -w moonlight-udp.pcapng
  Linux / macOS Sunshine host:
      sudo tcpdump -i any -s 0 -w moonlight-udp.pcap "host $ip and udp portrange 47998-48010"
  Copy the pcap into the session directory before running summarize.
EOF
}

latest_dir() {
  if [ -f "$LATEST" ]; then cat "$LATEST"; fi
}

cmd_collect() {
  require_device
  local dir
  dir="$(latest_dir)"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo "No active session. Run 'start' first." >&2
    exit 1
  fi

  if [ -f "$dir/.hilog_pid" ]; then
    kill "$(cat "$dir/.hilog_pid")" 2>/dev/null || true
    rm -f "$dir/.hilog_pid"
  fi

  local pid
  pid="$(hdc_shell "pidof $BUNDLE" 2>/dev/null | tr -d '\r')"
  echo "app pid: ${pid:-<not running>}"

  local remote_candidates=(
    "/data/app/el2/100/base/$BUNDLE/haps/entry/files/diag"
    "/data/app/el2/0/base/$BUNDLE/haps/entry/files/diag"
    "/data/app/el1/bundle/public/$BUNDLE/files/diag"
  )
  local pulled=0
  local remote
  for remote in "${remote_candidates[@]}"; do
    if hdc_shell "test -d $remote && echo yes" 2>/dev/null | tr -d '\r' | grep -q yes; then
      echo "pulling $remote"
      mkdir -p "$dir/app_files"
      if "$HDC" "${HDC_ARGS[@]}" file recv "$remote" "$dir/app_files" >/dev/null 2>&1; then
        pulled=1
        break
      fi
    fi
  done
  if [ "$pulled" -eq 0 ]; then
    echo "WARN: app sandbox diag dir not found (debuggable build required)." >&2
    hdc_shell "find /data/app/el2 -maxdepth 8 -type d -name diag -path '*$BUNDLE*' 2>/dev/null" 2>/dev/null || true
  fi

  if [ -f "$dir/hilog.txt" ]; then
    grep -i "MoonPort\|moonbridge\|moonlight" "$dir/hilog.txt" > "$dir/hilog_moonlight.txt" 2>/dev/null || true
  fi

  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local tar="$DIAG_ROOT/moonlight-diag-$stamp.tar.gz"
  tar -czf "$tar" -C "$DIAG_ROOT" "$(basename "$dir")"
  echo "packed: $tar"

  cmd_summarize "$tar"
}

cmd_summarize() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    target="$(latest_dir)"
  fi
  [ -e "$target" ] || { echo "nothing to summarize: $target" >&2; exit 1; }

  local tmp=""
  local src="$target"
  if [ -f "$target" ] && [[ "$target" == *.tar.gz ]]; then
    tmp="$(mktemp -d)"
    tar -xzf "$target" -C "$tmp"
    src="$(find "$tmp" -maxdepth 1 -type d -name 'session-*' | head -1)"
  fi

  local jsonl
  jsonl="$(find "$src" -name 'moonlight_native.jsonl' 2>/dev/null | head -1)"

  echo "================ Moonlight diagnostic summary ================"
  if [ -f "$src/device.txt" ]; then
    grep -E "serial=|started_at=|bundle=|host=|pid=|^OpenHarmony|^HarmonyOS" "$src/device.txt" 2>/dev/null | sed 's/^/  /'
  fi
  if [ -n "$jsonl" ] && [ -f "$jsonl" ]; then
    echo
    echo "--- native events ($(wc -l < "$jsonl" | tr -d ' ') lines) ---"
    python3 - "$jsonl" <<'PY'
import json, sys, collections, statistics
path = sys.argv[1]
cats = collections.Counter()
stages = []
stats = []
net = []
errors = []
for line in open(path, encoding='utf-8', errors='replace'):
    line = line.strip()
    if not line.startswith('{'):
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    cats[e.get('cat', '?')] += 1
    cat = e.get('cat')
    if cat == 'event' and e.get('type') in ('stage', 'stageComplete', 'stageFailed', 'connected', 'terminated'):
        stages.append(e)
    elif cat == 'stats':
        stats.append(e)
    elif cat == 'net':
        net.append(e)
    elif cat == 'conn' and 'failed' in str(e.get('msg', '')).lower():
        errors.append(e)
print('event categories:', dict(cats))
if stages:
    print('\nhandshake stages:')
    for e in stages:
        t = e.get('type')
        p = e.get('payload') or {}
        print(f"  {t:14s} stage={p.get('stage','-'):>3} {p.get('name','')} "
              f"+{p.get('elapsedMs','-')}ms err={p.get('errorCode','-')}")
if net:
    print('\nnetwork probes:')
    for e in net:
        print('  ', e.get('msg'))
if stats:
    fps = [s.get('fps', 0) for s in stats]
    rtt = [s.get('rttUs', 0) for s in stats if s.get('rttUs', 0) > 0]
    print(f"\nstream stats: samples={len(stats)} fps min/avg/max="
          f"{min(fps):.1f}/{statistics.mean(fps):.1f}/{max(fps):.1f}")
    if rtt:
        print(f"rtt us min/avg/max={min(rtt)}/{statistics.mean(rtt):.0f}/{max(rtt)}")
    last = stats[-1]
    print('last sample:', json.dumps(last, ensure_ascii=False))
if errors:
    print('\nconnection errors:')
    for e in errors[-10:]:
        print('  ', e.get('msg'))
PY
  else
    echo "WARN: moonlight_native.jsonl not found in session." >&2
  fi
  if [ -f "$src/hilog_moonlight.txt" ]; then
    echo
    echo "--- hilog (MoonPort) tail ---"
    tail -20 "$src/hilog_moonlight.txt" | sed 's/^/  /'
  fi
  echo "=============================================================="
  if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
}

cmd_hostcap() {
  local ip=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ip) ip="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$ip" ] || { echo "usage: $0 hostcap --ip HOST_IP" >&2; exit 1; }
  hostcap_hint "$ip"
}

case "${1:-}" in
  devices) cmd_devices ;;
  start) shift; cmd_start "$@" ;;
  collect) shift; cmd_collect "$@" ;;
  summarize) shift; cmd_summarize "$@" ;;
  hostcap) shift; cmd_hostcap "$@" ;;
  *)
    echo "usage: $0 {devices|start|collect|summarize|hostcap} [options]"
    echo "run '$0' with a command from the header comment for details"
    exit 1
    ;;
esac
