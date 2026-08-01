#!/bin/sh

set -eu

input=$1
output=$2
work_dir=$(mktemp -d "/tmp/bobrvm-archive.XXXXXX")

cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

(
    cd "$work_dir"
    /usr/bin/ar -x "$input"
)

chmod u+r "$work_dir"/*.o
mkdir -p "$(dirname "$output")"
xcrun libtool -static -o "$output" "$work_dir"/*.o
