#!/usr/bin/env bash
# Local mirror of .github/workflows/validate.yml — run before pushing.
# Never builds or boots anything; safe next to a running VM.
set -eu
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091  # this checkout's own lib/common.sh, resolved at run time
source "$(pwd)/lib/common.sh"

status=0
bash test/linux-create-release-cli.sh || status=1
for f in $(find "$VSETUP_ROOT" -name '*.sh' -type f | sort); do
  bash -n "$f" || { echo "FAIL bash -n $f"; status=1; }
done
if command -v shellcheck >/dev/null; then
  # shellcheck disable=SC2046  # the filenames have no spaces in this checkout
  shellcheck -x --severity=style $(find "$VSETUP_ROOT" -name '*.sh' -type f) || status=1
fi
python3 "$VSETUP_ROOT/lib/json_query.py" validate || status=1
bash "$VSETUP_ROOT/test/display-density.sh" || status=1
"$VSETUP_ROOT/create-vm.sh" --list >/dev/null || status=1
"$VSETUP_ROOT/test/cfw-work-parent.sh" || status=1
bash "$VSETUP_ROOT/test/release-bundle.sh" || status=1
"$VSETUP_ROOT/test/run-vphone-gdb.sh" || status=1
"$VSETUP_ROOT/test/vphone-caller-env.sh" || status=1
bash "$VSETUP_ROOT/test/first-boot-qmp.sh" || status=1
bash "$VSETUP_ROOT/test/cli-source-ref.sh" || status=1

# dry-run sanity for the reference pairing
VSETUP_SRC=/tmp/vs-src VSETUP_RELEASE=/tmp/vs-rel VSETUP_DEVICES=/tmp/vs-dev \
  ./create-vm.sh --dry-run -y --device 'iPhone17,3' --ios 26.6.2 --name ci-smoke \
  > /tmp/vs-smoke.log 2>&1 || status=1
grep -q 'dry-run' /tmp/vs-smoke.log || { echo 'FAIL: no dry-run output'; status=1; }
bash "$VSETUP_ROOT/test/cache-path.sh" || status=1
grep -Fq "VC=/tmp/vs-src/linux-create/.build/out/out/Products/Release-linux-$(uname -m)/vphone-cli" /tmp/vs-smoke.log || {
  echo 'FAIL: dry-run did not resolve the Release vphone-cli'; status=1;
}

if grep -nE '(^|[^[:alnum:]_])(pkill|killall|fuser -k)' setup.sh create-vm.sh lib/common.sh; then
  echo 'FAIL: kill commands are not allowed in setup scripts'; status=1
fi

[ "$status" = 0 ] && echo 'OK'
exit "$status"
