derive_pll_clocks
derive_clock_uncertainty

# Core-specific constraints.
#
# Multicycle exceptions are claims about both the launch and the capture
# edge, so each one below is scoped to registers whose timing is known.
# Where two exceptions overlap, this Quartus 17.0 STA applies the LAST
# matching one in the file, so the order of the sections matters.

# ---- Mixer pixel pipeline: 2 clk_sys periods ------------------------------
# The mixer advances only on cen_mix, at most once every other clk_sys, so
# its priority-sort logic has two periods.
#
#   -from: only registers that launch on cen_mix edges: the pixel taps
#   (q_text, q_n0..q_n3, q_bm, spr_q), the palette taps (prda_r, prdb_r),
#   bf_line (loaded once per line in hblank, stable for the whole line) and
#   the mixer's own registers. Named exactly rather than as q_*: s32_video
#   has other q_-prefixed registers that must stay single-cycle.
#
#   -to: only the cen_mix-paced stages (s0_*, s1_*, rgb*). The mixer's
#   register-write path and the cen_mix enable network are single-cycle and
#   must not be covered: a '-to' exception without '-from' would also waive
#   each register's clock-enable path.
#
# There is no '-from mixer -to outside' exception: the mixer's outputs
# feed registers in s32_video that capture on the very next clk_sys edge.
set_multicycle_path -setup 2 \
  -from [get_registers {*|s32_video:u_vid|spr_q* *|s32_video:u_vid|prda_r* *|s32_video:u_vid|prdb_r* *|s32_video:u_vid|bf_line* *|s32_video:u_vid|q_text* *|s32_video:u_vid|q_n0* *|s32_video:u_vid|q_n1* *|s32_video:u_vid|q_n2* *|s32_video:u_vid|q_n3* *|s32_video:u_vid|q_bm* *|s32_mixer:u_mix|*}] \
  -to   [get_registers {*|s32_mixer:u_mix|s0_* *|s32_mixer:u_mix|s1_* *|s32_mixer:u_mix|rgb*}]
set_multicycle_path -hold 1 \
  -from [get_registers {*|s32_video:u_vid|spr_q* *|s32_video:u_vid|prda_r* *|s32_video:u_vid|prdb_r* *|s32_video:u_vid|bf_line* *|s32_video:u_vid|q_text* *|s32_video:u_vid|q_n0* *|s32_video:u_vid|q_n1* *|s32_video:u_vid|q_n2* *|s32_video:u_vid|q_n3* *|s32_video:u_vid|q_bm* *|s32_mixer:u_mix|*}] \
  -to   [get_registers {*|s32_mixer:u_mix|s0_* *|s32_mixer:u_mix|s1_* *|s32_mixer:u_mix|rgb*}]

