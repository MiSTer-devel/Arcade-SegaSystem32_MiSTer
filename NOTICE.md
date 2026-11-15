# NOTICE — third-party components and attributions

This core is distributed under **GPL-3.0-or-later** (see `LICENSE`). It
includes the third-party components below. Each one keeps its original file
headers.

## Components compiled into the core

| Component | Author(s) | Licence | Location |
|---|---|---|---|
| MiSTer framework (`sys_top`, `hps_io`, `ascal`, `osd`, `video_freak`, …) | Till Harbaum, Alexey Melnikov (Sorgelig) and the MiSTer-devel contributors | GPL-2.0-or-later / GPL-3.0-or-later (per-file headers) | `sys/`: vendored unchanged from Template_MiSTer commit `3ea1134` (2026-08-26). 57 files; SHA-256 of all file contents concatenated in path order (`find sys -type f \| LC_ALL=C sort \| xargs cat \| sha256sum`): `8f3623f8af25cf7325c815fa7161d2434da47ebaac2138eca514ad04809c1970` |
| **jt12**, the YM2612/YM3438 FM synthesiser | Jose Tejada (jotego) | GPL-3.0-or-later | `rtl/sound/jt12/`: the subset this core uses, from github.com/jotego/jt12 commit `eaab7e1de6594982a299bc9101dc882384b85685`, with its `LICENSE` and a provenance `README.md`. Unchanged except thirteen files modified 2026-11-13 and 2026-11-14, each change described in the file's header: `jt12_acc.v` (the YM3438's nine-bit saturating channel accumulator), `jt12_eg_final.v` (the polarity of the LFO's amplitude modulation), `jt12_lfo.v` (the LFO's step period and its divider's phase after reset), `jt12_top.v` (the LFO value the phase generator reads), `jt12_eg.v` (the envelope level at a key-off under SSG-EG inversion, and the envelope-off rule), `jt12_mmr.v` (the two frequency latches, the bank a mode register takes its data from, and the DAC value's lowest bit), `jt12_eg_step.v` with `jt12_eg_pure.v` (which timer ticks step an envelope, and by how much), `jt12_eg_pure.v` with `jt12_eg_comb.v` and `jt12_eg.v` (attack rates 62 and 63 zero the level only as an attack begins), `jt12_timers.v` (the timer flags' enable bits, as in upstream jt12 commit `a91e893`), `jt12_kon.v` with `jt12_mod.v` (operator 1's key-on one sample after the other operators, and which operator-1 output each operator is modulated by) and `jt12_eg_cnt.v` (the envelope timer's 4,095 states) |
| **tv80**, the Z80 core | Guy Hutchison, based on Daniel Wallner's T80 | MIT-style (permission notice in each file header) | `rtl/sound/tv80/`. `tv80s.v` is modified: a clock-enable input replaces the constant enable, and the strobe registers advance on that enable; the changes are marked `S32` in the file |
| **CRT Adjust**, analog picture-geometry stage | Umberto Parisi (rmonic79) | GPL-3.0-or-later | `rtl/video/crt_adjust.sv`: from github.com/rmonic79/MiSTer-CRT-Adjust commit `c682de9`, with four marked adaptations listed in its header (line-buffer size parameter, no RAM initialiser, a sign-extension fix, a vertical-blank alignment parameter). `rtl/video/s32_crt_adjust.sv`, the glue around it, is original to this project |
| Intel PLL megafunction (50 MHz → 64.4318 MHz system clock and SDRAM clock) | Intel Corporation (generated IP) | Intel FPGA IP licence, as generated | `rtl/pll.v`, `rtl/pll.qip`, `rtl/pll/` |

All of these licences are compatible with distributing the combined work
under GPL-3.0-or-later. Everything else in `rtl/`, `S32.sv`, `S32.sdc`,
`S32.qsf` and `files.qip` is original to this project.

## Data taken from MAME

MAME (BSD-3-Clause; Aaron Giles and the MAME contributors) served as the
functional reference and produced every simulation comparison. No MAME
source is compiled into this core. Two pieces of data in the RTL come from
MAME's `segas32` driver: the protection module's opcode-decryption table and
its ROM address-line scramble (`rtl/sys32/s32_v25.sv`, from
`segas32_m.cpp`), both of which describe the original module.

## Trademarks and content

This repository contains no ROM data, no artwork, no manuals and no schematic
scans. *Golden Axe*, *Holosseum*, *Super Visual Football*, *Super Visual
Soccer*, *Arabian Fight*, *Burning Rival*, *Dark Edge*, *SegaSonic The Hedgehog*,
*Sonic the Hedgehog*, *Rad Mobile*, *Rad Rally*, *F1 Super Lap*, *F1 Exhaust Note*,
*Air Rescue* and *System 32* are trademarks of
SEGA; *F1* is a trademark of Formula One Licensing B.V.; *Dragon Ball Z*
is a trademark of Bird Studio/Shueisha and Toei Animation; *Jurassic
Park* is a trademark of Universal City Studios and Amblin Entertainment;
*J.League* is a trademark of the Japan Professional Football League;
*Spider-Man* is a trademark of Marvel; *Slip Stream* is a trademark of
Capcom; *Alien 3* is a trademark of 20th Century Studios. This is an unaffiliated
hardware-preservation project. Use it only with ROMs you are legally entitled
to.
