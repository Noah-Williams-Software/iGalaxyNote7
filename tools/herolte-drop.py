#!/usr/bin/env python3
"""Put files into the S7's iOS root from TWRP, through the kernel's drop zone.

The 128 MiB of USERDATA right below the persistent log (beyond the 20 GiB
HFSX volume) hold a package that the kernel writes into the root volume on
every boot, just before launchd (bsd/dev/herolte_drop.c). Destinations must
be under /private/var/herolte/; /private/var/herolte/autorun runs once per
boot as root (launchd job com.herolte.autorun, tools/herolte-tune-ios-root.sh).

  herolte-drop.py ADB autorun=build/herogpu-test [lib/libfoo.dylib=out/libfoo.dylib ...]
  herolte-drop.py ADB --clear

DEST=SRC: DEST is relative to /private/var/herolte/ (directories are created);
files keep SRC's executable bit (mode 0755 or 0644). Run with the phone in
TWRP, /data unmounted.
"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys
import time

DEV = '/dev/block/platform/155a0000.ufs/by-name/USERDATA'
BLOCK = 4096
LOG_BLOCKS = 1 + (4 << 20) // BLOCK
DROP_BLOCKS = 32768
PREFIX = '/private/var/herolte/'


def adb(tool, *args, data=None):
    return subprocess.run([tool, *args], check=True, capture_output=True, input=data).stdout


def pack(items):
    payload = bytearray()
    dirs = set()
    entries = []
    for dest, src in items:
        dest = dest.strip('/')
        parts = dest.split('/')
        for i in range(1, len(parts)):
            d = PREFIX + '/'.join(parts[:i])
            if d not in dirs:
                dirs.add(d)
                entries.append((d, 0, b''))
        data = open(src, 'rb').read()
        mode = 0o755 if os.access(src, os.X_OK) or dest == 'autorun' else 0o644
        entries.append((PREFIX + dest, mode, data))
    for path, mode, data in entries:
        p = path.encode()
        payload += struct.pack('<IIQ', len(p), mode, len(data)) + p
        payload += b'\0' * (-len(payload) % 8)
        payload += data
        payload += b'\0' * (-len(payload) % 8)
    if len(payload) > (DROP_BLOCKS - 1) * BLOCK:
        sys.exit(f'package too large: {len(payload)} bytes')
    ident = int(time.time())
    header = struct.pack('<8sIIQQ', b'HERODRP1', 1, len(entries), len(payload), ident)
    blob = header + b'\0' * (BLOCK - len(header)) + bytes(payload)
    blob += b'\0' * (-len(blob) % BLOCK)
    return blob, entries, ident


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('adb')
    ap.add_argument('items', nargs='*', help='DEST=SRC')
    ap.add_argument('--clear', action='store_true', help='erase the package header')
    args = ap.parse_args()

    size = int(adb(args.adb, 'shell', f'blockdev --getsize64 {DEV}').strip())
    first = size // BLOCK - LOG_BLOCKS - DROP_BLOCKS
    if args.clear:
        adb(args.adb, 'shell', f'dd if=/dev/zero of={DEV} bs={BLOCK} seek={first} count=1 conv=fsync')
        print('drop zone cleared')
        return
    if not args.items:
        ap.error('nothing to drop')
    blob, entries, ident = pack([i.split('=', 1) for i in args.items])
    local = 'herolte-drop.bin'
    open(local, 'wb').write(blob)
    adb(args.adb, 'push', local, '/tmp/drop.bin')
    adb(args.adb, 'shell', f'dd if=/tmp/drop.bin of={DEV} bs={BLOCK} seek={first} conv=fsync')
    back = adb(args.adb, 'shell', f'dd if={DEV} bs={BLOCK} skip={first} count={len(blob) // BLOCK} '
                                  f'2>/dev/null | sha256sum').split()[0].decode()
    adb(args.adb, 'shell', 'rm /tmp/drop.bin')
    os.remove(local)
    ok = back == hashlib.sha256(blob).hexdigest()
    for path, mode, data in entries:
        print(f'  {"dir " if mode == 0 else oct(mode)} {path} {len(data)} bytes')
    print(f'package {ident}: {len(blob)} bytes at block {first} -> {"verified" if ok else "MISMATCH"}')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
