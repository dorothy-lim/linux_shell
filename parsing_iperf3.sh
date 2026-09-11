#!/usr/bin/env bash
# Extract the numeric Bitrate value (no unit) from [SUM] lines in an iperf3 text log.
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [-d sender|receiver] [FILE...]

  -d DIRECTION  keep only "sender" or "receiver" rows (default: all)
  FILE...       one or more iperf3 log files (default: stdin)
EOF
    exit 1
}

direction=""

while getopts ":d:h" opt; do
    case "$opt" in
        d) direction="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

awk -v dir="$direction" '
/\[SUM\]/ {
    if (dir != "" && $NF != dir) next
    print $6
}
' "$@"
