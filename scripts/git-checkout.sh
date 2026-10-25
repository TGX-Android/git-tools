#!/usr/bin/env bash
# git-checkout.sh [-f|--force] [-C DIR] [-j JOBS] [--gc] [REF]
#
# Moves the repository to REF and every submodule (recursively, in parallel) to the commit
# pinned there, downloading only those commits: one commit deep in shallow clones (the ones
# git-clone.sh makes), just the missing commits in full clones.
#   REF          local BRANCH as it is, REMOTE/BRANCH or BRANCH that is only on origin (fetched,
#                the local branch is reset to the remote one), tag or commit; without REF only the
#                submodules are synced to the current commit
#   -f, --force  discard local changes and untracked files in the repository and all submodules,
#                keeping ignored ones (build/, .gradle/, local.properties); without REF moves the
#                current branch to its upstream: the CI update before ./gradlew assemble...
#   -C DIR       repository to work in (default: current directory)
#   -j JOBS      submodules processed in parallel (default: 16)
#   --gc         drop objects of earlier checkouts right away (slow on big repositories)
#
# git-cp.sh sources this file for its submodule walker.

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
set -euo pipefail
shopt -s inherit_errexit

# settings for every git command below, including the ones git itself runs
n=${GIT_CONFIG_COUNT:-0}
for kv in advice.detachedHead=false checkout.workers=0 submodule.recurse=false fetch.recurseSubmodules=false; do
  export "GIT_CONFIG_KEY_$n=${kv%%=*}" "GIT_CONFIG_VALUE_$n=${kv#*=}"
  n=$(( n + 1 ))
done
export GIT_CONFIG_COUNT=$n

