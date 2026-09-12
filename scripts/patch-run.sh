#!/usr/bin/env bash
# usage: patch-run.sh /path/to/sas-creator/run.sh
#
# sas-creator's run.sh was written in 2022 against an early Android 11 build.
# Newer builds moved or removed a few files it pokes at unconditionally
# (e.g. etc/init/llkd*.rc), which makes the script die because of `set -e`.
#
# This rewrites exactly those statements into per-file guarded loops:
#   for f in <files>; do [ -e "$f" ] || continue; <cmd> "$f"; done
# and turns cp-from-apex into an existence-guarded block.
#
# Every rewrite is matched against the pinned upstream revision, so if
# upstream changes we fail loudly instead of silently skipping a patch.
set -euo pipefail

run="${1:?usage: patch-run.sh /path/to/run.sh}"
[ -f "$run" ] || { echo "!! $run not found" >&2; exit 1; }

/usr/bin/python3 - "$run" <<'PY'
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

LLKD = "etc/init/llkd-debuggable.rc etc/init/llkd.rc"
LLKD_LIST = "etc/init/llkd-debuggable.rc etc/init/llkd.rc"
ZYG = ("etc/init/hw/init.zygote64.rc etc/init/hw/init.zygote64_32.rc "
       "etc/init/hw/init.zygote32_64.rc etc/init/hw/init.zygote32.rc")

def loop(cmd, files):
    return ('for f in %s; do [ -e "$f" ] || continue; %s "$f"; done' % (files, cmd))

REPLACEMENTS = [
    # --- files a newer tree may have removed -----------------------------
    ("sed -i 's/readproc//g' " + LLKD,
     loop("sed -i 's/readproc//g'", LLKD_LIST)),

    ("xattr -w security.selinux u:object_r:sepolicy_file:s0 " + LLKD,
     loop("xattr -w security.selinux u:object_r:sepolicy_file:s0", LLKD_LIST)),

    ("sed -E -i 's/\\+passcred//g' etc/init/logd.rc",
     loop("sed -E -i 's/\\+passcred//g'", "etc/init/logd.rc")),

    ("sed -E -i 's/\\+passcred//g' etc/init/lmkd.rc",
     loop("sed -E -i 's/\\+passcred//g'", "etc/init/lmkd.rc")),

    ("sed -E -i 's/reserved_disk//g' etc/init/vold.rc",
     loop("sed -E -i 's/reserved_disk//g'", "etc/init/vold.rc")),

    ("xattr -w security.selinux u:object_r:system_file:s0 "
     "etc/init/vold.rc etc/init/logd.rc etc/init/lmkd.rc",
     loop("xattr -w security.selinux u:object_r:system_file:s0",
          "etc/init/vold.rc etc/init/logd.rc etc/init/lmkd.rc")),

    ("sed -E -i /rlimit/d etc/init/bpfloader.rc etc/init/cameraserver.rc",
     loop("sed -E -i /rlimit/d", "etc/init/bpfloader.rc etc/init/cameraserver.rc")),

    ("xattr -w security.selinux u:object_r:system_file:s0 "
     "etc/init/bpfloader.rc etc/init/cameraserver.rc",
     loop("xattr -w security.selinux u:object_r:system_file:s0",
          "etc/init/bpfloader.rc etc/init/cameraserver.rc")),

    ("sed -i -e s/readproc//g -e s/reserved_disk//g " + ZYG,
     loop("sed -i -e s/readproc//g -e s/reserved_disk//g", ZYG)),

    ("xattr -w security.selinux u:object_r:system_file:s0 " + ZYG,
     loop("xattr -w security.selinux u:object_r:system_file:s0", ZYG)),

    # --- copying an init.rc out of an apex that may not be there ---------
    ("cp system_ext/apex/com.android.media.swcodec/etc/init.rc etc/init/media-swcodec.rc\n"
     "xattr -w security.selinux u:object_r:system_file:s0 etc/init/media-swcodec.rc",
     "if [ -f system_ext/apex/com.android.media.swcodec/etc/init.rc ]; then\n"
     "    cp system_ext/apex/com.android.media.swcodec/etc/init.rc etc/init/media-swcodec.rc\n"
     "    xattr -w security.selinux u:object_r:system_file:s0 etc/init/media-swcodec.rc\n"
     "fi"),

    ("cp system_ext/apex/com.android.adbd/etc/init.rc etc/init/adbd.rc\n"
     "xattr -w security.selinux u:object_r:system_file:s0 etc/init/adbd.rc",
     "if [ -f system_ext/apex/com.android.adbd/etc/init.rc ]; then\n"
     "    cp system_ext/apex/com.android.adbd/etc/init.rc etc/init/adbd.rc\n"
     "    xattr -w security.selinux u:object_r:system_file:s0 etc/init/adbd.rc\n"
     "fi"),
]

missing = [orig for orig, _ in REPLACEMENTS if orig not in src]
if missing:
    print("!! upstream run.sh did not contain the expected statement(s):", file=sys.stderr)
    for m in missing:
        print("   " + m.replace("\n", "\\n")[:120], file=sys.stderr)
    print("!! refusing to patch (upstream changed?) -- review scripts/patch-run.sh",
          file=sys.stderr)
    sys.exit(1)

for orig, new in REPLACEMENTS:
    src = src.replace(orig, new, 1)

open(path, "w", encoding="utf-8").write(src)
print("patched %d statements in %s" % (len(REPLACEMENTS), path))
PY

bash -n "$run"
echo ">> $run parses ok"
