#!/bin/sh
# Frabs Benchmark for Linux: https://benchmark.frabs.net
#
# Measures this server's CPU, memory, disk and network and shows the results on
# benchmark.frabs.net. It installs nothing and changes nothing: every file it makes
# goes in one temporary folder that is deleted when it finishes, even if you stop it.
#
#   curl -sL https://raw.githubusercontent.com/frabsnet/benchmark/main/run.sh | sh -s YOURCODE
#   wget -qO- https://raw.githubusercontent.com/frabsnet/benchmark/main/run.sh | sh -s YOURCODE
#
# Plain sh, so it runs on any Linux: Debian, Ubuntu, RHEL, Alpine, BusyBox and minimal
# containers. It uses only what the server already has (curl or wget, dd, and any one of
# sha256sum, sha1sum, md5sum, cksum or gzip) and needs no root.
#
# What it sends to benchmark.frabs.net: the step it is on, the measurements, and basic
# facts about the machine (OS, kernel, CPU model, core count, RAM, disk size,
# virtualisation). Never hostnames, IP addresses, users, files or processes.

API="https://api.frabs.net/v1/tools/bench"
LC_ALL=C; export LC_ALL

has() { command -v "$1" >/dev/null 2>&1; }

# Milliseconds since a fixed point (BusyBox date may not do nanoseconds; /proc/uptime always works).
ms() {
  t=$(date +%s%N 2>/dev/null)
  case $t in
    *[!0-9]*|'') read -r up _ < /proc/uptime; echo $(( ${up%.*} * 1000 + 1${up#*.}0 - 1000 )) ;;
    *) echo $(( t / 1000000 )) ;;
  esac
}
# A value times ten, written with one decimal: 1234 -> 123.4
dec() { echo "$(( $1 / 10 )).$(( $1 % 10 ))"; }
# A JSON string: control characters dropped, backslashes and quotes escaped.
json() { printf '"%s"' "$(printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-190)"; }

post() {
  if [ "$HTTP" = curl ]; then curl -fsS -m 10 -X POST -H 'content-type: application/json' --data "$1" "$API/$CODE/event" </dev/null >/dev/null 2>&1
  else wget -q -T 10 -O /dev/null --header='content-type: application/json' --post-data="$1" "$API/$CODE/event" </dev/null >/dev/null 2>&1; fi
  return 0
}
step() { # key, state, label, shown
  post "{\"step\":\"$1\",\"state\":\"$2\",\"detail\":$(json "$3")}"
  case $2 in
    running) printf '  %-34s ' "$3" ;;
    done) echo "done  $4" ;;
    skipped) echo "skipped ($3)" ;;
  esac
}
result() { post "{\"results\":{$1}}"; }
since() { took=$(( $(ms) - $1 )); [ $took -lt 1 ] && took=1; echo $took; }

# Bytes a download gets in up to $1 seconds.
fetch_for() {
  if [ "$HTTP" = curl ]; then curl -s -m "$1" -o - "$2" </dev/null 2>/dev/null | wc -c
  elif has timeout; then timeout "$1" wget -q -O - "$2" </dev/null 2>/dev/null | wc -c
  else
    ( wget -q -O - "$2" </dev/null 2>/dev/null | wc -c > "$WORK/n" ) & p=$!
    sleep "$1"; kill $p 2>/dev/null; wait $p 2>/dev/null; cat "$WORK/n" 2>/dev/null || echo 0
  fi
}
hash_mb() { dd if=/dev/zero bs=1048576 count="$1" 2>/dev/null | $HASH >/dev/null 2>&1; }

