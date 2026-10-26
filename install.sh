#!/usr/bin/env bash
# Galaxy Note 7 / Note FE (Exynos 8890): build iOS 16 and install it from TWRP.
#
#   sudo ./install.sh                 run everything, resuming where it stopped
#   sudo ./install.sh --plan          show the stages and what is already done
#   sudo ./install.sh --stage kernel  run one stage (deps auth backup kernel root build probe flash)
#
# Needs: Linux with apt, dnf or pacman, the phone in TWRP on USB, a GitHub
# account. Stages, in order:
#   deps    install adb, an aarch64 GCC, gh, python3, git, curl (asks first)
#   auth    gh login (once); builds run in YOUR GitHub account
#   backup  verified copies of BOOT and EFS from the phone
#   kernel  start the macOS 'xnu' workflow in --repo, download the kernel
#   root    push this tree to YOUR PRIVATE repo, build the iOS root there from
#           Apple's IPSW, download it (Apple software never goes in a public repo)
#   build   loader, device tree, payload, BOOT images (probe and XNU)
#   probe   flash the probe, wait for TWRP, ask what the screen showed
#   flash   write USERDATA (ERASES ANDROID DATA) and the XNU BOOT, reboot
#
# Nothing here has run on a real Note 7. The kernel and root builds use
# GitHub's macOS runners; on a private repo they bill at 10x minutes and the
# root job can run for hours (a free account's minutes may not cover it).
# Everything it makes lives in .install/ (git-ignored). Re-running continues
# from the saved state; --force STAGE redoes a stage.
set -euo pipefail

repo=$(cd "$(dirname "$0")" && pwd)
cd "$repo"
owner=${SUDO_USER:-root}
W=$repo/.install
STAGES="deps auth backup kernel root build probe flash"

REPO_SLUG=""; REF=""; ROOT_REPO=""; CPUS=1; EXTRA=""; SKIP_PROBE=0
ONLY=""; PLAN=0; FORCE=""; TOUCH_RESET=0

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; cat <<'E'

options:
  --repo OWNER/NAME       repo whose Actions build the kernel (default: git remote origin)
  --ref BRANCH            branch to build (default: current branch; it must be pushed)
  --root-repo OWNER/NAME  PRIVATE repo for the iOS root build (default: <you>/note7-ios-root)
  --cpus N                cores for the first boot (default 1; try 4 then 8 once it boots)
  --touch-reset           add boot-arg gracelte_rstxfer=1 (touch bus reset per transfer)
  --extra-bootargs "..."  more XNU boot-args
  --skip-probe            skip the probe stage (not recommended on a first try)
  --stage NAME            run only this stage
  --force NAME            redo this stage even if it is marked done
  --plan                  show stages and state, change nothing
E
}

while [ $# -gt 0 ]; do
    case $1 in
        --repo) REPO_SLUG=$2; shift 2 ;;
        --ref) REF=$2; shift 2 ;;
        --root-repo) ROOT_REPO=$2; shift 2 ;;
        --cpus) CPUS=$2; shift 2 ;;
        --touch-reset) TOUCH_RESET=1; shift ;;
        --extra-bootargs) EXTRA=$2; shift 2 ;;
        --skip-probe) SKIP_PROBE=1; shift ;;
        --stage) ONLY=$2; shift 2 ;;
        --force) FORCE=$2; shift 2 ;;
        --plan) PLAN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown option $1" >&2; usage >&2; exit 1 ;;
    esac
done

mkdir -p "$W/state"
die() { echo "error: $*" >&2; exit 1; }
say() { echo; echo "=== $*"; }
done_stage() { [ -f "$W/state/$1.done" ] && [ "$FORCE" != "$1" ]; }
mark() { touch "$W/state/$1.done"; }
as_user() { if [ "$owner" = root ]; then "$@"; else sudo -u "$owner" -H env "PATH=$PATH" "$@"; fi; }
ask() { local r; read -r -p "$1 [y/N] " r; [ "$r" = y ]; }

if [ "$PLAN" -eq 1 ]; then
    for s in $STAGES; do
        if [ -f "$W/state/$s.done" ]; then echo "[done] $s"; else echo "[todo] $s"; fi
    done
    exit 0
fi

[ "$(id -u)" -eq 0 ] || die "run with sudo (apt and adb need root)"
[ -t 0 ] || die "needs an interactive terminal"
chown -R "$owner" "$W" 2>/dev/null || true

