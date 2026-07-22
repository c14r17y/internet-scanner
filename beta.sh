#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "[Error] Run with sudo"
  exit 1
fi

### INDEV START ###

CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)/.config-dev"

for cfg in \
    main.conf \
    ports.conf \
    ranges.conf \
    zmap.conf \
    http.conf \
    mc.conf
do
    . "$CONFIG_DIR/$cfg"
done

### INDEV END ###

TS=$(date +"%Y-%m-%d_%H-%M-%S")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$SCRIPT_DIR/.tmp/zmap"
mkdir -p "$SCRIPT_DIR/.tmp/zgrab"
mkdir -p "$SCRIPT_DIR/.tmp/mcgrab"
mkdir -p "$SCRIPT_DIR/out/zgrab"
mkdir -p "$SCRIPT_DIR/.logs"

logfile="$SCRIPT_DIR/.logs/log_${TS}.log"

log() {
  echo "[$(date '+%H:%M:%S')] $*" | tee -a "$logfile"
}

# ---------------- Config ----------------

zmap_log="$SCRIPT_DIR/.logs/zmap_${TS}.log"

# ---------------- Helpers ----------------

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
    25565|25566|25567|19132|19133) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------- ZMAP ----------------

log "[ZMAP] Starting scan"

if [[ "$BYTE_RATEMODE" == "true" ]]; then
    RATE_ARG=(--bandwidth="$BPS_RATE")
else
    RATE_ARG=(--rate="$RATE")
fi

zmap "$RANGES" \
  --output-module=json \
  --target-ports="$PORTS" \
  --gateway-mac="$GATEWAY_MAC" \
  "${RATE_ARG[@]}" \
  --output-filter="$OUTPUT_FILTER" \
  --output-fields="$OUTPUT_FIELDS" \
  --output-file="$SCRIPT_DIR/.tmp/zmap/out_${TS}.json" \
  --retries="$RETRIES" \
  --log-file="$zmap_log"

log "[ZMAP] Done"

# ---------------- Router ----------------

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

# ---------------- MCGRAB ----------------

mc_out="$SCRIPT_DIR/out/mcgrab/minecraft_${TS}.jsonl"

if [ -s "$mc_targets" ]; then
  log "[MCGRAB] Running MINECRAFT stage"

  sort -u "$mc_targets" | ./mcgrab > "$mc_out"
else
  log "[MCGRAB] No targets"
fi

# ---------------- Merge ----------------

final="$SCRIPT_DIR/out/zgrab/final_${TS}.json"

log "[MERGE] Combining outputs"

jq -s '
  {
    http: .[0],
    minecraft: .[1]
  }
' "$http_out" "$mc_out" > "$final"

log "[DONE] Output: $final"
