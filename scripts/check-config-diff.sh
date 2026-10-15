#!/usr/bin/env bash
# Confirm that the final .config adds Landlock to the config Raspberry Pi ships
# for the pinned release. Writes the unified diff against that baseline, prints
# it for the job log, and keeps it as a release file. Other options that
# olddefconfig changes are not checked here.
#
# Usage: scripts/check-config-diff.sh <baseline-config> <final-config> <diff-out>
#   baseline-config  extracted by scripts/fetch-baseline.sh
#   final-config     .config after olddefconfig, the file that gets shipped
#   diff-out         where the unified diff is written
set -euo pipefail

die() {
  echo "check-config-diff: $*" >&2
  exit 1
}

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <baseline-config> <final-config> <diff-out>" >&2
  exit 2
fi
baseline=$1
final=$2
diff_out=$3

# diff exits 1 when the files differ, which is expected.
status=0
diff -u "$baseline" "$final" > "$diff_out" || status=$?
[ "$status" -le 1 ] || die "diff exited with status $status"
cat "$diff_out"

grep -q '^CONFIG_SECURITY_LANDLOCK=y$' "$baseline" && die "baseline already enables CONFIG_SECURITY_LANDLOCK"
grep -qxF 'CONFIG_SECURITY_LANDLOCK=y' "$final" || die "$final does not enable CONFIG_SECURITY_LANDLOCK"
lsm=$(grep -E '^CONFIG_LSM=' "$final" || true)
printf '%s\n' "$lsm" | grep -qE '^CONFIG_LSM="([^"]*,)?landlock(,[^"]*)?"$' \
  || die "$final does not list landlock in CONFIG_LSM (found: ${lsm:-nothing})"

echo "check-config-diff: Landlock added ($lsm); diff written to $diff_out"
