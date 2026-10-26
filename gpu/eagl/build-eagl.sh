#!/bin/bash
# The EAGL shim (Bergamota's gpu/eagl, MIT) for the Galaxy S7's iOS 16, over
# the Panfrost libOSMesa from gpu/mesa/build-mesa.sh. Injection build only:
# the system OpenGLES.framework is in the dyld cache, so libheroeagl.dylib
# copies its EAGLContext/EAGLSharegroup methods into the real classes when
# loaded. iOS 16's CoreAnimation then gets a working ES3 context and uses its
# own GLES renderer (no QuartzCore hook needed, unlike iOS 18).
#
#   build-eagl.sh OUT        (OUT as given to build-mesa.sh: lib/libOSMesa.8.dylib, lib/libdrm.2.dylib)
#
# Adds lib/libheroeagl.dylib, eagl_ca_test (CARenderer through the shim) and
# hero-run (the autorun that runs a test and logs its output).
set -euo pipefail
OUT=$(cd "$1" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
MESA_INC=${MESA_INC:?set MESA_INC to the Mesa source include/ directory}
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC="xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 -isysroot $SDK"
OBJ=$(mktemp -d)

python3 "$HERE/tools/gen_gl_stubs.py" > "$OBJ/gl_stubs.c"
CF="-O2 -g -fvisibility=hidden -Wall -Wno-deprecated-declarations -Wno-unused-function -I$HERE/src -I$MESA_INC"
$CC $CF -c "$OBJ/gl_stubs.c" -o "$OBJ/gl_stubs.o"
for f in gl_resolve gl_unimpl osm macro_ctx macro_slots hero_log hero_backboardd; do
  $CC $CF -c "$HERE/src/$f.c" -o "$OBJ/$f.o"
done
$CC $CF -fno-objc-arc -fobjc-exceptions -DEAGL_INJECT -c "$HERE/src/eagl.m" -o "$OBJ/eagl.o"
$CC -dynamiclib -o "$OUT/lib/libheroeagl.dylib" "$OBJ"/{gl_stubs,gl_resolve,gl_unimpl,osm,macro_ctx,macro_slots,hero_log,hero_backboardd,eagl}.o \
  -install_name @rpath/libheroeagl.dylib \
  -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework IOSurface \
  -L "$OUT/lib" -lOSMesa.8 -Wl,-rpath,/private/var/herolte/lib -Wl,-undefined,error

# The CoreAnimation test links the SDK's OpenGLES and QuartzCore; EAGL_INJECT_LIB names the shim.
$CC -O1 -g -Wno-deprecated-declarations -fno-objc-arc -I"$HERE/src" "$HERE/test/eagl_ca_test.m" \
  -o "$OUT/eagl_ca_test" \
  -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework IOSurface \
  -framework QuartzCore -framework OpenGLES
$CC -O2 -Wall -o "$OUT/hero-run" "$HERE/test/hero-run.c" -L "$OUT/lib" -ldrm.2 \
  -Wl,-rpath,/private/var/herolte/lib

for f in "$OUT/lib/libheroeagl.dylib" "$OUT/eagl_ca_test" "$OUT/hero-run"; do
  codesign -s - -f "$f"
  otool -L "$f"
done
