# iGalaxyNote7

**Apple's iOS 16 on the Samsung Galaxy Note 7 and Note FE (Exynos 8890).**

This repository ports [ios-sweet](https://github.com/dipa-studio/ios-sweet)
(Apple's open-source XNU `xnu-8796` plus the unmodified iPhone X iOS 16.7.16
userland, originally for the Redmi Note 10 Pro) to the Galaxy Note 7
(`gracelte`, SM-N930F) and Note FE (`gracerlte`, SM-N935F).

> **Status: untested on a Note 7.** No image from this repository has been
> built into a kernel here, flashed or booted on a Note 7 or Note FE. What is
> verified is that the XNU patch series applies to xnu-8796.141.3. Treat
> everything else as a plan built from source code, not a result. Experimental
> bring-up, not a usable phone OS; it erases USERDATA and replaces BOOT.

## How the port is built

ios-sweet's hardware layer is Qualcomm SM7150 only. The Note 7 shares its SoC
(Exynos 8890), bootloader family (Samsung S-Boot, no `fastboot boot`) and
UFS 2.0 storage with the Galaxy S7, which a community port had already taken
to the iOS home screen. That S7 port (`wardevsa/ios-a5xelte`, branch
`herolte`, itself a fork chain from ios-sweet and the Galaxy A5 2016 port) is
therefore the base here, with a thin Note 7 layer on top:

| Layer | Where |
| --- | --- |
| ios-sweet core: XNU patches 0001-0081, HFS, AMFI/sandbox stand-ins, HID, tools | `xnu/patches/`, `tools/` |
| Cortex-A53 / 4 KiB pages / GICv2 (A5XELTE donor) | patches 0082-0128 |
| Exynos 8890 board, UFS, SMP, touch, keys, battery, Mali-T880 (HEROLTE) | patches 0200-0249, `shim/herolte/` |
| **Note 7 / Note FE profile (this repository)** | patch 0300, `tools/mkadt_herolte.py --board gracelte`, `docs/gracelte-bringup.md` |

The kernel config stays `MACHINE_CONFIG=HEROLTE`; the Note 7 differences are
selected at run time. Why that is enough, what differs and what is still
unknown: **[docs/gracelte-bringup.md](docs/gracelte-bringup.md)**.

## One command

```sh
git clone https://github.com/Noah-Williams-Software/iGalaxyNote7 && cd iGalaxyNote7
git checkout claude/awesome-einstein-mit2sa      # the branch with the Note 7 layer, pushed to GitHub
sudo ./install.sh          # phone in TWRP on USB; resumes if interrupted
```

`install.sh` installs its dependencies (asks first), logs in to GitHub, backs up
BOOT and EFS, builds the kernel and the iOS root on GitHub's macOS runners in
**your** account (the root in a private repo it offers to create), downloads
both, builds the loader, device tree, payload and BOOT images locally, flashes a
probe image and asks what the screen showed, then writes USERDATA and the XNU
BOOT. You type `ERASE USERDATA` once, up front. `sudo ./install.sh --plan`
shows progress. Needs about 12 GB free and a few hours of macOS runner time
(private-repo macOS minutes are billed at 10x). **Never run on a real Note 7
yet**: the logic was exercised against simulated `gh` and `adb` only.

## Where to start

1. Read `docs/gracelte-bringup.md` (hardware comparison, steps, open questions).
2. Follow `docs/herolte-howto.md` with the Note 7 deltas from that document.
3. Run the stage-1 probe first (`shim/herolte/probe.*`): it settles the
   framebuffer address and S-Boot memory layout before anything else is tried.
4. Record every device result in `NOTE7_PROGRESS.md`.

## Useful tools

| Tool | What |
| --- | --- |
| `tools/check-patch-series.sh` | Replays the CI patch step on Linux (no compile) |
| `tools/mkadt_herolte.py --board gracelte` | Apple Device Tree for the Note 7 |
| `tools/mkpayload.py`, `tools/herolte-pack-boot.py` | Payload and BOOT image packers (host side, never flash) |
| `tools/herolte-log-pull.py` | Read the persistent kernel log from TWRP |
| `tools/validate-repo.py` | Patch numbering, Python and shell syntax |

## Provenance and licence

* ios-sweet is MIT licensed (`LICENSE`). Its original README, notes and agent
  instructions are kept in `docs/donors/`.
* The Exynos 8890 / S7 work comes from `wardevsa/ios-a5xelte` (branch
  `herolte`) and the Galaxy A5 2016 port `orhunnx/ios-a5xelte` before it. **That
  repository states no licence of its own**; it is imported here as the
  community derivative of an MIT project. Ask its author before redistributing
  this repository widely.
* Hardware facts for the Note 7 come from Samsung's kernel source as published
  in `LineageOS/android_kernel_samsung_universal8890` (GPL-2.0).
* Apple's software is not included and must not be committed. Build the root
  image in a private repository from Apple's own IPSW, as the S7 howto says.

## Safety

Unlocking the bootloader and flashing BOOT trips Knox. Back up `BOOT` and
`EFS` (IMEI) off the phone before anything else, and never write EFS,
RECOVERY or the bootloader partitions. Original Note 7 batteries were
recalled for fire risk: do not charge or leave a bring-up unit unattended with
an original battery, and stop if it swells.
