#!/usr/bin/env bash
# git-cp.sh [--hardlinks] [-j JOBS] FROM TO
#
# Local copy of a clone with its submodules that ends up like a fresh clone of FROM's origin
# (git clone --recursive, or git-clone.sh: shallow, sparse and partial clones stay so), with Git
# LFS objects and without downloading anything but commits missing in FROM. Objects are cloned
# copy-on-write where the filesystem supports it (APFS, btrfs, XFS), otherwise copied;
# --hardlinks hardlinks them to FROM instead of copying. Needs git-checkout.sh next to it.
#   -j JOBS  repositories copied in parallel (default: 16)

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

# MODE SRC DST: copy a file or a directory tree (DST must not exist)
copy_tree() {
  case $1 in
    cow) if [[ $OSTYPE == darwin* ]]; then cp -Rc -- "$2" "$3"; else cp -R --reflink=always -- "$2" "$3"; fi ;;
    # cp -l of macOS fails on some versions, pax makes the same hardlinks
    link) if [[ $OSTYPE == darwin* ]]; then mkdir -- "$3" && (cd -- "$2" && pax -rwl . "$3"); else cp -Rl -- "$2" "$3"; fi ;;
    copy) cp -R -- "$2" "$3" ;;
  esac
}

# SRC DST URL: make DST a repository with SRC's objects, LFS objects, origin refs and the settings
# a clone would have (shallow, sparse checkout, partial clone)
cp_repo() {
  local src=$1 dst=$2 sgd kv
  local -a fmt f
  sgd=$(git -C "$src" rev-parse --path-format=absolute --git-common-dir)
  if [[ -s $sgd/objects/info/alternates ]]; then echo "$src uses objects/info/alternates, not supported" >&2; return 1; fi
  mapfile -t fmt < <(git -C "$src" rev-parse --show-ref-format --show-object-format)
  git init -q --ref-format="${fmt[0]}" --object-format="${fmt[1]}" -- "$dst"
  rm -rf -- "$dst/.git/objects"
  copy_tree "$MODE" "$sgd/objects" "$dst/.git/objects"
  if [[ -d $sgd/lfs/objects ]]; then
    mkdir -p -- "$dst/.git/lfs"
    copy_tree "$MODE" "$sgd/lfs/objects" "$dst/.git/lfs/objects"
  fi
  for kv in shallow info/sparse-checkout config.worktree; do
    if [[ -f $sgd/$kv ]]; then cp -- "$sgd/$kv" "$dst/.git/$kv"; fi
  done
  git -C "$dst" config set remote.origin.url "$3"
  while IFS= read -r -d '' kv; do
    if [[ $kv == remote.origin.fetch$'\n'* ]]; then f=(--append); else f=(); fi
    git -C "$dst" config set "${f[@]}" "${kv%%$'\n'*}" "${kv#*$'\n'}"
  done < <(git -C "$src" config -z --local --get-regexp '^(remote\.origin\.(fetch|promisor|partialclonefilter)|core\.(repositoryformatversion|sparsecheckout|sparsecheckoutcone)|index\.sparse|extensions\.(partialclone|worktreeconfig)|gitclone\.profile)$' || true)
  git -C "$src" for-each-ref --format='%(if)%(symref)%(then)%(else)create %(refname) %(objectname)%(end)' refs/remotes/origin/ refs/tags/ |
    sed '/^$/d' | git -C "$dst" -c core.logAllRefUpdates=false update-ref --stdin
  git -C "$dst" pack-refs --all
}

