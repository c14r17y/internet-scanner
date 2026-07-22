#!/bin/bash

set -euo pipefail

# Check root
if [ "$(id -u)" -ne 0 ]; then
  clear
  echo -e "[Error] Run with sudo: sudo $0"
  exit 1
fi

### INDEV START ###

CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)/.config-dev"

for cfg in \
    main.conf \
    ports.conf \
    ranges.conf \
    zmap.conf \
    zgrab.conf \
    http.conf \
    mc.conf
do
    . "$CONFIG_DIR/$cfg"
done

### INDEV END ###

TS=$(date +"%Y-%m-%d_%H-%M-%S")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$SCRIPT_DIR/.tmp/zgrab"
mkdir -p "$SCRIPT_DIR/.tmp/zmap"
mkdir -p "$SCRIPT_DIR/.logs"
mkdir -p "$SCRIPT_DIR/out/zgrab"
mkdir -p "$SCRIPT_DIR/out/minecraft"
mkdir -p "$SCRIPT_DIR/.logs/zmap"
mkdir -p "$SCRIPT_DIR/.logs/zgrab"

logfile="$SCRIPT_DIR/.logs/log_${TS}.log"

ranges=$cherrynet
dedup="default"
outfilter="success=1 && repeat=0"
outfields="saddr,sport"
mcgrab_workers="100"
retries="1"
cooldowntime="8"
sbr="14"
sas="120"

IFS=',' read -r -a range_array <<< "$RANGES"
IFS=',' read -r -a port_array <<< "$PORTS"

log_command() {
  echo "($(date '+%Y-%m-%d %H:%M:%S')) $*" | tee -a "$logfile"
}

get_proto() {
  case "$1" in
    80|443|8080)
      echo "http"
      ;;
    21)
      echo "ftp"
      ;;
    22)
      echo "ssh"
      ;;
    23)
      echo "telnet"
      ;;
    *)
      return 1
      ;;
  esac
}

export PATH=$PATH:$HOME/go/bin

cat "$SCRIPT_DIR/banner.txt"

# -------------------------
# ZMAP PHASE
# -------------------------
total_ranges=${#range_array[@]}
for index in "${!range_array[@]}"; do
  range="${range_array[$index]}"
  outputfile="$SCRIPT_DIR/.tmp/zmap/out_${TS}_${index}.json"
  if [[ "$BYTE_RATEMODE" == "true" ]]; then
    RATE_ARG=(--bandwidth="$BPS_RATE")
  else
    RATE_ARG=(--rate="$RATE")
  fi
  log_command "[Zmap] ($((index+1))/$total_ranges) Scanning cidr: $range"
  zmap "$range" \
    --no-header-row \
    --target-ports="$PORTS" \
    --gateway-mac="$GATEWAY_MAC" \
    --cooldown-time="$COOLDOWNTIME" \
    --dedup-method="$DEDUP" \
    --output-module=json \
    --output-filter="$OUTPUT_FILTER" \
    --output-fields="$OUTPUT_FIELDS" \
    --retries="$RETRIES" \
    "${RATE_ARG[@]}" \
    --output-file="$outputfile" \
    --verbosity="$VERBOSITY" \
    --log-file="$zmap_logfile" || {
      log_command "[Error] zmap failed cidr $range"
      continue
    }

  log_command "[Zmap] finished cidr $range"
  scanned_ips=$(jq -r '.saddr' "$outputfile" | sort -u | wc -l)
  log_command "[Zmap] Scanned IPs: $scanned_ips"
  log_command "[Sleep] ${sbr}s between scans"
  sleep "$sbr"
done

log_command "[Zmap] done"
sleep "$sas"

# -------------------------
# TARGET FILES
# -------------------------
MC_TARGETS="$SCRIPT_DIR/.tmp/minecraft_${TS}.txt"
: > "$MC_TARGETS"

has_zgrab=false
zgrab_outputs=()

# -------------------------
# PROCESS RESULTS
# -------------------------
for p in "${port_array[@]}"; do

  # Minecraft ports
  if [[ "$p" =~ ^(25565|25566|25567|19132|19133)$ ]]; then

    jq -r "select(.sport == $p) | \"\(.saddr):\(.sport)\"" \
      "$SCRIPT_DIR/.tmp/zmap/"*.json \
      >> "$MC_TARGETS"

    continue
  fi

  # HTTP/other zgrab protocols
  if proto=$(get_proto "$p" 2>/dev/null); then
    has_zgrab=true
    targets_file="$SCRIPT_DIR/.tmp/zgrab/targets_${p}.txt"

    jq -r "select(.sport == $p) | .saddr" \
      "$SCRIPT_DIR/.tmp/zmap/"*.json \
      | sort -u > "$targets_file"

    [ ! -s "$targets_file" ] && continue

    zgrab_out="$SCRIPT_DIR/out/zgrab/zgrab_${TS}_p${p}.json"
    log_command "[Zgrab] $proto port $p -> $(wc -l < "$targets_file") hosts"

    ./bin/zgrab2 "$proto" \
      --port "$p" \
      --senders "$ZSENDERS" \
      --dns-resolution-timeout "$ZDNSTIMEOUT" \
      --user-agent "$ZUSERAGENT" \
      --input-file "$targets_file" \
      --output-file "$zgrab_out"

    zgrab_outputs+=("$zgrab_out")

  fi
done

# -------------------------
# MC GRABBER
# -------------------------
sort -u "$MC_TARGETS" -o "$MC_TARGETS"

if [ -s "$MC_TARGETS" ]; then
  log_command "[MC] found $(wc -l < "$MC_TARGETS") targets"

  mc_out="$SCRIPT_DIR/out/minecraft/minecraft_${TS}.txt"

  #./bin/mcgraber --workers "$mcgrab_workers" < "$MC_TARGETS" > "$mc_out"
  cat "$MC_TARGETS"  | ./bin/mcgraber --workers "$mcgrab_workers" | jq -s '.' > "$mc_out"

  log_command "[MC] saved -> $mc_out"
fi

# -------------------------
# MERGE ZGRAB OUTPUT
# -------------------------
if $has_zgrab && [ "${#zgrab_outputs[@]}" -gt 0 ]; then
  jq -s 'map(select(.data != null))' "${zgrab_outputs[@]}" > "$jarray"
  log_command "[Zgrab] merged -> $jarray"
else
  log_command "[Zgrab] skipped"
fi

log_command "[Done]"
