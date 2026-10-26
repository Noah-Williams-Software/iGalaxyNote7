#!/usr/bin/env bash
# Install helper for the Galaxy Note 7 / Note FE (Exynos 8890) from TWRP.
#
#   sudo tools/note7-install.sh status
#   sudo tools/note7-install.sh backup
#   sudo tools/note7-install.sh flash-boot IMAGE.img      (probe or XNU BOOT image)
#   sudo tools/note7-install.sh flash-root PART00 [PART01 ...]   (ERASES USERDATA)
#   sudo tools/note7-install.sh restore                   (stock BOOT back, from the backup)
#   sudo tools/note7-install.sh logs [OUT.txt]
#
# Run it with the phone in TWRP, connected by USB. Root is only for USB/adb access.
# It writes exactly two partitions, BOOT and USERDATA, and never EFS, RECOVERY or
# the bootloader. Every write needs a typed confirmation, a stock-BOOT backup that
# was verified on both sides, and is read back afterwards. Nothing is tested on a
# Note 7 yet (see NOTE7_PROGRESS.md): start with the probe image.
#
# Environment: ADB (adb binary), BACKUP_DIR (default: backup/note7-<serial>, which
# .gitignore excludes), ASSUME_YES=1 is deliberately not supported.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
ADB=${ADB:-adb}
UFS=/dev/block/platform/155a0000.ufs/by-name
owner=${SUDO_USER:-root}

die() { echo "error: $*" >&2; exit 1; }
say() { echo "== $*"; }

[ "$(id -u)" -eq 0 ] || die "run with sudo (adb needs USB access)"
command -v "$ADB" >/dev/null || die "adb not found (install android-tools-adb or set ADB=)"
command -v python3 >/dev/null || die "python3 not found"
[ -t 0 ] || die "needs an interactive terminal for confirmations"

confirm() { # confirm PROMPT [PHRASE]: default phrase is "yes"
    local phrase=${2:-yes} reply
    read -r -p "$1 Type '$phrase' to continue: " reply
    [ "$reply" = "$phrase" ] || die "not confirmed, nothing written"
}

phone() { "$ADB" -s "$SERIAL" shell "$@" | tr -d '\r'; }

connect() {
    "$ADB" start-server >/dev/null 2>&1 || true
    local devs
    devs=$("$ADB" devices | awk 'NR>1 && $2 != "" {print $1 ":" $2}')
    [ -n "$devs" ] || die "no device. Boot TWRP (Power+Vol Up+Home), plug in USB. If adb ran as your user, try: adb kill-server"
    [ "$(echo "$devs" | wc -l)" -eq 1 ] || die "several devices connected, unplug the others: $devs"
    SERIAL=${devs%%:*}
    local state=${devs##*:}
    [ "$state" = recovery ] || die "device state is '$state', need 'recovery' (TWRP), not Android"
    BACKUP_DIR=${BACKUP_DIR:-$repo/backup/note7-$SERIAL}

    local name hw
    name=$(phone getprop ro.product.device)
    hw=$(phone getprop ro.board.platform)
    echo "device: ${name:-unknown} (platform: ${hw:-unknown}, serial: $SERIAL)"
    case $name in
        gracelte | gracerlte | herolte | hero2lte) ;;
        graceqlte | *qlte) die "'$name' is a Snapdragon model; this port is Exynos 8890 only" ;;
        *) echo "warning: '$name' is not a known Exynos 8890 name (gracelte, gracerlte)"
           confirm "Continue with an unrecognised device?" "unknown device" ;;
    esac
    phone "[ -e $UFS/BOOT ] && [ -e $UFS/USERDATA ]" ||
        die "$UFS/BOOT or USERDATA missing: not an Exynos 8890 UFS layout"
    BOOT_SIZE=$(phone blockdev --getsize64 "$UFS/BOOT")
    echo "BOOT: $(phone readlink -f "$UFS/BOOT") ($BOOT_SIZE bytes)"
    echo "USERDATA: $(phone readlink -f "$UFS/USERDATA") ($(phone blockdev --getsize64 "$UFS/USERDATA") bytes)"
}

# pull_verified PHONE_PATH LOCAL_PATH: copy and compare SHA-256 on both sides.
pull_verified() {
    local want got
    "$ADB" -s "$SERIAL" pull "$1" "$2" >/dev/null
    want=$(phone sha256sum "$1" | awk '{print $1}')
    got=$(sha256sum "$2" | awk '{print $1}')
    [ -n "$want" ] && [ "$want" = "$got" ] || die "checksum mismatch pulling $1"
    echo "  $2 sha256 $got"
}