# ---- V60 CPU: 2 clk_sys periods --------------------------------------------
# The V60 core steps on cen16 (clk_sys / 4 = the real 16.108 MHz CPU clock)
# and is frozen between steps. A slot is 4 clk_sys, or 3 clk_sys while the
# board build repays SDRAM wait debt (s32_sys.sv wd_rec: one double step
# per slot, as its last step, since 2026-10-31); the clock never makes a
# 2-clk slot. The bus unit (v60_bcu) registers everything the rest of the
# machine sees.
#
# Setup 2 claims two periods, which a 3-clk slot still gives to an input
# that settles one clk after a step (the prefetch queue re-bases then, so
# its window/count -> u_v60 paths, ~28 ns in the seed-11 build, have
# exactly the two periods claimed). Do not relax it further, and do not let
# the slot shrink below 3 clk: the prefetch unit's paths are bounded by the
# cen16 spacing at which its state is consumed, not by the nominal freeze,
# and a looser claim lets unsettled fetch data be latched.
#
# INTO the core the claim is scoped to the two units that keep it: the bus
# unit and the prefetch unit (2026-11-10). It used to be a bare
# `-to u_v60`, which also gave two periods to everything else the core
# samples, and none of it has them:
#   - cen16 itself, the step enable of every core register (through
#     wait_hold): it rises one clk before the step it enables;
#   - the interrupt controller's pending/mask registers (irq, irq_vector):
#     a request can be raised on any clk, the one before a step included;
#   - the reset counter in the shell (core_hold -> rst).
# Those are the only outside startpoints (STA: every register that is not
# u_v60, u_bcu or u_pfu, -to u_v60). They are plain single-cycle paths
# again. Checked at one period on the netlists built under the old rule they
# all met it (Arcade-S32_20261109 seed 5: worst +1.565 ns), so no released
# build was wrong; nothing made the fitter keep it so (board-design.md 9.3
# item 8). Do not put the bare -to back, and scope any new input the same
# way: prove its source holds still for two periods, or leave it out.
set_multicycle_path -setup 2 -from [get_registers {*|v60:u_v60|*}]
set_multicycle_path -hold 1 -from [get_registers {*|v60:u_v60|*}]
set_multicycle_path -setup 2 -from [get_registers {*|v60_bcu:u_bcu|* *|v60_pfu:u_pfu|*}] -to [get_registers {*|v60:u_v60|*}]
set_multicycle_path -hold 1 -from [get_registers {*|v60_bcu:u_bcu|* *|v60_pfu:u_pfu|*}] -to [get_registers {*|v60:u_v60|*}]

# ---- inside that block: what does NOT have two periods ----------------------
# ORDER MATTERS: these must come after the four u_v60 rules above (this
# TimeQuest takes the last matching assignment), and they put back the one
# period those blankets took away from logic that does not wait for cen16
# (1, 2) or that can be launched the clk before a step (3).
# Added 2026-11-09; before that both sets were checked at two periods. They
# met one in every release netlist looked at (Arcade-S32_20261109 seed 5:
# multiplier 14.52 ns, pc to the queue 11.99 ns, against 15.52), so nothing
# on silicon was wrong, but nothing made the fitter keep it so.
#
# 1. The multiply/divide unit iterates once per clk_sys, and takes md_start
#    (a one-clk strobe) and its operands the clk after the core's step. All
#    paths INTO its registers are single-cycle. Its outputs go back to the
#    core, which samples them at a later step: those keep the two periods.
set_multicycle_path -setup 1 -to [get_registers {*|v60:u_v60|v60_muldiv:u_md|*}]
set_multicycle_path -hold 0 -to [get_registers {*|v60:u_v60|v60_muldiv:u_md|*}]
# 2. The prefetch unit follows pc on every clk_sys: the clk after a step it
#    drains or flushes (base/head/count/flushed) on the new pc and on pc_jump,
#    the core's one-clk control-transfer strobe, and its long-instruction
#    snapshot (win_q/cnt_q) may load on that clk too. bufv and inflight are
#    left at two periods: they change only with a bus-unit grant or done,
#    which v60_bcu gates with cen16, so the clk after a step they hold
#    whatever the pc terms are doing.
set_multicycle_path -setup 1 \
  -from [get_registers {*|v60:u_v60|pc[*] *|v60:u_v60|pc_jump}] \
  -to   [get_registers {*|v60_pfu:u_pfu|base[*] *|v60_pfu:u_pfu|head[*] *|v60_pfu:u_pfu|count[*] *|v60_pfu:u_pfu|flushed *|v60_pfu:u_pfu|win_q[*] *|v60_pfu:u_pfu|cnt_q[*]}]
set_multicycle_path -hold 0 \
  -from [get_registers {*|v60:u_v60|pc[*] *|v60:u_v60|pc_jump}] \
  -to   [get_registers {*|v60_pfu:u_pfu|base[*] *|v60_pfu:u_pfu|head[*] *|v60_pfu:u_pfu|count[*] *|v60_pfu:u_pfu|flushed *|v60_pfu:u_pfu|win_q[*] *|v60_pfu:u_pfu|cnt_q[*]}]
