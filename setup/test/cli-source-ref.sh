#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # each case sets its own subshell environment
set -Eeuo pipefail
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_EDITOR=true

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
fixture="$temporary/source repository"
checkout="$temporary/selected checkout"
unset VPHONE_CLI VPHONE_TEST_FETCH_LOG VPHONE_TEST_NO_FETCH
git() {
  if [[ ${1:-} == -C && ${3:-} == fetch ]]; then
    [ -z "${VPHONE_TEST_FETCH_LOG:-}" ] || printf '%s\n' "$*" >> "$VPHONE_TEST_FETCH_LOG"
    [ "${VPHONE_TEST_NO_FETCH:-0}" != 1 ] || return 97
  fi
  command git "$@"
}
export -f git
git init --quiet "$fixture"
printf 'first\n' > "$fixture/source.swift"
git -C "$fixture" add source.swift
git -C "$fixture" -c commit.gpgsign=false -c user.name=Fixture \
  -c user.email=fixture@example.invalid commit --quiet -m first
first=$(git -C "$fixture" rev-parse HEAD)
git -C "$fixture" tag selected-tag
printf 'second\n' > "$fixture/source.swift"
git -C "$fixture" add source.swift
git -C "$fixture" -c commit.gpgsign=false -c user.name=Fixture \
  -c user.email=fixture@example.invalid commit --quiet -m second
second=$(git -C "$fixture" rev-parse HEAD)

prepare() (
  unset VPHONE_CLI
  export VPHONE_CLI_REPO=${4:-$fixture} VPHONE_CLI_REF=$2
  export VPHONE_CLI_PUBLIC=unrelated-public-resources VPHONE_CLI_VERSION=2.14.2
  # shellcheck disable=SC1091  # this checkout's production helper
  source "$repo/setup/lib/common.sh"
  ensure_vphone_cli_source "$1"
  [ "$(git -C "$1" rev-parse HEAD)" = "$3" ]
  [ "$VPHONE_CLI_PUBLIC" = unrelated-public-resources ]
)

prepare "$checkout" "$first" "$first"
[ "$(cat "$checkout/source.swift")" = first ]
prepare "$temporary/tag checkout" selected-tag "$first"

# A fetched immutable revision can be rebuilt while its remote is unavailable.
mv "$fixture" "$fixture.offline"
prepare "$checkout" "$first" "$first"
VPHONE_TEST_NO_FETCH=1 prepare "$temporary/tag checkout" selected-tag "$first"
mv "$fixture.offline" "$fixture"

# Equivalent source URLs do not invalidate a managed checkout.
normalized="$temporary/normalized origin"
git -c advice.detachedHead=false clone --quiet --branch selected-tag "$fixture" "$normalized"
git -C "$normalized" remote set-url origin https://github.invalid/example/vphone-cli.git/
VPHONE_TEST_NO_FETCH=1 prepare "$normalized" "$first" "$first" https://github.invalid/example/vphone-cli
git -C "$normalized" remote set-url origin https://github.invalid/example/vphone-cli
VPHONE_TEST_NO_FETCH=1 prepare "$normalized" "$first" "$first" https://github.invalid/example/vphone-cli.git///

# Fetching an absent revision must preserve an existing full clone and its HEAD.
full="$temporary/full clone"
git clone --quiet "$fixture" "$full"
printf 'third\n' > "$fixture/source.swift"
git -C "$fixture" add source.swift
git -C "$fixture" -c commit.gpgsign=false -c user.name=Fixture \
  -c user.email=fixture@example.invalid commit --quiet -m third
third=$(git -C "$fixture" rev-parse HEAD)
if prepare "$full" "$third" "$third" > "$temporary/full.log" 2>&1; then
  echo 'FAIL: an existing full clone was reset to a fetched revision' >&2; exit 1
fi
[ "$(git -C "$full" rev-parse --is-shallow-repository)" = false ]
[ "$(git -C "$full" rev-parse HEAD)" = "$second" ]
grep -Fq 'preserve' "$temporary/full.log"

if prepare "$checkout" "$second" "$second" > "$temporary/mismatch.log" 2>&1; then
  echo 'FAIL: a different existing HEAD was accepted' >&2; exit 1