main() {
  CODE=$1
  case $CODE in
    [A-Z2-9][A-Z2-9][A-Z2-9][A-Z2-9][A-Z2-9][A-Z2-9][A-Z2-9][A-Z2-9][A-Z2-9]) ;;
    *) echo "Usage: curl -sL https://raw.githubusercontent.com/frabsnet/benchmark/main/run.sh | sh -s YOURCODE"
       echo "Get your code at https://benchmark.frabs.net"; exit 1 ;;
  esac
  if has curl; then HTTP=curl; elif has wget; then HTTP=wget; else echo "This benchmark needs curl or wget."; exit 1; fi
  # Results go to benchmark.frabs.net over HTTPS, so check that works before measuring anything.
  if [ "$HTTP" = curl ]; then curl -fsS -m 15 -o /dev/null "$API/$CODE" </dev/null 2>/dev/null; else wget -q -T 15 -O /dev/null "$API/$CODE" </dev/null 2>/dev/null; fi
  if [ $? -ne 0 ]; then
    echo "This server can't reach https://api.frabs.net, so results couldn't be shown."
    [ "$HTTP" = wget ] && echo "Its wget may not support modern HTTPS (BusyBox wget needs ssl_client); installing curl fixes it."
    echo "Also check the code is right and was made in the last two hours: https://benchmark.frabs.net"
    exit 1
  fi
  has dd || { echo "This benchmark needs dd, which every Linux has; it isn't on this one."; exit 1; }
  HASH=
  for h in sha256sum sha1sum md5sum cksum; do has $h && { HASH=$h; break; }; done
  [ -z "$HASH" ] && has gzip && HASH="gzip -1"

  # One folder for everything, on a real disk where possible (/tmp is often memory).
  WORK=
  for base in /var/tmp "$HOME" "${TMPDIR:-/tmp}" /tmp; do
    [ -n "$base" ] && [ -d "$base" ] && [ -w "$base" ] || continue
    WORK="$base/frabs-benchmark.$$"; mkdir "$WORK" 2>/dev/null && break; WORK=
  done
  [ -n "$WORK" ] || { echo "Couldn't make a temporary folder."; exit 1; }
  trap 'rm -rf "$WORK"' EXIT
  trap 'echo; echo "Stopped. Everything this benchmark made has been removed."; rm -rf "$WORK"; exit 130' INT TERM

  echo
  echo "  Frabs Benchmark · https://benchmark.frabs.net/$CODE"
  echo "  Nothing is installed. Everything it makes is removed at the end."
  echo
  post '{"state":"start","platform":"linux"}'

  # ---- the machine
  step system running "Reading the system"
  os=Linux; [ -r /etc/os-release ] && os=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}")
  cpu=$(grep -m1 -E '^(model name|Model|Hardware|cpu model)' /proc/cpuinfo 2>/dev/null | sed 's/^[^:]*:[[:space:]]*//')
  [ -z "$cpu" ] && has lscpu && cpu=$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -1)
  [ -z "$cpu" ] && cpu="$(uname -m) processor"
  cores=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null)
  [ "${cores:-0}" -ge 1 ] 2>/dev/null || cores=1
  ram=$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null); ram=$(( ${ram:-0} / 1024 ))
  set -- $(df -Pk "$WORK" 2>/dev/null | tail -1); disk=$(( ${2:-0} / 1024 )); free=$(( ${4:-0} / 1024 ))
  virt=$(systemd-detect-virt 2>/dev/null)
  if [ -z "$virt" ] || [ "$virt" = none ]; then
    if [ -f /.dockerenv ]; then virt=docker
    elif [ -r /run/systemd/container ]; then virt=$(cat /run/systemd/container)
    elif grep -qa container=lxc /proc/1/environ 2>/dev/null; then virt=lxc
    elif grep -q '^flags.* hypervisor' /proc/cpuinfo 2>/dev/null; then virt="virtual machine"
    else virt=none; fi
  fi
  post "{\"system\":{\"os\":$(json "$os"),\"kernel\":$(json "$(uname -r)"),\"arch\":$(json "$(uname -m)"),\"cpu\":$(json "$cpu"),\"cores\":$cores,\"ram_mb\":$ram,\"disk_mb\":$disk,\"disk_free_mb\":$free,\"virtualisation\":$(json "$virt")}}"
  step system done "Reading the system" "$cpu, $cores cores"

  # ---- CPU: hashing the same data on every machine (SHA-256 where the server has it)
  if [ -z "$HASH" ]; then
    step cpu_single skipped "no hashing tool on this server"; step cpu_multi skipped "no hashing tool on this server"
  else
    step cpu_single running "CPU, single core"
    t=$(ms); hash_mb 128; took=$(since $t)
    n=$(( 128 * 5000 / took )); [ $n -lt 128 ] && n=128; [ $n -gt 16384 ] && n=16384   # about five seconds of work
    t=$(ms); hash_mb $n; took=$(since $t)
    single=$(( n * 10000 / took ))
    result "\"cpu_single_mbs\":$(dec $single),\"cpu_method\":$(json "${HASH%% *}")"
    step cpu_single done "CPU, single core" "$(dec $single) MB/s"

    step cpu_multi running "CPU, all $cores cores"
    t=$(ms); i=0; while [ $i -lt $cores ]; do hash_mb $n & i=$((i + 1)); done; wait; took=$(since $t)
    multi=$(( n * cores * 10000 / took ))
    result "\"cpu_multi_mbs\":$(dec $multi)"
    step cpu_multi done "CPU, all $cores cores" "$(dec $multi) MB/s"
  fi

  # ---- memory: streaming through RAM
  step memory running "Memory speed"
  t=$(ms); dd if=/dev/zero of=/dev/null bs=1048576 count=8192 2>/dev/null; took=$(since $t)
  mem=$(( 8192 * 10000 / took ))
  result "\"memory_mbs\":$(dec $mem)"
  step memory done "Memory speed" "$(dec $mem) MB/s"

  # ---- disk: a test file sized to the free space (at most 1 GB, and a tenth of what's free)
  size=$(( free / 10 )); [ $size -gt 1024 ] && size=1024
  f="$WORK/test.bin"
  if [ $size -lt 32 ]; then
    for k in disk_write disk_read disk_iops; do step $k skipped "less than 320 MB free"; done
    result '"disk_note":"not enough free disk space"'
  else
    step disk_write running "Disk write, $size MB"
    t=$(ms)
    dd if=/dev/zero of="$f" bs=1048576 count=$size oflag=direct 2>/dev/null || dd if=/dev/zero of="$f" bs=1048576 count=$size 2>/dev/null
    sync; took=$(since $t)
    w=$(( size * 10000 / took ))
    result "\"disk_write_mbs\":$(dec $w)"
    step disk_write done "Disk write" "$(dec $w) MB/s"

    step disk_read running "Disk read, $size MB"
    how=direct; t=$(ms)
    dd if="$f" of=/dev/null bs=1048576 iflag=direct 2>/dev/null || { how=cached; dd if="$f" of=/dev/null bs=1048576 2>/dev/null; }
    took=$(since $t)
    r=$(( size * 10000 / took ))
    result "\"disk_read_mbs\":$(dec $r),\"disk_read_how\":\"$how\""
    step disk_read done "Disk read" "$(dec $r) MB/s"
    rm -f "$f"

    step disk_iops running "Disk 4K writes"
    t=$(ms)
    dd if=/dev/zero of="$WORK/4k.bin" bs=4096 count=8192 oflag=direct 2>/dev/null || { dd if=/dev/zero of="$WORK/4k.bin" bs=4096 count=8192 2>/dev/null; sync; }
    took=$(since $t)
    iops=$(( 8192 * 1000 / took ))
    rm -f "$WORK/4k.bin"
    result "\"disk_iops\":$iops"
    step disk_iops done "Disk 4K writes" "$iops IOPS"
  fi

  # ---- network: up to 8 seconds from each of five big public test files
  step network running "Network download"
  dl=; lat=; best=0
  while IFS='|' read -r name url; do
    [ -n "$name" ] || continue
    post "{\"step\":\"network\",\"state\":\"running\",\"detail\":$(json "Downloading from $name")}"
    printf '\n    %-30s ' "$name"
    t=$(ms); bytes=$(fetch_for 8 "$url" | tr -d ' '); took=$(since $t)
    mbit=$(( ${bytes:-0} * 8 * 10 / took / 1000 ))   # Mbit/s times ten
    # Connection time: the TCP connect with curl; with wget, one whole small request.
    if [ "$HTTP" = curl ]; then
      c=$(curl -s -o /dev/null -m 5 -r 0-0 -w '%{time_connect}' "$url" </dev/null 2>/dev/null); c=${c:-0}
      frac=$(printf '%s' "${c#*.}000" | cut -c1-3 | sed 's/^0*//'); cms=$(( ${c%.*} * 1000 + ${frac:-0} ))
    else t=$(ms); wget -q -T 5 --spider "$url" </dev/null >/dev/null 2>&1; cms=$(since $t); fi
    printf '%s Mbit/s, %s ms' "$(dec $mbit)" "$cms"
    dl="$dl{\"name\":$(json "$name"),\"value\":$(dec $mbit),\"unit\":\"Mbit/s\"},"
    lat="$lat{\"name\":$(json "$name"),\"value\":$cms,\"unit\":\"ms\"},"
    [ $mbit -gt $best ] && best=$mbit
  done <<'SITES'
