#!/usr/bin/env bash
# Extract the Bitrate value from [SUM] lines in an iperf3 text log.
set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [-n] [-d sender|receiver] [FILE...]

  -n            print only the numeric bitrate (strip the unit)
  -d DIRECTION  keep only "sender" or "receiver" rows (default: all)
  FILE...       one or more iperf3 log files (default: stdin)
EOF
    exit 1
}

numeric_only=0
direction=""

while getopts ":nd:h" opt; do
    case "$opt" in
        n) numeric_only=1 ;;
        d) direction="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

awk -v dir="$direction" -v numonly="$numeric_only" '
/\[SUM\]/ {
    if (dir != "" && $NF != dir) next
    if (numonly == 1) {
        print $6
    } else {
        print $6, $7
    }
}
' "$@"