fi
grep -Fq 'preserve' "$temporary/mismatch.log"
[ "$(git -C "$checkout" rev-parse HEAD)" = "$first" ]
[ "$(cat "$checkout/source.swift")" = first ]

printf 'local edit\n' > "$checkout/source.swift"
printf 'untracked edit\n' > "$checkout/new.swift"
if prepare "$checkout" "$first" "$first" > "$temporary/dirty.log" 2>&1; then
  echo 'FAIL: modified sources were accepted as the pinned ref' >&2; exit 1
fi
grep -Fq 'local changes' "$temporary/dirty.log"
[ "$(cat "$checkout/source.swift")" = 'local edit' ]
[ "$(cat "$checkout/new.swift")" = 'untracked edit' ]

if prepare "$temporary/tag checkout" "$first" "$first" "$temporary/other repository" \
    > "$temporary/origin.log" 2>&1; then
  echo 'FAIL: a different source origin was accepted' >&2; exit 1
fi
grep -Fq 'origin differs' "$temporary/origin.log"
[ "$(git -C "$temporary/tag checkout" remote get-url origin)" = "$fixture" ]

mkdir "$temporary/not git"
printf 'preserved\n' > "$temporary/not git/keep"
if prepare "$temporary/not git" "$first" "$first" > "$temporary/non-git.log" 2>&1; then
  echo 'FAIL: a non-Git source directory was accepted' >&2; exit 1
fi
[ "$(cat "$temporary/not git/keep")" = preserved ]

# An explicitly selected developer checkout belongs to the caller.
(
  export VPHONE_CLI="$checkout" VPHONE_CLI_REPO="$temporary/another fork" VPHONE_CLI_REF=-not-a-ref
  # shellcheck disable=SC1091
  source "$repo/setup/lib/common.sh"
  ensure_vphone_cli_source "$VPHONE_CLI"
)
[ "$(cat "$checkout/source.swift")" = 'local edit' ]
[ "$(cat "$checkout/new.swift")" = 'untracked edit' ]

# Exercise setup's actual caller without compiling Swift or touching a VM.
setup_script=${VPHONE_TEST_SETUP_SCRIPT:-$repo/setup/setup.sh}
sed -n '/^build_creator() {$/,/^}$/p' "$setup_script" > "$temporary/build-creator.sh"
mkdir -p "$temporary/backend/linux-create"
cat > "$temporary/backend/linux-create/build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1090  # test supplies the production helper path
source "$VPHONE_TEST_COMMON"
ensure_vphone_cli_source "$VPHONE_CLI"
printf '%s\n' "$VPHONE_CLI" > "$CAPTURE"
EOF
chmod +x "$temporary/backend/linux-create/build.sh"
(
  export VPHONE_CLI_REPO=$fixture VPHONE_CLI_REF=selected-tag
  export VPHONE_CLI_VERSION=2.14.2 VPHONE_CLI_PUBLIC=unrelated-public-resources
  export VSETUP_SRC="$temporary/backend" CAPTURE="$temporary/caller-path"
  export VPHONE_TEST_COMMON="$repo/setup/lib/common.sh" VPHONE_TEST_FETCH_LOG="$temporary/caller-fetches"
  # shellcheck disable=SC1091  # production helper and extracted caller
  source "$repo/setup/lib/common.sh"
  # shellcheck disable=SC1091
  source "$temporary/build-creator.sh"
  build_creator
)
[ "$(cat "$temporary/caller-path")" = "$temporary/backend/cpu-tree/vphone-cli-2.14.2" ]
[ "$(git -C "$(cat "$temporary/caller-path")" rev-parse HEAD)" = "$first" ]
[ "$(wc -l < "$temporary/caller-fetches")" = 1 ]

(
  export VPHONE_CLI="$checkout" VPHONE_CLI_REPO="$temporary/another fork" VPHONE_CLI_REF=-not-a-ref
  export VSETUP_SRC="$temporary/backend" CAPTURE="$temporary/explicit-caller-path"
  export VPHONE_TEST_COMMON="$repo/setup/lib/common.sh"
  # shellcheck disable=SC1091
  source "$repo/setup/lib/common.sh"
  # shellcheck disable=SC1091
  source "$temporary/build-creator.sh"
  build_creator
)
[ "$(cat "$temporary/explicit-caller-path")" = "$checkout" ]
echo 'OK: source ref selection and existing checkout preservation'
