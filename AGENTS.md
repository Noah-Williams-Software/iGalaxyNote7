# Working on iGalaxyNote7 (Galaxy Note 7 / Note FE, Exynos 8890)

- Read `README.md`, then `docs/gracelte-bringup.md` and `NOTE7_PROGRESS.md`.
  The S7 donor log is `docs/donors/HEROLTE_PROGRESS.md`; ios-sweet's original
  notes are `docs/donors/ios-sweet-NOTES.md` (Redmi Note 10 Pro, not this phone).
- Keep three kinds of claim apart in every note: **source-derived** (a DTS or
  driver says so), **built** (a CI run or `tools/check-patch-series.sh`
  succeeded) and **observed** (seen on a Note 7: photo, log, probe output).
  Today only the second kind exists, for patch application. Do not write
  "works" for anything that was not observed on the phone.
- The kernel is built on GitHub's macOS runners (`.github/workflows/xnu.yml`,
  `MACHINE_CONFIG=HEROLTE`). Before using a run, replay the patch step:
  `NO_STAGING=1 sh tools/check-patch-series.sh /path/to/xnu-8796.141.3`
  (the staging scripts download and run third-party code; read them before
  running without `NO_STAGING`).
- Device writes: only BOOT, and USERDATA after the user confirms. Never write
  EFS, RECOVERY or the bootloader partitions. Keep the stock BOOT and an EFS
  backup off the phone and out of git.
- Keep device dumps, serial numbers, IMEI data and downloaded Apple artifacts
  out of git; `.gitignore` covers the usual directories.
