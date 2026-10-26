# Galaxy Note 7 / Note FE (Exynos 8890): port of XNU / iOS 16

Status: **not run on a Note 7.** Everything here is derived from sources and
from the working Galaxy S7 port; nothing has been booted, flashed or measured
on a Note 7 yet. Device evidence goes in `NOTE7_PROGRESS.md`, kept apart from
the source-derived claims below.

## Why this is a small delta

The Note 7 (`gracelte`, SM-N930F) and the Note FE (`gracerlte`, SM-N935F) use
the same Exynos 8890 as the Galaxy S7 (`herolte`) and the same S-Boot
bootloader family. The S7 already boots XNU to the iOS home screen (see
`docs/donors/HEROLTE_PROGRESS.md`), so this repository carries that port
whole: the `HEROLTE` machine config, the Exynos UFS driver, the loader, the
touch, key and battery drivers and the Mali-T880 work. The Note 7 profile is
the HEROLTE kernel plus the board differences below, selected at run time:

* `tools/mkadt_herolte.py --board gracelte`: adds `samsung,gracelte` to the
  ADT compatible list and names the firmware `gracelte-entry`.
* `xnu/patches/0300-gracelte-touch-reset-before-trans.patch`: boot-arg
  `gracelte_rstxfer=1` resets the touch HSI2C before every transfer.
* The build still uses `MACHINE_CONFIG=HEROLTE`; it produces
  `kernel.development.herolte`, which is the Note 7 kernel too.

Variants: **Exynos only** (SM-N930F/FD/K/L/S, SM-N935F/K/L/S). The Snapdragon 820
Note 7 and Note FE, sold in the regions where Samsung shipped Qualcomm, are a
different SoC and are out of scope.

## Hardware: Note 7 against S7 (from sources, unverified on the phone)

Source: `LineageOS/android_kernel_samsung_universal8890`, branch
`lineage-18.1` (commit `33ca16c`): `exynos8890-gracelte_common.dtsi`,
`exynos8890-herolte_common.dtsi`, `exynos8890-rmem.dtsi`, the per-revision
`gracelte_eur_open_*` and `gracelte_kor_all_*` board files.

| Item | Galaxy S7 (herolte) | Note 7 (gracelte) | Effect on the port |
| --- | --- | --- | --- |
| SoC, GIC-400, timer, UFS at `0x155a0000` | Exynos 8890 | same | none |
| DRAM bank 1 | `0x80000000` + `0x7e400000` | `0x80000000` + `0x7dc00000` | none: XNU uses the `0x90000000..0xb0000000` window or bank 2 |
| DRAM bank 2 | `0x880000000` + 2 GiB | same | none |
| Reserved memory (`exynos8890-rmem.dtsi`) | TIMA `0xb1000000`, ION from `0xc0000000`, modem `0xf0000000` | same file | the loader window stays free |
| Panel | 1440x2560 | 1440x2560 | none |
| S-Boot framebuffer | `0xe2a00000`, stride 5760 | **assumed the same, not in any source** | verify with the probe (stage 1) |
| Keys (pinctrl `0x10580000`) | power GPA2-4, vol- GPA0-4, vol+ GPA0-3, home GPA0-5 | identical | none |
| Touch controller | `sec_ts` at `0x48`, HSI2C `0x14e10000`, IRQ GPA1-0 | same, **plus** an Atmel mXT (`0x4a`) node on early boards | `0x48` first; Atmel is not supported |
| Touch bus quirk | none | `samsung,reset-before-trans` | `gracelte_rstxfer=1` (patch 0300) |
| Touch rails | `tsp_io` 1.85 V, `tsp_avdd` 3.3 V | same regulators | the S7 path (APM, S2MPS16 LDO32/33) is reused; unverified |
| PMIC | S2MPS16 at `0x66`, HSI2C `0x10550000` | same | none |
| Fuel gauge | MAX77854 on HSI2C1 (patch 0221) | MAX77854, but the battery DTS adds HSI2C13 (`0x14e40000`) | may not ACK: the battery service must fall back to its static value |
| Touch keys | Abov MC96FT16xx at `0x20` | Cypress touchkey at `0x20` | not used |
| Extras | fingerprint | fingerprint, iris, USB-C (S2MM005 CCIC) | none for the first boot |