Cloudflare (nearest)|https://speed.cloudflare.com/__down?bytes=50000000
Clouvider, London|https://lon.speedtest.clouvider.net/1g.bin
Hetzner, Germany|https://fsn1-speed.hetzner.com/1GB.bin
OVH, France|https://proof.ovh.net/files/1Gb.dat
Hetzner, US East|https://ash-speed.hetzner.com/1GB.bin
SITES
  echo
  result "\"net_download\":[${dl%,}],\"net_best_mbit\":$(dec $best)"
  step network done "Network download" "best $(dec $best) Mbit/s"

  step upload running "Network upload"
  dd if=/dev/zero of="$WORK/up.bin" bs=1048576 count=25 2>/dev/null
  t=$(ms)
  if [ "$HTTP" = curl ]; then curl -s -o /dev/null -m 30 --data-binary @"$WORK/up.bin" -H 'content-type: application/octet-stream' https://speed.cloudflare.com/__up </dev/null 2>/dev/null; ok=$?
  else wget -q -T 30 -O /dev/null --header='content-type: application/octet-stream' --post-file="$WORK/up.bin" https://speed.cloudflare.com/__up </dev/null >/dev/null 2>&1; ok=$?; fi
  took=$(since $t)
  rm -f "$WORK/up.bin"
  if [ $ok -eq 0 ]; then
    up=$(( 25 * 1048576 * 8 / took / 100 ))   # Mbit/s times ten: bits / ms / 1000 * 10
    result "\"net_upload_mbit\":$(dec $up)"; step upload done "Network upload" "$(dec $up) Mbit/s"
  else
    result '"upload_note":"the upload test did not finish"'; step upload skipped "the upload test did not finish"
  fi

  step latency running "Network latency"
  result "\"latency\":[${lat%,}]"
  step latency done "Network latency" ""

  # ---- leave nothing behind
  step cleanup running "Removing everything it made"
  rm -rf "$WORK"
  step cleanup done "Removing everything it made" ""
  post '{"state":"finished"}'
  echo
  echo "  Done. Your results: https://benchmark.frabs.net/$CODE"
  echo
}

# Everything above is only definitions; the run starts here, once the whole script has arrived.
main "$@"
