#!/usr/bin/env bash
# Frabs Benchmark for Linux: https://benchmark.frabs.net
#
# Measures this server's CPU, memory, disk and network and shows the results on
# benchmark.frabs.net. It installs nothing and changes nothing: every file it makes
# goes in one temporary folder that is deleted when it finishes, even if you stop it.
#
#   curl -sL https://raw.githubusercontent.com/frabsnet/benchmark/main/run.sh | bash -s YOURCODE
#
# What it sends to benchmark.frabs.net: the step it is on, the measurements below, and
# basic facts about the machine (OS, kernel, CPU model, core count, RAM, disk size,
# virtualisation). Never hostnames, IP addresses, users, files or processes.
set -u
export LC_ALL=C

CODE=${1:-}
API="https://api.frabs.net/v1/tools/bench"
if [[ ! $CODE =~ ^[A-Z2-9]{9}$ ]]; then
  echo "Usage: curl -sL https://raw.githubusercontent.com/frabsnet/benchmark/main/run.sh | bash -s YOURCODE"
  echo "Get your code at https://benchmark.frabs.net"
  exit 1
fi
for tool in curl dd sha256sum awk; do
  command -v "$tool" >/dev/null 2>&1 || { echo "This benchmark needs $tool, which isn't installed here."; exit 1; }
done

# One folder for everything, on a real disk (not /tmp, which is often memory).
base=/var/tmp; [[ -w $base ]] || base=${TMPDIR:-/tmp}
WORK=$(mktemp -d "$base/frabs-benchmark.XXXXXX") || { echo "Couldn't make a temporary folder."; exit 1; }
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT
trap 'echo; echo "Stopped. Everything this benchmark made has been removed."; exit 130' INT TERM