Board revisions: the Note 7 BOOT carries several DTBs (`hw_rev` 0, 1, 2, ...,
11+ for EUR; 1 to 12+ for KOR). S-Boot picks one by revision and
`herolte-pack-boot.py` keeps the stock DTBH, so no choice is needed.

## Installer script

`sudo tools/note7-install.sh` (status, backup, flash-boot, flash-root, restore,
logs) automates the TWRP side over adb: it checks the model, backs up BOOT and
EFS with checksums on both ends, writes only BOOT and USERDATA after typed
confirmations, and reads BOOT back after writing. Tested against a simulated
phone only, not a real Note 7.

## Steps

Same stages as the S7 (`docs/herolte-bringup.md`, `docs/herolte-howto.md`).
Differences are marked.

1. **Back up first.** From TWRP: the stock `BOOT`, and `EFS` (IMEI) off the
   phone. Never write EFS, RECOVERY or the bootloader partitions. Only `BOOT`
   and, after confirmation, `USERDATA` are written. Unlocking the bootloader
   (OEM unlock) and flashing a custom BOOT trips Knox (warranty void).
2. **Probe (stage 1).** `shim/herolte/probe.*` prints EL, FDT and image
   addresses, MIDR/MPIDR, ID registers and the initrd range, then returns to
   TWRP. It is the first thing to run and **decides the assumptions above**:
   if no text appears over the logo, the framebuffer is not at `0xe2a00000`
   and `A5XELTE_FB_PA` in `pexpert/pexpert/arm64/A5XELTE.h` (patch 0200)
   needs the real value. Expect MIDR `0x410fd034` (Cortex-A53) and the S7's
   S-Boot placements (image `0x800bc000`, initrd `0x89000000`, FDT
   `0x8a000000`); any difference changes `shim/herolte/xnu_boot.c`.
3. **Pack.** Find the BOOT partition size on the Note 7 with
   `blockdev --getsize64 /dev/block/platform/155a0000.ufs/by-name/BOOT` and
   pass it as `--partition-size`; the S7 value (41943040) is not assumed.
4. **Kernel.** Run the `xnu` workflow (default `HEROLTE`). Before spending a
   macOS run, `NO_STAGING=1 sh tools/check-patch-series.sh XNU_SRC` checks
   that all patches apply to xnu-8796.141.3.
5. **ADT and payload.**
   ```sh
   python3 tools/mkadt_herolte.py gracelte.adt --bank2 --bank2-mb 1024 --board gracelte
   python3 tools/mkpayload.py kernel.development.herolte gracelte.adt payload.bin \
     --cmdline "debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress"
   ```
   Start with `cpus=1`. The root-mount boot-args are in `docs/herolte-howto.md`.
6. **Root.** The same iPhone X (D22AP) iOS 16.7.16 HFSX image as the S7, built
   in a **private** repository from Apple's IPSW. Check the Note 7's USERDATA size
   (`blockdev --getsize64` on its by-name entry); the S7's was 21566 MiB and
   the Note 7 is a 64 GB phone, so the 20480 MiB image should fit.
7. **Touch.** Try `herotouch` as on the S7; if `sec_ts` reads fail or hang,
   add `gracelte_rstxfer=1`. Rail power goes through the APM as on the S7
   (`herotouchslow=1` pauses before each risky step so the log shows how far it got).

## Open questions, in the order they will bite

1. Framebuffer address, S-Boot memory placements, BOOT size (probe).
2. Whether the APM-mediated touch power path works on the Note 7 PMIC wiring.
3. Whether the touch controller is `sec_ts` (final retail units) or the Atmel mXT.
4. Fuel gauge bus, and whether `SweetBattery` degrades cleanly without it.
5. The S7's RAM ceiling (1 GiB of bank 2 stable, 1.5 GiB and up panics) is
   unexplained and may or may not repeat; Note 7 has the same 4 GiB.

## Battery safety

Original Note 7 batteries are the recalled ones. Do not charge an original
unit unattended, do not run a bring-up phone with a swollen or damaged battery,
and prefer a Note FE or a replacement battery. This port adds no charging
control; whatever S-Boot and the PMIC do is all there is.