do_backup() {
    mkdir -p "$BACKUP_DIR"
    say "backing up BOOT and EFS (read-only) to $BACKUP_DIR"
    local part
    for part in BOOT EFS; do
        if phone "[ -e $UFS/$part ]"; then
            phone "dd if=$UFS/$part of=/tmp/$part.img bs=1048576 2>/dev/null"
            pull_verified "/tmp/$part.img" "$BACKUP_DIR/$part.img"
            phone "rm -f /tmp/$part.img"
        else
            echo "  (no $part partition by that name; skipped)"
        fi
    done
    [ -s "$BACKUP_DIR/BOOT.img" ] || die "BOOT backup is empty"
    [ -s "$BACKUP_DIR/EFS.img" ] || echo "warning: EFS not backed up. Do not continue without a TWRP EFS backup."
    chown -R "$owner" "$BACKUP_DIR" 2>/dev/null || true
    say "done. Copy $BACKUP_DIR somewhere off this PC; it holds your IMEI."
}

# write_boot IMAGE: verified backup first, size and header checks, write, read back.
write_boot() {
    local img=$1 size want got blocks
    [ -f "$img" ] || die "no such file: $img"
    [ -s "$BACKUP_DIR/BOOT.img" ] || die "no BOOT backup in $BACKUP_DIR; run: $0 backup"
    [ "$(head -c 8 "$img")" = "ANDROID!" ] || die "$img is not an Android boot image"
    size=$(stat -c %s "$img")
    [ "$size" -le "$BOOT_SIZE" ] || die "image ($size) is larger than BOOT ($BOOT_SIZE)"
    echo "image: $img ($size bytes, sha256 $(sha256sum "$img" | awk '{print $1}'))"
    confirm "This overwrites the BOOT partition (your stock copy is in $BACKUP_DIR)."

    "$ADB" -s "$SERIAL" push "$img" /tmp/boot.img >/dev/null
    want=$(sha256sum "$img" | awk '{print $1}')
    got=$(phone sha256sum /tmp/boot.img | awk '{print $1}')
    [ "$want" = "$got" ] || die "push corrupted, BOOT untouched"
    phone "dd if=/tmp/boot.img of=$UFS/BOOT bs=1048576 conv=fsync 2>/dev/null"
    blocks=$(((size + 4095) / 4096))
    got=$(phone "dd if=$UFS/BOOT bs=4096 count=$blocks 2>/dev/null | head -c $size | sha256sum" | awk '{print $1}')
    [ "$want" = "$got" ] ||
        die "BOOT read-back differs! Do NOT reboot. Run: $0 restore"
    phone "rm -f /tmp/boot.img"
    say "BOOT written and verified"
}

reboot_prompt() {
    local reply
    read -r -p "Reboot now? [y/N] " reply
    [ "$reply" = y ] && "$ADB" -s "$SERIAL" reboot
    return 0
}

do_flash_root() {
    [ "$#" -ge 1 ] || die "usage: flash-root root.img.gz.part00 [part01 ...]"
    local f
    for f in "$@"; do [ -f "$f" ] || die "no such file: $f"; done
    [ -s "$BACKUP_DIR/BOOT.img" ] || die "no BOOT backup in $BACKUP_DIR; run: $0 backup"
    if phone mount | grep -q ' /data '; then
        echo "/data is mounted. It has to be unmounted before USERDATA is written."
        confirm "Unmount /data now (TWRP stops using it)?"
        phone "umount /data" || die "could not unmount /data; unmount it in TWRP (Mount menu)"
    fi
    echo "This ERASES everything in USERDATA: all Android data, photos and apps."
    confirm "There is no undo." "ERASE USERDATA"
    python3 "$repo/tools/herolte-flash-root.py" "$ADB" "$@" --state "$BACKUP_DIR/flash.state"
    chown -R "$owner" "$BACKUP_DIR" 2>/dev/null || true
}

do_logs() {
    local out=${1:-$BACKUP_DIR/boot-log.txt}
    mkdir -p "$(dirname "$out")"
    python3 "$repo/tools/herolte-log-pull.py" "$ADB" "$out"
    chown "$owner" "$out" "$out.bin" 2>/dev/null || true
    echo "log: $out (may contain device identifiers; keep it out of git)"
}

cmd=${1:-}
[ -n "$cmd" ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
shift
connect
case $cmd in
    status) ;;
    backup) do_backup ;;
    flash-boot) [ "$#" -eq 1 ] || die "usage: flash-boot IMAGE.img"
        write_boot "$1"; reboot_prompt ;;
    restore) write_boot "$BACKUP_DIR/BOOT.img"; reboot_prompt ;;
    flash-root) do_flash_root "$@" ;;
    logs) do_logs "$@" ;;
    *) die "unknown command '$cmd'" ;;
esac
