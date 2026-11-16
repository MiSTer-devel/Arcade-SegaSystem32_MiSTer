# jt12 — YM2612/YM3438 FM synthesis core

Source: https://github.com/jotego/jt12
Commit: eaab7e1de6594982a299bc9101dc882384b85685 (2026-01-30)
License: GPL-3.0-or-later (see LICENSE; headers in each file)
Author: Jose Tejada (@topapate)

Subset used by the System 32 core: jt12.v top (YM2612 defaults) plus its
dependency tree, and jt10_adpcm_div.v (divider reused by
jt12_pcm_interpol). The ADPCM blocks proper are not elaborated
(use_adpcm=0).

**Thirteen files are modified (2026-11-13 to 11-15, each marked in its
header; ports unchanged but for one input added to `jt12_eg_pure.v` and
`jt12_eg_comb.v`, 2026-11-14).** Every other file is the upstream
commit's, byte for byte.

- `jt12_acc.v`: the upstream accumulator added every carrier of all six
  channels in one 12-bit sum. The YM3438 adds each channel's carriers in
  a nine-bit accumulator that saturates at every add, so a channel with
  two or more loud carriers clips at the rail; the modified file does
  that (bench `sim/jt12_acc`; docs/OPEN-QUESTIONS.md Q69).
  `jt12_single_acc.v` is no longer instantiated.
- `jt12_eg_final.v`, one line: the LFO's amplitude-modulation triangle
  was upside down. The chip's AM value is at its maximum when the LFO
  counter is 0, which is where the counter stays while the LFO is
  disabled, so an AM-enabled operator in a channel with AMS set is
  attenuated by the full depth while the LFO is off (bench
  `sim/jt12_egfinal`; Q70).
- `jt12_lfo.v`, the divider: the chip advances its LFO every 108 / 77 /
  71 / 67 / 62 / 44 / 8 / 5 samples, the upstream file one sample more
  (bench `sim/jt12_lfo`; Q70). Since 2026-11-14 the divider also leaves
  reset at 1, which puts the LFO's steps one sample earlier against the
  envelope timer, where the die-traced model has them.
- `jt12_top.v` (2026-11-14), the LFO value the phase generator reads:
  the chip latches the LFO's PM and AM values once a sample for every
  slot; upstream both units read the live value, which suits the
  envelope (tremolo) but puts vibrato a sample off for part of the slots.
  The phase generator now reads a copy taken 22 cycles after `zero`
  (`tools/fm/fm_lfo_probe.py`; Q70).
- `jt12_eg.v`, one signal: when the key goes off while SSG-EG has an
  operator's output inverted, the chip takes the inverted value as the
  level the release starts from. The upstream file dropped the inversion
  and kept the stored level, so the note jumped up or was cut
  (`tools/fm/fm_ssg_probe.py`; Q70).
- `jt12_mmr.v`, the frequency latches: the chip has one for A4-A6 and
  another for AC-AE (channel 3's operators), and takes A8-AA from bank 0
  only. The upstream file had one latch for both and took A8-AA from
  either bank. And the mode registers (21-2C) take their data only when
  address and data are both written on bank 0 (`tools/fm/
  fm_latch_probe.py`; Q70). And (2026-11-14) a 2A write leaves the DAC
  value's bit 0 alone, which only test register 2C bit 3 sets; the
  upstream file set it to 1 (`tools/fm/fm_dac_probe.py`; Q70). And
  (2026-11-15) the status busy bit: it shows from the second internal
  cycle after a data write for exactly 32 cycles, and a data write while
  it runs neither restarts nor extends it; the upstream file restarted
  it at every write (`sim/jt12_busy`, against Nuked-OPN2; Q70).
- `jt12_kon.v` and `jt12_mod.v`: on the chip operator 1 takes a key-on
  one sample after the other three operators of the same write. The
  upstream files keyed all four on together and made up for it on some
  modulation paths (operator 2, and operator 3 in algorithm 5) but not
  on others (operator 4 in algorithms 2 and 5, operator 3 in algorithm
  1), and operator 1 itself, audible in algorithm 7, sounded a sample
  early. Now the key state of an operator-1 slot is delayed one pass and
  every modulation tap is the chip's (bench `sim/jt12_kon`;
  `tools/fm/fm_alg_probe.py` and `fm_routing_probe.py`, settled against
  Nuked-OPN2; Q70).
- `jt12_eg_cnt.v`: the envelope timer is the chip's, twelve bits with
  FFF followed by 1 (4,095 states); the upstream file was a plain
  counter (Q70).
- `jt12_timers.v`: a timer's overflow sets its status flag only while
  its enable bit (register 27 bit 2 / 3) is set, and /IRQ is the two
  flags. This one is upstream's own change, taken by hand from commit
  `a91e893` (bench `sim/jt12_timers`; Q70).
- `jt12_eg_step.v` and `jt12_eg_pure.v`, when and by how much an
  envelope steps. The upstream file found the envelope timer's tick from
  a counter bit that depends on the operator's rate, so it took a stray
  step after about half of all rate changes (attack to decay, key-off,
  an SSG-EG restart); and it stepped decays two levels at a time on half
  as many ticks as the chip, which has one grid for attack and decay and
  steps a decay by one (bench `sim/jt12_egstep`; Q70). And on the ticks
  where an attack at rate 48 or more steps double, the chip shifts the
  level one place less; the upstream file doubled the single step
  (bench `sim/jt12_egpure`; Q70). And at rates 49 to 59 the ticks that
  take the doubled step are the chip's (its timer's low bits 0; 0 or 2;
  0, 1 or 2), where the upstream file had the same number of them on
  the other ticks (`tools/fm/fm_eghi_probe.py`; Q70).
- `jt12_eg_pure.v`, `jt12_eg_comb.v` and `jt12_eg.v` (2026-11-14):
  attack rates 62 and 63 zero the level only in the pass in which an
  attack begins (a key-on, or an SSG-EG repeat while the key is held).
  Written into an attack already under way they leave the level where
  it is until the key-off or a lower rate. The upstream file zeroed the
  level in every attack pass at those rates. `jt12_eg.v` makes the new
  signal (`fresh_I`) and `jt12_eg_comb.v` passes it on (bench
  `sim/jt12_egpure`; `tools/fm/fm_ar62_probe.py`; Q70).
- `jt12_eg.v` (2026-11-14), the envelope-off rule: outside an attack,
  unless an attack begins in the pass or SSG-EG holds the level up (key
  down in mode B or D), a level at 200h or beyond under SSG-EG, or at
  3F0h or beyond without it, goes to release at 3FFh at once. Upstream
  held SSG-EG's hold-at-the-bottom modes 9 and F at about -48 dB for as
  long as the key was down, and released SSG-EG notes from there at
  four levels a step (`tools/fm/fm_ssg_probe.py`; Q70).

Upstream was checked on 2026-11-13 at `eebba1d` (2026-11-09, 17 commits
on). For a YM3438 two of them change behaviour. `a91e893` reworks CSM
key-on (not taken: no game uses CSM), gates the timer flags with their
enable bits (taken, above) and converts the level at an SSG-EG key-off
(the change this core had made the same day, in `jt12_eg.v`). `1076fae`
drops every data write made on the other bank than its address; the
die-traced model drops only those to the mode registers, which is what
`jt12_mmr.v` does here. The rest is ADPCM, YM2203 and layout. Upstream
has none of the other changes listed above.

Verified in sim/s32_sound: the full 132,390-write MAME write-stream
lockstep passes with both jt12 instances live (status/busy/timer
behavior compatible with the game's polling loops).