want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# ---------------------------------------------------------------- deps
stage_deps() {
    local missing="" c
    for c in adb aarch64-linux-gnu-gcc aarch64-linux-gnu-ld gh python3 git curl sha256sum; do
        command -v "$c" >/dev/null || missing="$missing $c"
    done
    if [ -z "$missing" ]; then echo "all tools present"; return; fi
    echo "missing:$missing"
    local pm pkgs
    if command -v apt-get >/dev/null; then
        pm="apt-get install -y"
        pkgs="adb gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu gh python3 git curl coreutils"
    elif command -v dnf >/dev/null; then
        pm="dnf install -y"
        pkgs="android-tools gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu gh python3 git curl coreutils"
    elif command -v pacman >/dev/null; then
        pm="pacman -S --needed --noconfirm"
        pkgs="android-tools aarch64-linux-gnu-gcc aarch64-linux-gnu-binutils github-cli python git curl coreutils"
    else
        die "no apt/dnf/pacman: install adb, an aarch64-linux-gnu GCC and binutils, gh, python3, git, curl yourself"
    fi
    echo "will run: $pm $pkgs"
    ask "Install these packages now?" || die "dependencies are required"
    command -v apt-get >/dev/null && apt-get update -qq
    # shellcheck disable=SC2086
    $pm $pkgs || die "package install failed (on older Ubuntu, 'gh' may need https://cli.github.com/)"
    for c in adb aarch64-linux-gnu-gcc gh; do command -v "$c" >/dev/null || die "$c still missing"; done
}

# ---------------------------------------------------------------- auth
stage_auth() {
    if ! as_user gh auth status >/dev/null 2>&1; then
        echo "Log in to GitHub (a browser or device code is needed once)."
        as_user gh auth login --hostname github.com --git-protocol https --web -s repo,workflow
    fi
    as_user gh auth setup-git >/dev/null 2>&1 || true
    GH_USER=$(as_user gh api user -q .login)
    echo "GitHub user: $GH_USER"
}

