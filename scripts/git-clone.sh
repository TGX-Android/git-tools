#!/usr/bin/env bash
# git-clone.sh [--tgx] [-b BRANCH | -r COMMIT] [-j JOBS] URL [DIR]
#
# Minimal clone: one commit of the repository and of each submodule (recursively, in parallel).
# Needs git-checkout.sh next to it, which later moves the clone to other commits the same way.
#   --tgx      Telegram X: leave out what its build doesn't use (all of rtc_third_party but the
#              few libraries webrtc includes, rtc_base, test data of androidx-media and openh264,
#              tests of OpenSSL, crc32c and leveldb)
#   -b BRANCH  branch or tag (default: the remote HEAD)
#   -r COMMIT  exactly this commit (full id), detached like git checkout COMMIT
#   -j JOBS    submodules fetched in parallel (default: 16)

# Copyright © 2026 (tgx-android@pm.me)
# Distributed under the Boost Software License, Version 1.0, see LICENSE or
# https://www.boost.org/LICENSE_1_0.txt

case $OSTYPE in
  msys*|cygwin*) echo "${0##*/}: Windows is not supported by this script" >&2; exit 1 ;;
esac

# refuse versions older than the ones these scripts were tested with: bash 5.2.21, git 2.49.0
if (( BASH_VERSINFO[0] * 10000 + BASH_VERSINFO[1] * 100 + BASH_VERSINFO[2] < 50221 )); then
  echo "${0##*/}: needs bash 5.2.21 or newer, this is $BASH_VERSION" >&2; exit 1
fi
v=$(git version 2>/dev/null); v=${v#git version }
IFS=. read -r v1 v2 v3 <<< "$v"; v3=${v3%%[!0-9]*}
if (( v1 * 10000 + v2 * 100 + ${v3:-0} < 24900 )); then
  echo "${0##*/}: needs git 2.49.0 or newer, this is ${v:-none}" >&2; exit 1
fi
# shellcheck source=git-checkout.sh
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/git-checkout.sh"

args=(-q --depth 1 --no-tags) jobs=()
while (( $# )); do
  case $1 in
    --tgx) args+=(-c gitclone.profile=tgx); shift ;;   # read by git-checkout.sh
    -b) args+=(-b "$2"); shift 2 ;;
    -r) args+=(--revision "$2"); shift 2 ;;
    -j) jobs=(-j "$2"); shift 2 ;;
    -h|--help) sed -n '2,11s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) break ;;
  esac
done
if (( $# < 1 || $# > 2 )); then echo "usage: ${0##*/} [--tgx] [-b BRANCH | -r COMMIT] [-j JOBS] URL [DIR]" >&2; exit 2; fi
url=$1 dir=${2:-$(basename "${url%/}" .git)}
if (( TTY )); then args+=(--progress); fi

t0=${EPOCHREALTIME/[.,]/}
git clone "${args[@]}" -- "$url" "$dir"
main -C "$dir" "${jobs[@]}"
kib "$dir"; hsize "$REPLY"; size=$REPLY
kib "$dir/.git"; hsize "$REPLY"; gsize=$REPLY
htime $(( (${EPOCHREALTIME/[.,]/} - t0) / 1000000 ))
echo "${0##*/}: $dir in $REPLY, $size on disk ($gsize of it in .git)" >&2
(( ! WALK_FAILED ))