# 3. The bus unit's completion (2026-11-10). v60_bcu loads done_q, and
#    c_rdata on a read, on whatever clk the fabric finishes, and releases the
#    core in the first cen16-high cycle of the last T3 that sees done_q. When
#    the fabric finishes on the very clk cen16 rises, the core steps ONE clk
#    after they loaded, and a read's data goes straight into that step
#    (flags, the string compares, the write-back value). The sim/s32_board
#    CRAGE monitor counts it on the ga2 boot: 70 of 53,568 data reads and
#    15,766 of 135,420 writes are released at that age. These were under the
#    two-period blanket; at one period the read data missed on both netlists
#    looked at (Arcade-S32_20261109 seed 5: three flags_wdata bits and two
#    multiplier enables, worst -1.09 ns at the slow corner), so this one is
#    a real gap that earlier releases carried (board-design.md 9.3 item 8).
#    The unit's other registers the core reads (run, tst, ci, n_cyc) change
#    only on a step edge and keep the two periods.
set_multicycle_path -setup 1 \
  -from [get_registers {*|v60_bcu:u_bcu|c_rdata[*] *|v60_bcu:u_bcu|done_q}] \
  -to   [get_registers {*|v60:u_v60|*}]
set_multicycle_path -hold 0 \
  -from [get_registers {*|v60_bcu:u_bcu|c_rdata[*] *|v60_bcu:u_bcu|done_q}] \
  -to   [get_registers {*|v60:u_v60|*}]

# ---- V60 wait-debt stall sample: 2 periods ----------------------------------
# s32_sys wd_stall_q samples `bcu_busy || fetch_hold` only on cen16, exactly
# as the core samples the same signals (fetch_hold is the prefetch window
# through the length decoder, ~20 ns). Same spacing argument as the u_v60
# block above: the source settles one clk after a step and the next step is
# three clk or more later. Scoped to the prefetch unit's registers: the
# window/count path is the two-period one; the other startpoint in that cone
# is the core's pc (the length decoder itself is combinational), covered by
# the -from u_v60 rule above; the cen16 and bus-unit terms into wd_stall_q
# are genuinely single-cycle (~9-10 ns) and stay checked at one period
# (seed-11 release netlist core0p143: pfu 24.76 ns at two periods, slack
# +5.54; cen16 8.03 ns and bcu 6.24 ns at one, +7.19 / +8.98). (Added
# 2026-10-31: fed in without this register the
# path ended at the cen16 register at -7 ns; first written -to-only,
# scoped the same day.)
set_multicycle_path -setup 2 -from [get_registers {*|v60_pfu:u_pfu|*}] -to [get_registers {*|s32_sys:u_sys|wd_stall_q}]
set_multicycle_path -hold 1 -from [get_registers {*|v60_pfu:u_pfu|*}] -to [get_registers {*|s32_sys:u_sys|wd_stall_q}]

# ---- V60 prefetch long-instruction hint: 2 periods ------------------------
# v60_pfu decodes its "instruction longer than 16 bytes" hint (long_q) from a
# window snapshot (win_q, cnt_q). Snapshot and hint load on the same
# alternate clocks (hph), so long_q captures win_q/cnt_q two periods after
# they were launched: true by construction, not by observation. -from and
# -to both: the hph enable path and the window -> win_q path stay
# single-cycle (v60_pfu.sv header; docs/slipstrm-bringup.md §5.1).
set_multicycle_path -setup 2 \
  -from [get_registers {*|v60_pfu:u_pfu|win_q[*] *|v60_pfu:u_pfu|cnt_q[*]}] \
  -to   [get_registers {*|v60_pfu:u_pfu|long_q}]
set_multicycle_path -hold 1 \
  -from [get_registers {*|v60_pfu:u_pfu|win_q[*] *|v60_pfu:u_pfu|cnt_q[*]}] \
  -to   [get_registers {*|v60_pfu:u_pfu|long_q}]

# No exception covers the bus fabric. The core never reaches s32_v60bus
# directly (the bus unit sits between them), and the decode from the bus
# unit's registered address is a genuine single-cycle path.

