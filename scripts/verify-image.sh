#!/usr/bin/env bash
# usage: verify-image.sh <system.img>
#
# Sanity-checks the output of sas-creator's run.sh. Exits non-zero on failure
# so CI catches a bad image instead of you flashing it.
set -uo pipefail

img="${1:?usage: verify-image.sh <system.img>}"
fail=0

ok()  { echo "  OK   $*"; }
bad() { echo "  FAIL $*"; fail=1; }

has() { # has <dir-in-image> <substring>
  local dir="$1" pat="$2"
  if debugfs -R "ls -l $dir" "$img" 2>/dev/null | grep -q -- "$pat"; then
    ok "$dir contains $pat"
  else
    bad "$dir missing $pat"
  fi
}

echo "== filesystem =="
if e2fsck -fn "$img" >/tmp/fsck.out 2>&1; then
  ok "e2fsck clean"
else
  bad "e2fsck reported problems:"
  sed 's/^/       /' /tmp/fsck.out
fi

echo
echo "== layout (must be non-sas) =="
rootlist="$(debugfs -R "ls -l /" "$img" 2>/dev/null)"
echo "$rootlist" | sed 's/^/  | /'
names="$(echo "$rootlist" | awk '{print $NF}')"
for p in bin etc build.prop framework lib64 system_ext xbin; do
  if echo "$names" | grep -qx -- "$p"; then ok "/$p present"; else bad "/$p missing"; fi
done
if echo "$names" | grep -qx -- "system"; then
  bad "top-level /system still present -- image is still system-as-root"
else
  ok "no top-level /system (non-sas)"
fi

echo
echo "== sas-creator patches =="
has /lib            "vndk-26"
has /lib            "vndk-sp-26"
has /lib64          "vndk-26"
has /lib64          "vndk-sp-26"
has /etc/init       "apex-setup.rc"
has /etc/init       "init-environ.rc"
has /system_ext/apex "com.android.vndk.v26"

if debugfs -R "ea_list /bin/sh" "$img" 2>/dev/null | grep -q "security.selinux"; then
  ok "selinux xattr present on /bin/sh"
else
  bad "selinux xattr missing on /bin/sh"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "SOME CHECKS FAILED"
  exit 1
fi