json() { # a JSON string: quotes and backslashes escaped, control characters dropped
  local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=$(printf '%s' "$s" | tr -d '\000-\037'); printf '"%s"' "${s:0:190}"
}
send() { curl -fsS -m 10 -X POST -H 'content-type: application/json' --data "$1" "$API/$CODE/event" >/dev/null 2>&1 || true; }
step() { # step key, state, detail
  send "{\"step\":\"$1\",\"state\":\"$2\",\"detail\":$(json "${3:-}")}"
  case $2 in running) printf '  %-34s ' "$3" ;; done) printf 'done  %s\n' "${4:-}" ;; skipped) printf 'skipped (%s)\n' "$3" ;; failed) printf 'failed (%s)\n' "$3" ;; esac
}
now() { date +%s%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", (b - a) / 1e9 }'; }
num() { awk -v v="$1" 'BEGIN { printf "%.1f", v }'; }

echo
echo "  Frabs Benchmark · https://benchmark.frabs.net/$CODE"
echo "  Nothing is installed. Everything it makes is removed at the end."
echo
send "{\"state\":\"start\",\"platform\":\"linux\"}"

# ---- the machine
step system running "Reading the system"
os=$( (. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-Linux}") || echo Linux)
cpu=$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null)
[[ -z $cpu ]] && cpu=$(lscpu 2>/dev/null | awk -F': +' '/Model name/ { print $2; exit }')
cores=$(nproc 2>/dev/null || echo 1)
ram=$(awk '/^MemTotal/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null)
read -r disk_total disk_free < <(df -Pm "$WORK" | awk 'NR == 2 { print $2, $4 }')
virt=$(systemd-detect-virt 2>/dev/null || true); [[ -z $virt ]] && virt=unknown
send "{\"system\":{\"os\":$(json "$os"),\"kernel\":$(json "$(uname -r)"),\"arch\":$(json "$(uname -m)"),\"cpu\":$(json "${cpu:-Unknown}"),\"cores\":${cores:-1},\"ram_mb\":${ram:-0},\"disk_mb\":${disk_total:-0},\"disk_free_mb\":${disk_free:-0},\"virtualisation\":$(json "$virt")}}"
step system done "Reading the system" "${cpu:-Unknown CPU}, $cores cores"

# ---- CPU: SHA-256 hashing, the same work on every machine
hash_mb() { dd if=/dev/zero bs=1M count="$1" 2>/dev/null | sha256sum >/dev/null; }
step cpu_single running "CPU, single core"
t0=$(now); hash_mb 256; t1=$(now)
# Size the real run to take about 5 seconds.
n=$(awk -v s="$(secs "$t0" "$t1")" 'BEGIN { n = int(256 * 5 / (s > 0.01 ? s : 0.01)); if (n < 256) n = 256; if (n > 16384) n = 16384; print n }')
t0=$(now); hash_mb "$n"; t1=$(now)
single=$(awk -v n="$n" -v s="$(secs "$t0" "$t1")" 'BEGIN { printf "%.1f", n / s }')
send "{\"results\":{\"cpu_single_mbs\":$single}}"
step cpu_single done "CPU, single core" "$single MB/s"

step cpu_multi running "CPU, all $cores cores"
t0=$(now); for ((i = 0; i < cores; i++)); do hash_mb "$n" & done; wait; t1=$(now)
multi=$(awk -v n="$n" -v c="$cores" -v s="$(secs "$t0" "$t1")" 'BEGIN { printf "%.1f", n * c / s }')
send "{\"results\":{\"cpu_multi_mbs\":$multi}}"
step cpu_multi done "CPU, all $cores cores" "$multi MB/s"

# ---- memory: copying through RAM
dd_rate() { # bytes and seconds from dd's summary line -> MB/s
  awk '/copied/ { for (i = 1; i <= NF; i++) if ($i == "s," || $i == "s") s = $(i - 1); b = $1 } END { if (s > 0) printf "%.1f", b / s / 1e6; else print 0 }'
}
step memory running "Memory speed"
mem=$(dd if=/dev/zero of=/dev/null bs=1M count=16384 2>&1 | dd_rate)
send "{\"results\":{\"memory_mbs\":$mem}}"
step memory done "Memory speed" "$mem MB/s"

# ---- disk: a test file sized to the free space (at most 1 GB, at most a tenth of what's free)
size=$(( ${disk_free:-0} / 10 )); (( size > 1024 )) && size=1024
f="$WORK/test.bin"
if (( size < 64 )); then
  for s in disk_write disk_read disk_iops; do step $s skipped "not enough free disk space"; done
else
  step disk_write running "Disk write, ${size} MB"
  w=$(dd if=/dev/zero of="$f" bs=1M count=$size oflag=direct conv=fdatasync 2>&1 | dd_rate)
  [[ $w == 0 ]] && w=$(dd if=/dev/zero of="$f" bs=1M count=$size conv=fdatasync 2>&1 | dd_rate)
  send "{\"results\":{\"disk_write_mbs\":$w}}"
  step disk_write done "Disk write" "$w MB/s"

  step disk_read running "Disk read, ${size} MB"
  r=$(dd if="$f" of=/dev/null bs=1M iflag=direct 2>&1 | dd_rate)
  [[ $r == 0 ]] && r=$(dd if="$f" of=/dev/null bs=1M 2>&1 | dd_rate)
  send "{\"results\":{\"disk_read_mbs\":$r}}"
  step disk_read done "Disk read" "$r MB/s"
  rm -f -- "$f"

  step disk_iops running "Disk 4K writes"
  k=$(dd if=/dev/zero of="$WORK/4k.bin" bs=4k count=16384 oflag=direct 2>&1 | dd_rate)
  [[ $k == 0 ]] && k=$(dd if=/dev/zero of="$WORK/4k.bin" bs=4k count=16384 conv=fdatasync 2>&1 | dd_rate)
  iops=$(awk -v m="$k" 'BEGIN { printf "%d", m * 1e6 / 4096 }')
  rm -f -- "$WORK/4k.bin"
  send "{\"results\":{\"disk_iops\":$iops}}"
  step disk_iops done "Disk 4K writes" "$iops IOPS"
fi

# ---- network: download from big public test files, 8 seconds each
SITES=(
  "Cloudflare (nearest)|https://speed.cloudflare.com/__down?bytes=50000000"
  "Hetzner, Germany|https://fsn1-speed.hetzner.com/1GB.bin"
  "OVH, France|https://proof.ovh.net/files/1Gb.dat"
  "Clouvider, London|https://lon.speedtest.clouvider.net/1g.bin"
  "Hetzner, US East|https://ash-speed.hetzner.com/1GB.bin"
)
step network running "Network download"
dl="["; lat="["; best=0
for site in "${SITES[@]}"; do
  name=${site%%|*}; url=${site#*|}
  printf '\n    %-30s ' "$name"
  bps=$(curl -s -o /dev/null -m 8 -w '%{speed_download}' "$url" 2>/dev/null); bps=${bps:-0}
  mbit=$(awk -v b="$bps" 'BEGIN { printf "%.1f", b * 8 / 1e6 }')
  ms=$(curl -s -o /dev/null -m 5 -r 0-0 -w '%{time_connect}' "$url" 2>/dev/null); ms=$(awk -v t="${ms:-0}" 'BEGIN { printf "%.1f", t * 1000 }')
  printf '%s Mbit/s, %s ms' "$mbit" "$ms"
  dl+="{\"name\":$(json "$name"),\"value\":$mbit,\"unit\":\"Mbit/s\"},"
  lat+="{\"name\":$(json "$name"),\"value\":$ms,\"unit\":\"ms\"},"
  best=$(awk -v a="$best" -v b="$mbit" 'BEGIN { print (b > a ? b : a) }')
  send "{\"step\":\"network\",\"state\":\"running\",\"detail\":$(json "Downloading from $name")}"
done
echo
dl="${dl%,}]"; lat="${lat%,}]"
send "{\"results\":{\"net_download\":$dl,\"net_best_mbit\":$best}}"
step network done "Network download" "best $best Mbit/s"

step upload running "Network upload"
dd if=/dev/zero of="$WORK/up.bin" bs=1M count=100 2>/dev/null
ubps=$(curl -s -o /dev/null -m 8 -w '%{speed_upload}' --data-binary @"$WORK/up.bin" -H 'content-type: application/octet-stream' https://speed.cloudflare.com/__up 2>/dev/null); ubps=${ubps:-0}
up=$(awk -v b="$ubps" 'BEGIN { printf "%.1f", b * 8 / 1e6 }')
rm -f -- "$WORK/up.bin"
send "{\"results\":{\"net_upload_mbit\":$up}}"
step upload done "Network upload" "$up Mbit/s"

step latency running "Network latency"
send "{\"results\":{\"latency\":$lat}}"
step latency done "Network latency" ""

# ---- leave nothing behind
step cleanup running "Removing everything it made"
cleanup
step cleanup done "Removing everything it made" ""
send "{\"state\":\"finished\"}"
echo
echo "  Done. Your results: https://benchmark.frabs.net/$CODE"
echo
