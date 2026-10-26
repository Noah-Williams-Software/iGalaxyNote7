# Galaxy Note 7 / Note FE: progress log

Three kinds of entry, never mixed: **source** (derived from code or DTS),
**built** (a build or script ran), **observed** (seen on a Note 7).

## 2026-10-26

- **source** Exynos 8890 Note 7 (`gracelte`) board files compared with the S7
  (`herolte`) in `LineageOS/android_kernel_samsung_universal8890` @ `33ca16c`.
  Same SoC, keys, PMIC, reserved memory, DRAM bank 2 and touch bus; differences
  are in `docs/gracelte-bringup.md`: bank 1 size, `samsung,reset-before-trans`
  on the touch HSI2C, a second touch node (Atmel mXT at `0x4a`), the
  battery bus, the touch-key chip.
- **source** No Note 7 board exists in `ivoszbg/uniLoader`, so the S-Boot
  framebuffer address `0xe2a00000` is an assumption inherited from the S7.
- **built** S7 donor tree imported (`wardevsa/ios-a5xelte`, `herolte`
  branch). `tools/check-patch-series.sh` with `NO_STAGING=1` on pristine
  `apple-oss-distributions/xnu` tag `xnu-8796.141.3`: 171 patches applied
  including new `0300`; 2 skipped (`0031`, `0041`) only because they patch the
  HFS sources that the staging script downloads and this run did not execute.
  `tools/validate-repo.py` passes (patch numbers unique, 26 Python and 12
  shell scripts compile).
- **built** `tools/mkadt_herolte.py --board gracelte` produces an ADT without
  the D22AP `/product` node (needs `research/ipsw-x/d22ap.adt`, not present).
- **not done** No kernel compile (needs the macOS workflow), so patch 0300 is
  not compiled. No image built, no device run.

## 2026-10-26 (later)

- **built** `tools/note7-install.sh` (TWRP/adb side) and `install.sh` (full
  pipeline) tested against a simulated phone (file-backed partitions, a stock
  BOOT with a DTBH 8890 header) and a fake `gh`: dependencies, auth, backup,
  kernel and root stages, resume, the shim built with Ubuntu's
  `gcc-aarch64-linux-gnu` 13 (`-Werror` clean), ADT, BOOT packing, probe gate,
  USERDATA write via `herolte-flash-root.py`, XNU BOOT write with read-back.
  The payload packer was stubbed (it needs a real Mach-O kernel).
- **not done** No real GitHub Actions run, no real Note 7, no real adb/TWRP.
  The `ios-root` workflow has only ever run for the S7; macOS minutes needed.

### Next

1. Run the `xnu` workflow on this repository (default `HEROLTE`) and fix any
   compile error in 0300.
2. Back up BOOT and EFS from a Note 7 in TWRP, build the stage-1 probe, pack it
   with `herolte-pack-boot.py`, flash BOOT, and record exactly what the screen
   shows: framebuffer, MIDR/MPIDR, addresses, initrd range, BOOT size.