# ---- Video register shadow: 2 periods --------------------------------------
# CPU-written video configuration, changed by the games during vblank. A
# write in the middle of a line can tear one sample, as on the real board.
set_multicycle_path -setup 2 -from [get_registers {*|s32_video:u_vid|vregs*}]
set_multicycle_path -hold 1 -from [get_registers {*|s32_video:u_vid|vregs*}]

# ---- Mixer layer sort: 4 periods -------------------------------------------
# The layer-priority sort is recomputed from slowly changing configuration
# into free-running registers; its 42-stage compare network gets 4 periods.
# This block must stay AFTER the video register rule above: the last
# matching exception wins, and the earlier rule would otherwise clamp the
# vregs -> sorted paths to 2 periods. The sorted registers have no reset or
# enable, so these are their only sources.
set_multicycle_path -setup 4 \
  -from [get_registers {*|s32_video:u_vid|vregs* *|s32_mixer:u_mix|*}] \
  -to   [get_registers {*|s32_mixer:u_mix|sorted?*}]
set_multicycle_path -hold 3 \
  -from [get_registers {*|s32_video:u_vid|vregs* *|s32_mixer:u_mix|*}] \
  -to   [get_registers {*|s32_mixer:u_mix|sorted?*}]

# ---- SDRAM I/O timing (MT48LC16M16 class, CAS latency 2, 64.43 MHz) ------
# SDRAM_CLK is PLL outclk_1 (-3879 ps phase) wired straight to the pin.
# Commands and write data are sampled by the chip on its next edge; read data
# is captured in the SDRAM_DQ I/O-cell register (s32_sdram dq_in_q) on the
# second clk_sys edge after the chip drives it. Delays are datasheet values
# (read tAC 6.0 / tOH 2.5 ns, write tIS 1.5 / tIH 0.8 ns). If the PLL counter
# name below ever stops matching, Quartus only warns and these I/O paths go
# unconstrained. [] in a get_pins filter is a Tcl character class, so literal
# brackets are written as ? wildcards (general?1?).
create_generated_clock -name SDRAM_CLK \
  -source [get_pins -compatibility_mode {*|pll|pll_inst|altera_pll_i|general?1?.gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {SDRAM_CLK}]

# Read capture: chip data access tAC = 6.0 ns (max), output hold tOH = 2.5 ns
set_input_delay  -clock SDRAM_CLK -max 6.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]

# Command/address/data launch: chip input setup tIS = 1.5, hold tIH = 0.8
set_output_delay -clock SDRAM_CLK -max  1.5 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -min -0.8 [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]

# Read capture: SDRAM_CLK edges sit 3.879 ns before clk_sys edges, so by
# default STA would pick a capture edge only 3.879 ns after launch. The I/O
# register really captures on the next clk_sys edge. The output direction's
# default (to the chip's next edge) is already correct.
set_multicycle_path -setup -end 2 \
  -from [get_clocks {SDRAM_CLK}] \
  -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}]
set_multicycle_path -hold -end 1 \
  -from [get_clocks {SDRAM_CLK}] \
  -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general?0?.gpll~PLL_OUTPUT_COUNTER|divclk}]

# ---- CLK_VIDEO: the video PLL is asynchronous to everything (2026-11-06) ----
# pll_vid (rtl/pll_vid, GitHub issue #1) is a second PLL on the same 50 MHz
# pin, reconfigured at run time between 50 MHz and clk_sys's frequency. Its
# instance name does not match sys_top.sdc's core-PLL group
# (*|pll|pll_inst|...), so it is grouped here, alone: a single -group is
# asynchronous to every other clock. Every path between it and clk_sys is
# synchronized by construction: s32_vidout's Gray write pointer (two flops)
# and its dual-clock RAM, read at least MIN_OCC = 2 entries (16 video
# clocks) behind that pointer; vid_cfg_ok (CLK_50M) through two flops; and
# the CRT Adjust OSD fields, static settings sampled on the dot enable.
set_clock_groups -asynchronous \
  -group [get_clocks {*|pll_vid|pll_vid_inst|altera_pll_i|*|divclk}]
