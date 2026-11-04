#!/usr/bin/env bash
# Deploy-tag rules for main.yml and release.yml; tested by libs/utils/tests/test_release_tags.py.
# Any well-formed tag deploys: uat-* to uat, release-* to prod (prod after approval). Old tags too (rollback).
#   valid KIND NAME  exit 0 iff NAME is a well-formed KIND (uat|release) tag, else print an ::error::
#   newest KIND      the newest well-formed KIND tag on origin; fails if there is none
#   next KIND        next free KIND tag for today in Australia/Sydney (TODAY=YYYY-MM-DD overrides)
#   resolve EVENT REF DISPATCH_ENV DISPATCH_APPLY  print the env a main.yml run targets, or refuse it
set -euo pipefail

kind() { # sets RE and FMT (no subshell, so an unknown kind exits)
  case "$1" in
    uat | release) RE="^$1-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]+\$" FMT="$1-YYYY-MM-DD-N" ;;
    *) echo "unknown tag kind: $1" >&2; exit 2 ;;
  esac
}

valid() {
  kind "$1"
  [[ "$2" =~ $RE ]] || { echo "::error::'$2' is not a well-formed $1 tag ($FMT)"; return 1; }
}

list() { # well-formed KIND tags on origin, oldest -> newest
  local refs
  kind "$1"
  refs="$(git ls-remote --tags --refs origin "refs/tags/$1-*")" || return # fails closed: no origin, no list
  awk '{ sub(/^refs\/tags\//, "", $2); print $2 }' <<<"$refs" | { grep -E "$RE" || true; } | sort -V
}

newest() {
  local t
  t="$(list "$1" | tail -1)" && [ -n "$t" ] && echo "$t"
}

next() {
  local day n
  day="${TODAY:-$(TZ=Australia/Sydney date +%F)}"
  n="$(list "$1" | sed -n "s/^$1-${day}-//p" | sort -n | tail -1)"
  echo "$1-${day}-$((10#${n:-0} + 1))"
}

resolve() { # EVENT REF DISPATCH_ENV DISPATCH_APPLY
  local k="" env tag="${2#refs/tags/}"
  case "$2" in
    refs/tags/uat-*) k=uat env=uat ;;
    refs/tags/release-*) k=release env=prod ;;
  esac
  if [ "$1" = pull_request ] || [ "$1 $2" = "push refs/heads/main" ]; then
    echo dev # PRs into main: CI + dev plan; pushes to main: CI + dev plan + dev apply
  elif [ -z "$k" ]; then
    [ "$1" = workflow_dispatch ] || { echo "::error::No environment maps to $2"; return 1; }
    if [ "$4" = true ] && { [ "$3" = uat ] || [ "$3" = prod ]; }; then
      echo "::error::$3 applies only from a ${3/prod/release}-* tag, not a dispatch on $2"
      return 1
    fi
    echo "$3"
  else
    valid "$k" "$tag" || return 1
    # A dispatch on a deploy tag (release.yml's, or a rollback) stands in for its push.
    if [ "$1" = workflow_dispatch ] && { [ "$3" != "$env" ] || [ "$4" != true ]; }; then
      echo "::error::A dispatch on ${tag} deploys it: pass environment=${env} apply_changes=true"
      return 1
    fi
    echo "$env"
  fi
}

case "${1:-}" in
  valid | newest | next | resolve) "$@" ;;
  *) sed -n 's/^#   /  /p' "$0" >&2; exit 2 ;;
esac
