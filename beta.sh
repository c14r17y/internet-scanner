#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "[Error] Run with sudo"
  exit 1
fi

TS=$(date +"%Y-%m-%d_%H-%M-%S")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$SCRIPT_DIR/.tmp/zmap"
mkdir -p "$SCRIPT_DIR/.tmp/zgrab"
mkdir -p "$SCRIPT_DIR/.tmp/mcutil"
mkdir -p "$SCRIPT_DIR/out/zgrab"
mkdir -p "$SCRIPT_DIR/.logs"

logfile="$SCRIPT_DIR/.logs/log_${TS}.log"

log() {
  echo "[$(date '+%H:%M:%S')] $*" | tee -a "$logfile"
}

# ---------------- CONFIG ----------------

ranges="2.132.64.0/22"
ports="23,80,81,22,8081,25565"

gatewaymac="c0:25:2f:50:83:95"
rate="150"

outfilter="success=1 && repeat=0"
outfields="saddr,sport"

zmap_log="$SCRIPT_DIR/.logs/zmap_${TS}.log"

# ---------------- HELPERS ----------------

get_proto() {
  case "$1" in
    80|81|8080|8081) echo "http" ;;
    22) echo "ssh" ;;
    23) echo "telnet" ;;
    *) return 1 ;;
  esac
}

is_minecraft() {
  case "$1" in
    25565|25566|25567) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------- ZMAP ----------------

log "[ZMAP] Starting scan"

zmap "$ranges" \
  --target-ports="$ports" \
  --gateway-mac="$gatewaymac" \
  --rate="$rate" \
  --output-module=json \
  --output-filter="$outfilter" \
  --output-fields="$outfields" \
  --output-file="$SCRIPT_DIR/.tmp/zmap/out_${TS}.json" \
  --log-file="$zmap_log"

log "[ZMAP] Done"

# ---------------- ROUTER ----------------

mc_targets="$SCRIPT_DIR/.tmp/zgrab/mc_targets_${TS}.txt"
: > "$mc_targets"

log "[ROUTER] Splitting targets"

jq -c '.[]? // empty' "$SCRIPT_DIR/.tmp/zmap/out_${TS}.json" \
| while read -r line; do

  ip=$(echo "$line" | jq -r '.saddr')
  port=$(echo "$line" | jq -r '.sport')

  if is_minecraft "$port"; then
    echo "$ip" >> "$mc_targets"
    continue
  fi

  proto=$(get_proto "$port") || continue

  echo "$ip:$port:$proto"
done > "$SCRIPT_DIR/.tmp/zgrab/http_targets_${TS}.txt"

# ---------------- ZGRAB2 ----------------

http_out="$SCRIPT_DIR/out/zgrab/http_${TS}.json"

if [ -s "$SCRIPT_DIR/.tmp/zgrab/http_targets_${TS}.txt" ]; then
  log "[ZGRAB] Running HTTP/SSH/TELNET"

  while IFS=: read -r ip port proto; do
    zgrab2 "$proto" \
      --port "$port" \
      --input-file <(echo "$ip") \
      --output-file "$http_out" \
      --senders 2 \
      --dns-resolution-timeout 10 \
      --user-agent "Mozilla/5.0"
  done < "$SCRIPT_DIR/.tmp/zgrab/http_targets_${TS}.txt"
fi

# ---------------- MCUTIL ----------------

mc_out="$SCRIPT_DIR/out/mcutil/minecraft_${TS}.jsonl"

if [ -s "$mc_targets" ]; then
  log "[MINECRAFT] Running mcutil stage"

  sort -u "$mc_targets" | ./mcgrab > "$mc_out"
else
  log "[MINECRAFT] No targets"
fi

# ---------------- MERGE ----------------

final="$SCRIPT_DIR/out/zgrab/final_${TS}.json"

log "[MERGE] Combining outputs"

jq -s '
  {
    http: .[0],
    minecraft: .[1]
  }
' "$http_out" "$mc_out" > "$final"

log "[DONE] Output: $final"