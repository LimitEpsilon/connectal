#!/usr/bin/env bash

# Repeated FPGA measurements for the T=4, W=8 and T=4, W=16 builds.
# Run this script from any directory; paths are resolved relative to the script.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

repetitions=5
output_dir=""
skip_build=0
timeout_seconds=300
max_attempts=3

usage() {
  cat <<'EOF'
Usage: ./benchmark.sh [OPTIONS]

Runs vecadd, sgemm, mstress, and madmax on both vcu108-w8 and
vcu108-w16. Each invocation is retained as a separate raw log. Results are
written to results.csv and summary.txt under OUTPUT_DIR.

Options:
  -n, --repetitions N  repetitions per benchmark/configuration (default: 5)
  -o, --output DIR     result directory (default: fpga-results-<timestamp>)
      --timeout SEC    timeout for one FPGA invocation (default: 300)
      --max-attempts N maximum attempts for one measured run (default: 3)
      --skip-build     use existing benchmark host binaries
  -h, --help           show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--repetitions)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }
      repetitions="$2"
      shift 2
      ;;
    -o|--output)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }
      output_dir="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }
      timeout_seconds="$2"
      shift 2
      ;;
    --max-attempts)
      [[ $# -ge 2 ]] || { echo "missing value for $1" >&2; exit 2; }
      max_attempts="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$repetitions" =~ ^[1-9][0-9]*$ ]] || {
  echo "repetitions must be a positive integer" >&2
  exit 2
}
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo "timeout must be a positive integer" >&2
  exit 2
}
[[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || {
  echo "max-attempts must be a positive integer" >&2
  exit 2
}

if [[ -z "$output_dir" ]]; then
  output_dir="fpga-results-$(date -u +%Y%m%dT%H%M%SZ)"
elif [[ "$output_dir" != /* ]]; then
  output_dir="$script_dir/$output_dir"
fi

if [[ -e "$output_dir" ]]; then
  echo "refusing to overwrite existing output directory: $output_dir" >&2
  exit 2
fi
mkdir -p "$output_dir/raw"

readonly threads=4
readonly -a benchmarks=(vecadd sgemm mstress madmax)

command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required to summarize the measurements" >&2
  exit 2
}
command -v timeout >/dev/null 2>&1 || {
  echo "GNU timeout is required to bound FPGA invocations" >&2
  exit 2
}
command -v unlink >/dev/null 2>&1 || {
  echo "unlink is required to clean stale vx_socket files" >&2
  exit 2
}

cleanup_vx_sockets() {
  local socket_path
  for socket_path in "$script_dir/vx_socket.server" "$script_dir/vx_socket.client"; do
    if [[ -e "$socket_path" || -L "$socket_path" ]]; then
      unlink -- "$socket_path" || {
        echo "failed to remove stale socket: $socket_path" >&2
        return 1
      }
    fi
  done
}

trap 'cleanup_vx_sockets || true; exit 130' INT TERM

for warps in 8 16; do
  build="vcu108-w${warps}/bin/ubuntu.exe"
  [[ -x "$build" ]] || {
    echo "missing FPGA executable: $script_dir/$build" >&2
    exit 2
  }
done

for benchmark in "${benchmarks[@]}"; do
  [[ -f "kernels/${benchmark}.elf" ]] || {
    echo "missing kernel: $script_dir/kernels/${benchmark}.elf" >&2
    exit 2
  }
done

if (( ! skip_build )); then
  make -C benchmarks vecadd sgemm madmax mstress-w8 mstress-w16
fi

for host in benchmarks/vecadd benchmarks/sgemm benchmarks/madmax \
            benchmarks/mstress-w8 benchmarks/mstress-w16; do
  [[ -x "$host" ]] || {
    echo "missing host benchmark: $script_dir/$host" >&2
    exit 2
  }
done

metadata="$output_dir/metadata.txt"
{
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname)"
  echo "kernel=$(uname -srmo)"
  echo "repetitions=$repetitions"
  echo "timeout_seconds=$timeout_seconds"
  echo "max_attempts=$max_attempts"
  echo "threads=$threads"
  echo "mstress_count_per_thread=64"
  echo "mstress_w8_points=2048"
  echo "mstress_w16_points=4096"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "git_commit=$(git rev-parse HEAD)"
    if git diff --quiet -- . && git diff --cached --quiet -- .; then
      echo "git_tracked_files_dirty=no"
    else
      echo "git_tracked_files_dirty=yes"
    fi
  fi
  if command -v bsc >/dev/null 2>&1; then
    echo "bsc_version_begin"
    bsc -version 2>&1 || true
    echo "bsc_version_end"
  fi
  echo "sha256_begin"
  sha256sum \
    vcu108-w8/bin/ubuntu.exe \
    vcu108-w16/bin/ubuntu.exe \
    benchmarks/vecadd benchmarks/sgemm benchmarks/madmax \
    benchmarks/mstress-w8 benchmarks/mstress-w16 \
    kernels/vecadd.elf kernels/sgemm.elf \
    kernels/mstress.elf kernels/madmax.elf \
    benchmarks/mstress.cpp benchmarks/Makefile benchmark.sh
  echo "sha256_end"
} > "$metadata"

csv="$output_dir/results.csv"
printf '%s\n' \
  'timestamp_utc,warps,threads,benchmark,repetition,attempts,cycles,instructions,ipc,status,raw_log' \
  > "$csv"

attempts_csv="$output_dir/attempts.csv"
printf '%s\n' \
  'timestamp_utc,warps,threads,benchmark,repetition,attempt,command_status,outcome,raw_log' \
  > "$attempts_csv"

run_one() {
  local warps="$1"
  local benchmark="$2"
  local repetition="$3"
  local build="vcu108-w${warps}"
  local host="benchmarks/${benchmark}"
  local raw_prefix="raw/w${warps}-${benchmark}-r$(printf '%02d' "$repetition")"
  local raw_rel raw timestamp cycles instructions ipc expected_points
  local command_status result_line outcome attempt
  local -a command

  if [[ "$benchmark" == mstress ]]; then
    host="benchmarks/mstress-w${warps}"
  fi
  command=("./${build}/bin/ubuntu.exe" "$host" "kernels/${benchmark}.elf")

  for ((attempt = 1; attempt <= max_attempts; ++attempt)); do
    raw_rel="${raw_prefix}-a$(printf '%02d' "$attempt").log"
    raw="$output_dir/$raw_rel"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # This also removes sockets left behind by an interrupted manual run before
    # the first measured attempt.
    cleanup_vx_sockets

    echo
    echo "[$timestamp] W=$warps T=$threads benchmark=$benchmark repetition=$repetition/$repetitions attempt=$attempt/$max_attempts"
    {
      echo "# timestamp_utc=$timestamp"
      echo "# warps=$warps threads=$threads benchmark=$benchmark repetition=$repetition attempt=$attempt"
      printf '# command:'
      printf ' %q' "${command[@]}"
      printf '\n'
    } | tee "$raw"

    set +e
    timeout --signal=TERM --kill-after=10s "${timeout_seconds}s" \
      "${command[@]}" 2>&1 | tee -a "$raw"
    command_status=${PIPESTATUS[0]}
    set -e

    if grep -q 'FAILED' "$raw"; then
      outcome="BENCHMARK_FAILED"
      printf '%s,%d,%d,%s,%d,%d,%d,%s,%s\n' \
        "$timestamp" "$warps" "$threads" "$benchmark" "$repetition" \
        "$attempt" "$command_status" "$outcome" "$raw_rel" >> "$attempts_csv"
      cleanup_vx_sockets
      echo "benchmark or validation reported FAILED; refusing to retry: $raw" >&2
      return 1
    elif (( command_status == 124 )); then
      outcome="TIMEOUT"
    elif (( command_status == 139 )) || grep -Eqi 'segmentation fault|segfault' "$raw"; then
      outcome="SEGFAULT"
    elif (( command_status != 0 )); then
      outcome="COMMAND_ERROR"
    else
      result_line="$(
        awk '/Cycles:[[:space:]]*[0-9]+[[:space:]]+Instructions:[[:space:]]*[0-9]+[[:space:]]+PASSED/ {
               for (i = 1; i <= NF; ++i) {
                 if ($i == "Cycles:") cycles = $(i + 1)
                 if ($i == "Instructions:") instructions = $(i + 1)
               }
             }
             END { if (cycles != "" && instructions != "") print cycles, instructions }' "$raw"
      )"
      if [[ -z "$result_line" ]]; then
        outcome="INCOMPLETE"
      elif ! awk 'BEGIN { found = 0 } /^PASSED!\r?$/ { found++ } END { exit(found == 1 ? 0 : 1) }' "$raw"; then
        outcome="INCOMPLETE"
      else
        read -r cycles instructions <<< "$result_line"
        if [[ "$benchmark" == mstress ]]; then
          expected_points=$((64 * warps * threads))
          if ! grep -q "^number of points: ${expected_points}$" "$raw"; then
            outcome="WORKLOAD_MISMATCH"
          else
            outcome="PASSED"
          fi
        else
          outcome="PASSED"
        fi
      fi
    fi

    printf '%s,%d,%d,%s,%d,%d,%d,%s,%s\n' \
      "$timestamp" "$warps" "$threads" "$benchmark" "$repetition" \
      "$attempt" "$command_status" "$outcome" "$raw_rel" >> "$attempts_csv"

    if [[ "$outcome" == PASSED ]]; then
      ipc="$(awk -v i="$instructions" -v c="$cycles" 'BEGIN { printf "%.6f", i / c }')"
      printf '%s,%d,%d,%s,%d,%d,%s,%s,%s,PASSED,%s\n' \
        "$timestamp" "$warps" "$threads" "$benchmark" "$repetition" \
        "$attempt" "$cycles" "$instructions" "$ipc" "$raw_rel" >> "$csv"
      return 0
    fi

    cleanup_vx_sockets
    if [[ "$outcome" == WORKLOAD_MISMATCH ]]; then
      echo "mstress workload mismatch; refusing to retry: $raw" >&2
      return 1
    fi
    if (( attempt == max_attempts )); then
      echo "run failed after $max_attempts attempts ($outcome); last raw log: $raw" >&2
      return 1
    fi
    echo "transient FPGA failure ($outcome); sockets cleaned; retrying" >&2
    sleep 2
  done
}

# Pair the two configurations for each benchmark. Alternate their order between
# repetitions to avoid confounding W with slow drift in board or host state.
# Each invocation reloads its FPGA executable, and every measured run is
# retained; no warm-up run is discarded.
for ((repetition = 1; repetition <= repetitions; ++repetition)); do
  if (( repetition % 2 == 1 )); then
    warp_order=(8 16)
  else
    warp_order=(16 8)
  fi
  for benchmark in "${benchmarks[@]}"; do
    for warps in "${warp_order[@]}"; do
      run_one "$warps" "$benchmark" "$repetition"
    done
  done
done

summary="$output_dir/summary.txt"
python3 - "$csv" > "$summary" <<'PY'
import csv
import statistics
import sys
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1], newline="")))
groups = defaultdict(list)
instruction_counts = defaultdict(set)
for row in rows:
    key = (int(row["warps"]), row["benchmark"])
    groups[key].append(int(row["cycles"]))
    instruction_counts[key].add(int(row["instructions"]))

print("W benchmark  n  instructions  cycles-min  cycles-median  cycles-max  median-ipc  range-percent")
benchmark_order = {"vecadd": 0, "sgemm": 1, "mstress": 2, "madmax": 3}
for key in sorted(groups, key=lambda key: (key[0], benchmark_order[key[1]])):
    values = groups[key]
    if len(instruction_counts[key]) != 1:
        raise SystemExit(f"instruction count changed within {key}: {sorted(instruction_counts[key])}")
    instructions = next(iter(instruction_counts[key]))
    median = statistics.median(values)
    median_ipc = instructions / median
    range_percent = 100.0 * (max(values) - min(values)) / median
    print(f"{key[0]:2d} {key[1]:8s} {len(values):2d} {instructions:13d} "
          f"{min(values):11d} {median:13.1f} {max(values):10d} "
          f"{median_ipc:10.4f} {range_percent:13.3f}")
PY

echo
cat "$summary"
echo
echo "Raw logs:  $output_dir/raw"
echo "CSV:       $csv"
echo "Attempts:  $attempts_csv"
echo "Summary:   $summary"
echo "Metadata:  $metadata"
