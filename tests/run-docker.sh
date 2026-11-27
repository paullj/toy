#!/usr/bin/env bash
# Run a Linux binary in a Docker (OrbStack) container: the one place the test runner
# (TOY_TEST_RUNNER=docker:<platform>) and scripts start one.
#
# usage: tests/run-docker.sh <platform> [-C <dir>] [-s <KiB>] [-e NAME=VALUE]... [-n <name>] [-S <file>] [--] <binary> [args...]
#   platform  linux/arm64 or linux/amd64
#   -C dir    the working directory (default: the binary's folder)
#   -s KiB    the stack limit
#   -e        a variable of the program's environment
#   -n name   the container's name, so a caller that gives up on the run can `docker kill` it
#   -S file   where to write how the program ended: 'exit N' or 'signal N'. Nothing is
#             written when the program never ran (docker or the exec failed).
# Stdin, stdout and stderr pass through. The script exits with the program's code, or
# 128 + the signal, as a shell reports it; docker's own failures exit 125-127. A program
# can exit with any of those codes too, so a caller that must tell them apart reads -S.
set -euo pipefail

usage() { echo "usage: $0 <platform> [-C <dir>] [-s <KiB>] [-e NAME=VALUE]... [-n <name>] [-S <file>] [--] <binary> [args...]" >&2; exit 125; }
[ $# -ge 2 ] || usage
platform=$1; shift
cwd=""
status=""
opts=()
while [ $# -gt 0 ]; do
  case $1 in
    -C) [ $# -ge 2 ] || usage; cwd=$2; shift 2 ;;
    -s) [ $# -ge 2 ] || usage; opts+=(--ulimit "stack=$(($2 * 1024))"); shift 2 ;;
    -e) [ $# -ge 2 ] || usage; opts+=(-e "$2"); shift 2 ;;
    -n) [ $# -ge 2 ] || usage; opts+=(--name "$2"); shift 2 ;;
    -S) [ $# -ge 2 ] || usage; status=$2; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || usage

# Folders are spelled as `cd` then `pwd` leaves them, so one folder named two ways
# ('d' and 'd/.') is still one mount.
canon() { (cd "$1" && pwd); }
bin=$(canon "$(dirname "$1")")/$(basename "$1"); shift
dir=$(dirname "$bin")
[ -n "$cwd" ] && cwd=$(canon "$cwd") || cwd=$dir
tmp=""
if [ -n "$status" ]; then
  status=$(canon "$(dirname "$status")")/$(basename "$status")
else
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  status=$tmp/status
fi
rm -f "$status"
# Only these folders are mounted, each at its host path: the binary's, the working
# directory and the status file's. A path argument elsewhere does not resolve.
mounted=()
for d in "$dir" "$cwd" "$(dirname "$status")"; do
  case " ${mounted[*]-} " in *" $d "*) ;; *) mounted+=("$d"); opts+=(-v "$d:$d") ;; esac
done

# The program's exit code alone cannot say how it ended: an exit 129 and a SIGHUP death
# look the same to docker's caller, and 125-127 are also docker's own failures. So a
# wrapper records the raw wait status. --init keeps the program off PID 1, which the
# kernel shields from signals it has no handler for, so a program that aborts dies as
# it would natively.
wrapper='my $status = shift; my $r = system { $ARGV[0] } @ARGV;
if ($r == -1) { print STDERR "$ARGV[0]: $!\n"; exit 127 }
open my $f, ">", $status or die "$status: $!";
print $f (($? & 127) ? "signal " . ($? & 127) : "exit " . ($? >> 8)), "\n";
close $f or die; exit 0'
set +e
docker run --rm -i --init --quiet --platform "$platform" "${opts[@]}" -w "$cwd" \
  debian:stable-slim /usr/bin/perl -e "$wrapper" "$status" "$bin" "$@"
rc=$?
set -e
read -r how n 2>/dev/null < "$status" || exit $(( rc == 0 ? 125 : rc ))
case $how in
  exit) exit "$n" ;;
  signal) exit $(( 128 + n )) ;;
esac
exit 125