JOBS=16 FORCE=0 PRUNE=0 TOTAL_KIB=0 PROFILE='' TOP='' TTY=0 COLS=100
F=()   # -f for checkouts when --force
if [[ -t 2 ]]; then TTY=1 COLS=$(tput cols 2>/dev/null || echo 100); fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/git-sh.XXXXXX")
cleanup() {
  local -a pids
  mapfile -t pids < <(jobs -p)
  if (( ${#pids[@]} )); then   # workers lead process groups with their git processes
    kill -- "${pids[@]/#/-}" 2>/dev/null || true
    kill "${pids[@]}" 2>/dev/null || true
  fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Telegram X build (git-clone.sh --tgx): submodules it never uses, and the parts it uses of the
# heavy ones ("cone DIR..." keeps those top-level directories, anything else is a list of
# non-cone sparse-checkout patterns); paths are relative to the top repository
TGX_SKIP=(   # tests and benchmarks; tdlib/source/{td,openssl} themselves are read by app/build.gradle.kts
  'tdlib/source/openssl/*'
  'app/jni/tgvoip/third_party/crc32c/third_party/*'
  'vkryl/leveldb/jni/leveldb/third_party/*'
)
TGX_FIRST=(   # the biggest ones, started first
  'app/thirdparty/androidx-media/*' app/jni/tgvoip/third_party/webrtc_deps/third_party
  app/jni/tgvoip/third_party/webrtc app/jni/third_party/ffmpeg app/jni/tgvoip/third_party/openh264 tdlib
)
declare -A TGX_SPARSE=(
  [app/jni/tgvoip/third_party/webrtc_deps/third_party]='cone ffmpeg jni_zero libevent libsrtp libyuv openh264 opus pffft rnnoise'
  [app/jni/tgvoip/third_party/webrtc_deps/base]='cone'
  [app/jni/tgvoip/third_party/openh264]='/* !/res/'
  ['app/thirdparty/androidx-media/*']='/* !/libraries/test_data/'
)

die() { echo "${0##*/}: $*" >&2; exit 1; }

# KIB -> REPLY: "12.3 MiB"
hsize() {
  local -i x=$(( $1 * 10 )) i=0
  local -a u=(KiB MiB GiB TiB)
  while (( x >= 10240 && i < 3 )); do x=$(( (x + 512) / 1024 )); i+=1; done
  REPLY="$(( x / 10 )).$(( x % 10 )) ${u[i]}"
}

# SECONDS -> REPLY: "1:05"
htime() { printf -v REPLY '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# DIR... -> REPLY: their total size in KiB (missing ones count as 0)
kib() {
  local -i t=0 k
  local out='' _
  if (( $# )); then out=$(du -sk -- "$@" 2>/dev/null) || true; fi
  while read -r k _; do t+=$k; done <<< "$out"
  REPLY=$t
}

# REPO: queue REPO's submodules (the ones `git submodule update` would update)
walk_queue() {
  local repo=$1 kv key name path rec rest rel url
  local -a first=() later=() stale=()
  local -A name_of=() url_of=() none_of=() sha_of=()
  if [[ ! -f $repo/.gitmodules ]]; then return 0; fi
  if (( FORCE )); then git -C "$repo" submodule --quiet sync; fi
  git -C "$repo" submodule --quiet init
  while IFS= read -r -d '' kv; do   # .gitmodules: paths, and update = none decided by the repository
    key=${kv%%$'\n'*} name=${key#submodule.}
    case $key in
      *.path) name_of[${kv#*$'\n'}]=${name%.path} ;;
      *.update) if [[ ${kv#*$'\n'} == none ]]; then none_of[${name%.update}]=1; fi ;;
    esac
  done < <(git -C "$repo" config -z -f .gitmodules --get-regexp '^submodule\..*\.(path|update)$' || true)
  while IFS= read -r -d '' kv; do   # local config: URLs, and update = none set only locally (dropped)
    key=${kv%%$'\n'*} name=${key#submodule.}
    case $key in
      *.url) url_of[${name%.url}]=${kv#*$'\n'} ;;
      *.update) name=${name%.update}; if [[ ${kv#*$'\n'} == none && -z ${none_of[$name]-} ]]; then stale+=("$name"); fi ;;
    esac
  done < <(git -C "$repo" config -z --local --get-regexp '^submodule\..*\.(url|update)$' || true)
  for name in "${stale[@]}"; do git -C "$repo" config unset "submodule.$name.update"; done
  if (( ! ${#name_of[@]} )); then return 0; fi
  rel=${repo#"$TOP"}; rel=${rel#/}; rel=${rel:+$rel/}
  while IFS= read -r -d '' rec; do
    if [[ $rec != 160000\ * ]]; then continue; fi
    path=${rec#*$'\t'} rest=${rec#* }
    name=${name_of[$path]-}
    if [[ -z $name ]]; then continue; fi
    url=${url_of[$name]-}
    if [[ -z $url || -n ${none_of[$name]-} ]]; then continue; fi   # inactive, or not wanted by the repository
    # not downloaded for the profile; kept in sync once there (git submodule update --init PATH)
    if [[ $PROFILE == tgx && ! -e $repo/$path/.git ]] && matches "$rel$path" "${TGX_SKIP[@]}"; then continue; fi
    sha_of[$path]=${rest%% *}
    if [[ $PROFILE == tgx ]] && matches "$rel$path" "${TGX_FIRST[@]}"; then first+=("$path"); else later+=("$path"); fi
  done < <(git -C "$repo" --literal-pathspecs ls-files -s -z -- "${!name_of[@]}")
  for path in "${first[@]}" "${later[@]}"; do
    name=${name_of[$path]}
    t_repo+=("$repo") t_path+=("$path") t_sha+=("${sha_of[$path]}") t_name+=("$name") t_url+=("${url_of[$name]}")
  done
}

# STRING PATTERN...: does STRING match one of the glob patterns?
matches() {
  local p
  for p in "${@:2}"; do
    # shellcheck disable=SC2053 # glob patterns
    if [[ $1 == $p ]]; then return 0; fi
  done
  return 1
}

# Progress line: repositories, bytes on disk, speed, elapsed, percent and time left when the
# total (TOTAL_KIB) is known, and the repositories being worked on
draw() {
  local -i now kb dt el pct=0 left=0 i n=$(( ndone + nfail + ${#running[@]} + ${#t_repo[@]} - qh ))
  local line names='' size speed bar
  now=${EPOCHREALTIME/[.,]/}
  kib "${measure[@]}"; kb=$(( REPLY > base_kib ? REPLY - base_kib : 0 ))
  dt=$(( now - last_us ))
  if (( dt >= 200000 )); then
    rate=$(( (rate + (kb > last_kb ? (kb - last_kb) * 1000000 / dt : 0)) / 2 ))
    last_us=$now last_kb=$kb
  fi
  el=$(( (now - t0_us) / 1000000 ))
  hsize "$kb"; size=$REPLY
  hsize "$rate"; speed=$REPLY/s
  for i in "${!active[@]}"; do names+=${names:+, }${t_name[i]}; done
  if (( TOTAL_KIB )); then
    pct=$(( kb >= TOTAL_KIB ? 100 : kb * 100 / TOTAL_KIB ))
    if (( rate )); then left=$(( kb >= TOTAL_KIB ? 0 : (TOTAL_KIB - kb) / rate )); fi
    printf -v bar '%*s' $(( pct / 5 )) ''; bar=${bar// /█}
    printf -v line '%*s' $(( 20 - pct / 5 )) ''; bar+=${line// /░}
    hsize "$TOTAL_KIB"; size+=" / $REPLY"
    htime "$left"
    printf -v line '[%*d/%d] %s %3d%%  %s  %s  %s left  %s' ${#n} $(( ndone + nfail )) "$n" "$bar" "$pct" "$size" "$speed" "$REPLY" "$names"
  else
    htime "$el"
    printf -v line '[%*d/%d]  %s  %s  %s  %s' ${#n} $(( ndone + nfail )) "$n" "$size" "$speed" "$REPLY" "$names"
  fi
  printf '\r%s\e[K' "${line:0:COLS-1}" >&2
}

# walk TOP WORKER [URL]: runs "WORKER REPO PATH SHA NAME URL" in the background for every
# submodule of TOP (recursively, JOBS at a time; a repository's submodules are queued once its
# worker succeeds). With URL the first job is TOP itself (PATH and SHA empty).
# Sets WALK_DONE, WALK_FAILED, WALK_NEW (fresh repositories were made) and WALK_KIB.
walk() {
  local top=$1 worker=$2 pid sub res clr=
  local -i idx qh=0 rc timer=0 ndone=0 nfail=0 rate=0 last_kb=0 base_kib t0_us last_us el
  local -a t_repo=() t_path=() t_sha=() t_name=() t_url=() measure=() active=()
  local -A running=() started=()
  WALK_NEW=0
  if (( TTY )); then clr=$'\r\e[K'; fi
  if [[ -e $top/.git ]]; then measure=("$top/.git"); fi
  if [[ -n ${3-} ]]; then t_repo=("$top") t_path=("") t_sha=("") t_name=("${top##*/}") t_url=("$3")
  else walk_queue "$top"; fi
  kib "${measure[@]}"; base_kib=$REPLY
  t0_us=${EPOCHREALTIME/[.,]/} last_us=$t0_us
  while (( ${#t_repo[@]} > qh || ${#running[@]} )); do
    while (( ${#t_repo[@]} > qh && ${#running[@]} < JOBS )); do
      idx=$qh qh+=1
      sub=${t_repo[idx]}${t_path[idx]:+/${t_path[idx]}}
      if [[ ! -e $sub/.git ]]; then   # a new repository: count what goes into it
        if (( TOTAL_KIB )); then measure+=("$sub/.git/objects" "$sub/.git/lfs"); else measure+=("$sub/.git"); fi
        WALK_NEW=1
      fi
      set -m   # a process group of its own, so that an abort stops the git processes too
      ( export GIT_TERMINAL_PROMPT=0
        "$worker" "${t_repo[idx]}" "${t_path[idx]}" "${t_sha[idx]}" "${t_name[idx]}" "${t_url[idx]}"
      ) </dev/null >"$TMP/$idx.log" 2>&1 3>"$TMP/$idx.res" &
      set +m
      running[$!]=$idx started[$!]=${EPOCHREALTIME/[.,]/} active[idx]=1
    done
    if (( TTY && ! timer )); then sleep 0.5 & timer=$!; fi
    pid='' rc=0
    wait -n -p pid || rc=$?
    if [[ -z $pid ]]; then continue; fi
    if (( pid == timer )); then timer=0; draw; continue; fi
    if [[ -z ${running[$pid]-} ]]; then continue; fi   # a finished process substitution
    idx=${running[$pid]}
    unset "running[$pid]" "active[$idx]"
    el=$(( (${EPOCHREALTIME/[.,]/} - ${started[$pid]}) / 100000 ))
    res=''; read -r res < "$TMP/$idx.res" || true
    if (( rc )); then
      nfail+=1
      printf '%s[%d/%d] %s: FAILED\n' "$clr" $(( ndone + nfail )) $(( ndone + nfail + ${#running[@]} + ${#t_repo[@]} - qh )) "${t_name[idx]}" >&2
      sed 's/^/    /' "$TMP/$idx.log" | tail -n 20 >&2
    else
      ndone+=1
      walk_queue "${t_repo[idx]}${t_path[idx]:+/${t_path[idx]}}"
      if (( ! TTY )); then
        printf '[%d/%d] %s: %s (%d.%ds)\n' $(( ndone + nfail )) $(( ndone + nfail + ${#running[@]} + ${#t_repo[@]} - qh )) \
          "${t_name[idx]}" "${res:-ok}" $(( el / 10 )) $(( el % 10 )) >&2
      fi
    fi
    if (( TTY )); then draw; fi
  done
  if (( timer )); then kill "$timer" 2>/dev/null || true; wait "$timer" 2>/dev/null || true; fi
  if (( TTY )); then printf '\r\e[K' >&2; fi
  kib "${measure[@]}"
  WALK_KIB=$(( REPLY > base_kib ? REPLY - base_kib : 0 )) WALK_DONE=$ndone WALK_FAILED=$nfail
}

# REL: partial clone and sparse-checkout options of the profile for the submodule at REL -> opt+=
sparse_opts() {
  local key spec='' cone=true tpl
  local -a w
  if [[ $PROFILE != tgx ]]; then return 0; fi
  for key in "${!TGX_SPARSE[@]}"; do
    # shellcheck disable=SC2053 # glob patterns
    if [[ $1 == $key ]]; then spec=${TGX_SPARSE[$key]}; break; fi
  done
  if [[ -z $spec ]]; then return 0; fi
  read -ra w <<< "$spec"
  tpl=$(mktemp -d "$TMP/tpl.XXXXXX")
  mkdir "$tpl/info"
  if [[ ${w[0]} == cone ]]; then
    printf '/*\n!/*/\n' > "$tpl/info/sparse-checkout"
    if (( ${#w[@]} > 1 )); then printf '/%s/\n' "${w[@]:1}" >> "$tpl/info/sparse-checkout"; fi
  else
    cone=false
    printf '%s\n' "${w[@]}" > "$tpl/info/sparse-checkout"
  fi
  # the template puts the patterns in place before the checkout; blobs outside them never download
  opt+=(--template="$tpl" --filter=blob:none -c core.sparseCheckout=true -c "core.sparseCheckoutCone=$cone")
}

# REPO SHA: fetch that commit (one commit deep in a shallow repository)
fetch_commit() {
  local err
  local -a depth=()
  if [[ $(git -C "$1" rev-parse --is-shallow-repository) == true ]]; then depth=(--depth 1); fi
  if ! err=$(git -C "$1" fetch -q --no-tags "${depth[@]}" origin "$2" 2>&1); then
    if [[ $err != *unadvertised* ]]; then printf '%s\n' "$err" >&2; return 1; fi
    # an old server that refuses fetching by commit id: fetch the branches
    git -C "$1" fetch -q --no-tags origin '+refs/heads/*:refs/remotes/origin/*'
  fi
}

# REPO OLD NEW: like git checkout --recurse-submodules, remove the working trees of submodules that
# NEW no longer has, unless they have changes; their repositories stay in .git/modules
drop_removed() {
  local meta path sub out
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    sub=$1/$path
    if [[ $meta == :160000\ * && -f $sub/.git ]] &&
       out=$(git -C "$sub" status --porcelain --ignore-submodules=none 2>/dev/null) && [[ -z $out ]]; then
      rm -rf -- "$sub"
    fi
  done < <(git -C "$1" diff --raw -z --no-renames --diff-filter=D "$2" "$3" --)
}

# REPO: drop objects that only earlier checkouts used
prune() {
  git -C "$1" reflog expire --expire=now --all
  git -C "$1" gc -q --prune=now
  if [[ -d $(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/lfs ]]; then
    git -C "$1" lfs prune >/dev/null
  fi
}

# Worker: make submodule PATH of REPO a checkout of exactly SHA (NAME and URL from REPO's config)
sub_sync() {
  local repo=$1 path=$2 sha=$3 name=$4 url=$5 sub=$1/$2 head err rel
  local -a opt=(-q --no-tags)
  if [[ ! -e $sub/.git && -d $(git -C "$repo" rev-parse --path-format=absolute --git-path "modules/$name") ]]; then
    # deinitialized or deleted earlier: reattach the repository that is still there
    git -C "$repo" submodule --quiet update --init --no-fetch -- "$path" 2>/dev/null || true
  fi
  if [[ ! -e $sub/.git ]]; then
    rel=${repo#"$TOP"}; rel=${rel#/}
    sparse_opts "${rel:+$rel/}$path"
    if ! err=$(git clone "${opt[@]}" --depth 1 --revision="$sha" -- "$url" "$sub" 2>&1); then
      if [[ $err != *unadvertised* ]]; then printf '%s\n' "$err" >&2; return 1; fi
      git clone "${opt[@]}" --no-checkout -- "$url" "$sub"   # server refuses fetching by commit id
      git -C "$sub" checkout -q --detach "$sha"
    fi
    echo cloned >&3
    return 0
  fi
  head=$(git -C "$sub" rev-parse -q --verify HEAD) || head=
  if [[ $head != "$sha" ]]; then
    if ! GIT_NO_LAZY_FETCH=1 git -C "$sub" cat-file -e "$sha^{commit}" 2>/dev/null; then fetch_commit "$sub" "$sha"; fi
    git -C "$sub" checkout -q "${F[@]}" --detach "$sha"
    if [[ -n $head ]]; then drop_removed "$sub" "$head" "$sha"; fi
    echo "updated to ${sha:0:7}" >&3
  elif (( FORCE )); then
    git -C "$sub" checkout -q -f --detach "$sha"
  fi
  if (( FORCE )); then git -C "$sub" clean -ffdq; fi
  if (( PRUNE )); then prune "$sub"; fi
}

# Moves TOP to REF: a local branch as it is, a remote branch resets the local one to it
checkout_top() {
  local ref=$1 sha old
  old=$(git -C "$TOP" rev-parse -q --verify HEAD) || old=
  if [[ -z $ref ]]; then
    ref=$(git -C "$TOP" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) ||
      die "the current branch has no upstream, name the branch to check out"
  fi
  if [[ $ref =~ ^[0-9a-f]{7,64}$ ]] && sha=$(git -C "$TOP" rev-parse -q --verify "$ref^{commit}"); then
    git -C "$TOP" checkout -q "${F[@]}" --detach "$sha"   # a commit that is already here
  elif git -C "$TOP" show-ref -q --verify "refs/heads/$ref"; then
    git -C "$TOP" checkout -q "${F[@]}" "$ref" --
  else
    fetch_top "$ref"
  fi
  if [[ -n $old ]]; then drop_removed "$TOP" "$old" HEAD; fi
  if (( FORCE )); then git -C "$TOP" clean -ffdq; fi
  if (( PRUNE )); then prune "$TOP"; fi
}

# REF: fetch REF into TOP and check it out
fetch_top() {
  local ref=$1 remote=origin remotes line sha desc branch spec s covered=0
  local -a depth=() progress=() specs=()
  remotes=$'\n'$(git -C "$TOP" remote)$'\n'
  if [[ $ref == */* && $remotes == *$'\n'"${ref%%/*}"$'\n'* ]]; then remote=${ref%%/*} ref=${ref#*/}; fi
  if [[ $(git -C "$TOP" rev-parse --is-shallow-repository) == true ]]; then depth=(--depth 1); fi
  if (( TTY )); then progress=(--progress); fi
  git -C "$TOP" fetch -q "${progress[@]}" --no-tags "${depth[@]}" "$remote" "$ref"
  # FETCH_HEAD: "SHA<tab>[not-for-merge]<tab>branch 'NAME' of URL" (or tag 'NAME', or 'SHA')
  read -r line < "$(git -C "$TOP" rev-parse --path-format=absolute --git-path FETCH_HEAD)"
  sha=${line%%$'\t'*} desc=${line##*$'\t'}
  if [[ $desc == "branch '"* ]]; then
    branch=${desc#"branch '"} branch=${branch%"' of "*}
    spec=refs/heads/$branch:refs/remotes/$remote/$branch
    mapfile -t specs < <(git -C "$TOP" config get --all "remote.$remote.fetch" || true)
    for s in "${specs[@]}"; do
      if [[ ${s#+} == "refs/heads/*:refs/remotes/$remote/*" || ${s#+} == "$spec" ]]; then covered=1; fi
    done
    if (( ! covered )); then git -C "$TOP" config --add "remote.$remote.fetch" "+$spec"; fi
    git -C "$TOP" update-ref "refs/remotes/$remote/$branch" "$sha"
    git -C "$TOP" checkout -q "${F[@]}" -B "$branch" --track "$remote/$branch"
  else
    git -C "$TOP" checkout -q "${F[@]}" --detach "$sha"
  fi
}

main() {
  local dir=. ref='' out size el commit branch failed=''
  local -i t0=${EPOCHREALTIME/[.,]/}
  while (( $# )); do
    case $1 in
      -f|--force) FORCE=1 F=(-f); shift ;;
      -C) dir=$2; shift 2 ;;
      -j) JOBS=$2; shift 2 ;;
      --gc) PRUNE=1; shift ;;
      -h|--help) sed -n '2,16s/^# \{0,1\}//p' "$0"; exit 0 ;;
      -*) die "unknown option $1" ;;
      *) if [[ -n $ref ]]; then die "only one REF expected"; fi; ref=$1; shift ;;
    esac
  done
  if [[ ! $JOBS =~ ^[1-9][0-9]*$ ]]; then die "-j needs a positive number"; fi
  TOP=$(git -C "$dir" rev-parse --show-toplevel)
  PROFILE=$(git -C "$TOP" config get gitclone.profile || true)
  if [[ -n $ref ]] || (( FORCE )); then checkout_top "$ref"; fi
  walk "$TOP" sub_sync
  if (( WALK_NEW )) && ! out=$(git -C "$TOP" submodule --quiet absorbgitdirs 2>&1); then
    printf '%s\n' "$out" >&2; exit 1
  fi
  hsize "$WALK_KIB"; size=$REPLY
  htime $(( (${EPOCHREALTIME/[.,]/} - t0) / 1000000 )); el=$REPLY
  if (( WALK_FAILED )); then failed=", $WALK_FAILED FAILED"; fi
  commit=$(git -C "$TOP" log -1 --format='%h %s')
  branch=$(git -C "$TOP" rev-parse --abbrev-ref HEAD)
  printf '%s: %d submodules%s, fetched %s in %s\n' "${0##*/}" "$WALK_DONE" "$failed" "$size" "$el" >&2
  echo "Using commit ${commit%% *} ($branch): ${commit#* }"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; (( ! WALK_FAILED )); fi