resolve_repo() {
    [ -n "${GH_USER:-}" ] || GH_USER=$(as_user gh api user -q .login)
    if [ -z "$REPO_SLUG" ]; then
        REPO_SLUG=$(as_user git remote get-url origin | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')
    fi
    [ -n "$REF" ] || REF=$(as_user git rev-parse --abbrev-ref HEAD)
    [ -n "$ROOT_REPO" ] || ROOT_REPO=$GH_USER/note7-ios-root
    echo "kernel: $REPO_SLUG @ $REF   root: $ROOT_REPO (private)"
}

# shellcheck source=tools/note7-install.sh
load_phone() {
    # shellcheck disable=SC1091
    . "$repo/tools/note7-install.sh"
    connect
}

# ---------------------------------------------------------------- backup
stage_backup() { load_phone; do_backup; }

# ---------------------------------------------------------------- Actions helpers
find_run() { # find_run REPO WORKFLOW BRANCH EVENT SINCE
    local n id
    for n in $(seq 1 30); do
        id=$(as_user gh run list -R "$1" -w "$2" -b "$3" -e "$4" -L 10 --json databaseId,createdAt \
            --jq "[.[]|select(.createdAt>=\"$5\")]|sort_by(.createdAt)|reverse|.[0].databaseId // empty" || true)
        [ -n "$id" ] && { echo "$id"; return; }
        sleep 4
    done
    die "no $2 run showed up in $1"
}

watch_run() { # watch_run REPO RUNID
    as_user gh run watch "$2" -R "$1" --exit-status --interval 60 ||
        die "run $2 failed: https://github.com/$1/actions/runs/$2 (annotations list the compile errors)"
}

# ---------------------------------------------------------------- kernel + root
start_kernel() {
    [ -f "$W/state/kernel.run" ] && [ "$FORCE" != kernel ] && return
    local local_sha remote_sha since
    local_sha=$(as_user git rev-parse HEAD)
    remote_sha=$(as_user git ls-remote origin "refs/heads/$REF" | awk '{print $1}')
    [ "$local_sha" = "$remote_sha" ] || die "$REF is not pushed (local $local_sha, remote ${remote_sha:-none}): git push first"
    since=$(date -u -d '30 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
    as_user gh workflow run xnu.yml -R "$REPO_SLUG" --ref "$REF" -f machine_config=HEROLTE ||
        die "could not start xnu.yml (it must exist on the default branch of $REPO_SLUG)"
    find_run "$REPO_SLUG" xnu.yml "$REF" workflow_dispatch "$since" > "$W/state/kernel.run"
    echo "kernel build: https://github.com/$REPO_SLUG/actions/runs/$(cat "$W/state/kernel.run")"
}

start_root() {
    [ -f "$W/root/root.img.gz.part00" ] && [ "$FORCE" != root ] && return
    [ -f "$W/state/root.run" ] && [ "$FORCE" != root ] && return
    local private
    if private=$(as_user gh repo view "$ROOT_REPO" --json isPrivate -q .isPrivate 2>/dev/null); then
        [ "$private" = true ] || die "$ROOT_REPO is public; the iOS root must stay in a private repo"
    else
        echo "$ROOT_REPO does not exist. The iOS root is built there from Apple's IPSW."
        echo "Private repos bill macOS minutes at 10x; the job may run for hours."
        ask "Create private repo $ROOT_REPO?" || die "need a private repo for the root build"
        as_user gh repo create "$ROOT_REPO" --private --description "iOS root build for the Note 7 port (private: contains Apple software)"
    fi
    local since
    since=$(date -u -d '30 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
    echo "pushing this tree to $ROOT_REPO (branch ios-root-build) to start the build"
    # One-commit snapshot of the committed tree: works from shallow clones and
    # sends no history. Uncommitted changes are not included.
    local snap
    snap=$(as_user env GIT_AUTHOR_NAME=install GIT_AUTHOR_EMAIL=install@localhost \
        GIT_COMMITTER_NAME=install GIT_COMMITTER_EMAIL=install@localhost \
        git commit-tree 'HEAD^{tree}' -m "snapshot for the iOS root build")
    as_user git push --force "https://github.com/$ROOT_REPO.git" "+$snap:refs/heads/ios-root-build"
    find_run "$ROOT_REPO" ios-root.yml ios-root-build push "$since" > "$W/state/root.run"
    echo "root build: https://github.com/$ROOT_REPO/actions/runs/$(cat "$W/state/root.run")"
}

stage_kernel() {
    resolve_repo
    start_kernel
    watch_run "$REPO_SLUG" "$(cat "$W/state/kernel.run")"
    rm -rf "$W/kernel"; mkdir -p "$W/kernel"
    as_user gh run download "$(cat "$W/state/kernel.run")" -R "$REPO_SLUG" -n xnu-kernel -D "$W/kernel"
    [ -f "$W/kernel/kernel.development.herolte" ] || die "artifact has no kernel.development.herolte"
    (cd "$W/kernel" && grep ' kernel\.development\.herolte$' SHA256SUMS | sha256sum -c -) || die "kernel checksum mismatch"
}

stage_root() {
    resolve_repo
    if [ -f "$W/root/root.img.gz.part00" ] && [ "$FORCE" != root ]; then echo "root already downloaded"; return; fi
    local free
    free=$(df -BG --output=avail "$repo" | tail -1 | tr -dc 0-9)
    [ "$free" -ge 12 ] || die "need about 12 GB free here for the root download (have ${free} GB)"
    start_root
    watch_run "$ROOT_REPO" "$(cat "$W/state/root.run")"
    local tag
    tag=$(as_user gh release list -R "$ROOT_REPO" -L 1 --json tagName -q '.[0].tagName')
    [ -n "$tag" ] || die "no release in $ROOT_REPO"
    rm -rf "$W/root"; mkdir -p "$W/root"
    as_user gh release download "$tag" -R "$ROOT_REPO" -D "$W/root"
    (cd "$W/root" && sha256sum -c SHA256SUMS) || die "root image checksum mismatch"
    mkdir -p "$repo/research/ipsw-x"
    cp "$W/root/d22ap.adt" "$repo/research/ipsw-x/d22ap.adt"
    chown -R "$owner" "$W" "$repo/research" 2>/dev/null || true
}

# Both builds are started before either is waited on, so they run in parallel.
start_builds() {
    resolve_repo
    done_stage kernel || start_kernel
    done_stage root || start_root
}

# ---------------------------------------------------------------- build
bootargs() {
    local a="debug=0xc serial=3 cpus=$CPUS keepsyms=1 -enable_kprintf_spam -noprogress"
    a="$a rd=ufsroot0 ufsroot=USERDATA ufsrw=1 rootrw=1 cs_enforcement_disable=1"
    a="$a unentitled_ios_sim_launch=1 ignition_level=1 launchd_unsecure_cache=1"
    a="$a wdt=-1 -wdt_no_pmu wdt_test=no_user_checkin a5fb_keep_on=1 a5fb_noconsole=1 a5fb_perf=1 sweetfb_native=1"
    [ "$TOUCH_RESET" -eq 0 ] || a="$a gracelte_rstxfer=1"
    echo "$a${EXTRA:+ $EXTRA}"
}

stage_build() {
    load_phone
    [ -s "$BACKUP_DIR/BOOT.img" ] || die "no BOOT backup: run the backup stage"
    [ -f "$W/kernel/kernel.development.herolte" ] || die "no kernel: run the kernel stage"
    [ -f "$repo/research/ipsw-x/d22ap.adt" ] || die "no d22ap.adt: run the root stage"
    mkdir -p "$W/out"
    say "loader"
    CROSS=aarch64-linux-gnu- sh "$repo/shim/herolte/build.sh"
    say "device tree and payload"
    python3 "$repo/tools/mkadt_herolte.py" "$W/out/gracelte.adt" --bank2 --bank2-mb 1024 --board gracelte
    python3 "$repo/tools/mkpayload.py" "$W/kernel/kernel.development.herolte" "$W/out/gracelte.adt" \
        "$W/out/payload.bin" --cmdline "$(bootargs)"
    say "BOOT images from your stock BOOT (size limit $BOOT_SIZE)"
    rm -f "$W/out/probe-boot.img" "$W/out/xnu-boot.img"
    python3 "$repo/tools/herolte-pack-boot.py" pack "$BACKUP_DIR/BOOT.img" \
        "$repo/shim/herolte/out/probe.Image" "$W/out/probe-boot.img" --partition-size "$BOOT_SIZE"
    python3 "$repo/tools/herolte-pack-boot.py" pack "$BACKUP_DIR/BOOT.img" \
        "$repo/shim/herolte/out/xnu_boot.Image" "$W/out/xnu-boot.img" \
        --append "$W/out/payload.bin" --partition-size "$BOOT_SIZE"
    chown -R "$owner" "$W" "$repo/shim/herolte/out" 2>/dev/null || true
}

# ---------------------------------------------------------------- consent
authorize() {
    cat <<E

This will, on the phone:
  1. write the PROBE image to BOOT, reboot, and ask you what the screen showed
  2. ERASE USERDATA (all Android data, photos, apps) and write the iOS root there
  3. write the XNU image to BOOT and reboot
Your stock BOOT and EFS are saved first (in $BACKUP_DIR) and BOOT is read back
after each write. Original Note 7 batteries were recalled: keep an eye on the
phone while it charges. Flashing BOOT trips Knox.
E
    local reply
    read -r -p "Type 'ERASE USERDATA' to allow all of this, or anything else to stop: " reply
    [ "$reply" = "ERASE USERDATA" ] || die "not authorised, nothing written"
    PREAUTH="yes,ERASE USERDATA"
    export PREAUTH
}

# ---------------------------------------------------------------- probe, flash
stage_probe() {
    load_phone
    authorize
    write_boot "$W/out/probe-boot.img"
    "$ADB" -s "$SERIAL" reboot
    echo "Probe running: expect white text over the logo and a 60 s countdown, then TWRP."
    wait_recovery 420
    echo
    echo "Did the probe show white text over the Samsung logo? (MIDR should read 0x410fd034)"
    ask "Text appeared" || die "no text: the framebuffer or load addresses differ from the S7. Stopping; see docs/gracelte-bringup.md, step 2."
}

stage_flash() {
    load_phone
    [ -n "${PREAUTH:-}" ] || authorize
    do_flash_root "$W"/root/root.img.gz.part*
    write_boot "$W/out/xnu-boot.img"
    say "done. Rebooting into XNU; the first boot takes several minutes on the Apple logo."
    "$ADB" -s "$SERIAL" reboot
    echo "Logs afterwards: boot TWRP (Power+Vol Up+Home) and run: sudo tools/note7-install.sh logs"
}

# ---------------------------------------------------------------- driver
run_stage() {
    local s=$1
    want "$s" || return 0
    if [ -z "$ONLY" ] && done_stage "$s"; then echo "[skip] $s (done; --force $s to redo)"; return 0; fi
    if [ "$s" = probe ] && [ "$SKIP_PROBE" -eq 1 ]; then echo "[skip] probe"; return 0; fi
    say "stage: $s"
    "stage_$s"
    mark "$s"
}

case " $STAGES " in *" ${ONLY:-deps} "*) ;; *) die "unknown stage '$ONLY'" ;; esac

run_stage deps
run_stage auth
run_stage backup
if [ -z "$ONLY" ]; then start_builds; fi
run_stage kernel
run_stage root
run_stage build
run_stage probe
run_stage flash
say "finished"