# Worker: copy submodule PATH of REPO in TO from FROM and check out SHA (download it when FROM
# lacks that commit); with an empty PATH copy the top repository and check out its default branch
cp_worker() {
  local dst=$1${2:+/$2} sha=$3 url=$5 src def
  src=$SRC${dst#"$DST"}
  if [[ -z $2 ]]; then
    cp_repo "$SRC" "$DST" "$url"
    def=$(git -C "$SRC" symbolic-ref -q --short refs/remotes/origin/HEAD || git -C "$SRC" symbolic-ref -q --short HEAD) || def=''
    def=${def#origin/}
    if [[ -n $def ]] && git -C "$DST" show-ref -q --verify "refs/remotes/origin/$def"; then
      git -C "$DST" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$def"
      git -C "$DST" branch -q --track "$def" "refs/remotes/origin/$def"
      git -C "$DST" checkout -q -f "$def" --
      echo "copied, on $def" >&3
    else
      git -C "$DST" checkout -q -f --detach "$(git -C "$SRC" rev-parse HEAD)"
      echo "copied, detached at FROM's HEAD: its default branch is unknown" >&3
    fi
  elif [[ $(git -C "$src" rev-parse --show-toplevel 2>/dev/null) == "$src" ]] &&
       GIT_NO_LAZY_FETCH=1 git -C "$src" cat-file -e "$sha^{commit}" 2>/dev/null; then
    cp_repo "$src" "$dst" "$url"
    git -C "$dst" checkout -q -f --detach "$sha"
    echo copied >&3
  else
    sub_sync "$@"
  fi
}

link=0
while (( $# )); do
  case $1 in
    --hardlinks) link=1; shift ;;
    -j) JOBS=$2; shift 2 ;;
    -h|--help) sed -n '2,9s/^# \{0,1\}//p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) break ;;
  esac
done
if (( $# != 2 )); then echo "usage: ${0##*/} [--hardlinks] [-j JOBS] FROM TO" >&2; exit 2; fi
if [[ ! $JOBS =~ ^[1-9][0-9]*$ ]]; then die "-j needs a positive number"; fi
SRC=$(realpath -- "$1")
if [[ $(git -C "$SRC" rev-parse --show-toplevel 2>/dev/null) != "$SRC" ]]; then die "not the top of a git working tree: $1"; fi
if [[ -e $2 ]]; then die "destination already exists: $2"; fi
url=$(git -C "$SRC" config get remote.origin.url) || die "$1 has no 'origin' remote"
PROFILE=$(git -C "$SRC" config get gitclone.profile || true)
t0=${EPOCHREALTIME/[.,]/}

# total for the progress line: objects of every repository in FROM
mapfile -t gds < <(git -C "$SRC" rev-parse --path-format=absolute --git-common-dir
                   git -C "$SRC" submodule --quiet foreach --recursive 'git rev-parse --path-format=absolute --git-common-dir')
dirs=()
for d in "${gds[@]}"; do dirs+=("$d/objects" "$d/lfs/objects"); done
kib "${dirs[@]}"; TOTAL_KIB=$REPLY

mkdir -p -- "$2"
DST=$(realpath -- "$2") TOP=$DST
# cp -c of macOS silently copies what it can't clone, e.g. to another volume
if [[ $OSTYPE == darwin* && $(stat -f %d -- "${gds[0]}") != "$(stat -f %d -- "$DST")" ]]; then MODE='copy'
elif copy_tree cow "${gds[0]}/HEAD" "$DST/.git-cp-probe" 2>/dev/null; then MODE='cow'
elif (( link )) && ln -- "${gds[0]}/HEAD" "$DST/.git-cp-probe" 2>/dev/null; then MODE='link'
else MODE='copy'; fi
rm -f -- "$DST/.git-cp-probe"
hsize "$TOTAL_KIB"
echo "${0##*/}: ${#gds[@]} repositories, $REPLY of objects, mode: $MODE" >&2

walk "$DST" cp_worker "$url"
if (( WALK_NEW )) && [[ -f $DST/.gitmodules ]] && ! out=$(git -C "$DST" submodule --quiet absorbgitdirs 2>&1); then
  printf '%s\n' "$out" >&2; exit 1
fi
hsize "$TOTAL_KIB"
case $MODE in
  copy) note="objects ($REPLY) copied" ;;
  link) note="objects ($REPLY) are hardlinks to FROM and take no extra space" ;;
  cow) note="objects ($REPLY) are copy-on-write clones sharing disk blocks with FROM" ;;
esac
kib "$DST"; hsize "$REPLY"; size=$REPLY
htime $(( (${EPOCHREALTIME/[.,]/} - t0) / 1000000 ))
echo "${0##*/}: done in $REPLY; $DST: $size, $note" >&2
(( ! WALK_FAILED ))
