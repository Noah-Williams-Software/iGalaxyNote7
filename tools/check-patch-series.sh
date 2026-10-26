#!/bin/sh
# Replay the CI patch step (darwin-xnu-build build.sh patches()) on a Linux box:
# run xnu/patches/*.sh, then `git apply` every xnu/patches/*.patch in glob
# order, reporting each one that would be skipped. No compile; this only proves
# the series still applies to xnu-8796.141.3, which is where most CI runs die.
#
#   git clone --depth 1 --branch xnu-8796.141.3 \
#       https://github.com/apple-oss-distributions/xnu /tmp/xnu-src
#   tools/check-patch-series.sh /tmp/xnu-src [WORKDIR]
#
# The staging scripts download libpthread, HFS and BearSSL (network needed) and
# run them: read them first. NO_STAGING=1 skips them; patches that touch staged
# files then report as skipped, but nothing from the network is executed.
# SOURCE is never modified; the work copy is WORKDIR (default: mktemp -d).
set -eu
src=${1:?usage: check-patch-series.sh XNU_SOURCE [WORKDIR]}
work=${2:-$(mktemp -d)}
repo=$(cd "$(dirname "$0")/.." && pwd)
patches=$repo/xnu/patches

rm -rf "$work/xnu"
mkdir -p "$work"
cp -a "$src" "$work/xnu"
cd "$work/xnu"
git -c user.name=x -c user.email=x@x add -A >/dev/null 2>&1 || true

# GNU sed equivalents of the BSD sed edits in darwin-xnu-build patches().
sed -i 's|^LDFLAGS_KERNEL_SDK	= -L$(SDKROOT).*|LDFLAGS_KERNEL_SDK	= -L$(FAKEROOT_DIR)/usr/local/lib/kernel -lfirehose_kernel|' makedefs/MakeInc.def
sed -i 's|^\(INCFLAGS_SDK[[:space:]]*=\) -I$(SDKROOT)/usr/local/include/\(kernel\)\{0,1\}|\1 -I$(FAKEROOT_DIR)/usr/local/include/kernel|' makedefs/MakeInc.def
sed -i 's|export MIG := $(shell $(XCRUN) -sdk $(SDKROOT) -find mig)|export MIG := $(shell find $(FAKEROOT_DIR) -name "mig")|' makedefs/MakeInc.cmd
sed -i 's|export MIGCOM := $(shell $(XCRUN) -sdk $(SDKROOT) -find migcom)|export MIGCOM := $(shell find $(FAKEROOT_DIR) -name "migcom")|' makedefs/MakeInc.cmd

if [ -z "${NO_STAGING:-}" ]; then
    for s in "$patches"/*.sh; do
        echo "script: ${s##*/}"
        KDKROOT= bash "$s" >/dev/null
    done
fi

ok=0
bad=0
for p in "$patches"/*.patch; do
    if err=$(git apply --check "$p" 2>&1); then
        git apply "$p"
        ok=$((ok + 1))
    else
        bad=$((bad + 1))
        echo "SKIPPED ${p##*/}: $(echo "$err" | head -2 | tr '\n' ' ')"
    fi
done
echo "applied $ok, skipped $bad (work copy: $work/xnu)"
[ "$bad" -eq 0 ]
