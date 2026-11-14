/*  This file is part of JT12.

    JT12 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT12 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT12.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 29-10-2018

    
    Modified 2026-11-13 for the Sega System 32 core (RetroShrimp), three
    things, all marked below. The ports are the original ones.

    1. How the module finds the envelope timer's tick (cnt_lsb, sum_up and
       low_zero at the end of the file).

    The chip steps an envelope as a function of its envelope timer and the
    operator's rate at that moment, once per timer tick. The original file
    found the tick by comparing one bit of the counter (the lowest bit of
    the slice the rate selects) with the value the operator stored on its
    last pass. Which bit that is depends on the rate, so on the pass after
    a rate change (attack to decay, decay to the sustain rate, key-off, an
    SSG-EG restart) it compared a bit with the stored value of another
    one, and about half the time took a step that no tick had asked for:
    every envelope ran a step or two ahead after each change of rate, and
    an SSG-EG sawtooth repeated 1.6 % too fast.

    Now the operator stores a bit of the counter that changes at every
    tick whatever the rate (bit 12, jt12_eg_cnt.v), and a step is taken on the first pass after a
    tick if the counter's bits below the selected slice are all 0. At a
    constant rate this is the same as before, pass for pass.

    Reference: Nuked-OPN2 ym3438.c, OPN2_EnvelopePrepare (traced from the
    YM3438 die): eg_inc is computed from the rate, eg_shift_lock and
    eg_timer_low_lock alone, and only while eg_quotient == 2; nothing is
    kept per operator.

    2. Which ticks step a decay, sustain or release (mux_sel and the step
       table for rates under 48). The chip uses one timer grid for attack
       and decay alike: with r4 = rate[5:2], a tick steps the envelope
       when the lowest set bit of its 12-bit timer is bit 11-r4, or bit
       12-r4 if rate bit 1 is set, or bit 13-r4 if rate bit 0 is set, and
       a decay step adds 1 to the level (4 under SSG-EG). The original
       file put decays on the grid one bit higher (half as many ticks) and
       added 2 (jt12_eg_pure.v): the same slope in steps twice as coarse
       and up to a tick late. It also had a pattern of its own for rates
       0-3 and, for rate[1:0] = 1, the extra step at slice value 6 where
       the chip has it at 4.

       References: Nuked-OPN2 OPN2_EnvelopePrepare (sum = (rate >> 2) +
       eg_shift_lock; 12: inc 1; 13: inc rate bit 1; 14: inc rate bit 0)
       and OPN2_EnvelopeADSR (inc = 1 << (eg_inc - 1), shifted by 2 under
       SSG-EG); MAME ymfm_fm.ipp attenuation_increment (rows 8-47:
       10101010, 10111010, 11101110, 11111110 over timer bits 13-r4 to
       11-r4) and fm_operator::clock_envelope.

    3. Which ticks take the larger step at rates 48 and above. Every tick
       steps there, and by the rate's two low bits one, two or three ticks
       in four take a doubled step. The chip doubles on the ticks where
       its timer's two low bits are 0 (rate bits 01), 0 or 2 (10), or 0, 1
       or 2 (11). The original file had the same number of doubled steps
       on the other ticks (3; 1 or 3; 1, 2 or 3), which is MAME's table
       (ymfm attenuation_increment, rows 48-59) but not the die's.

       Reference: Nuked-OPN2 eg_stephi and OPN2_EnvelopePrepare (inc =
       eg_stephi[rate & 3][eg_timer_low_lock] + (rate >> 2) - 11, the two
       low timer bits latched with eg_shift_lock). Found by an independent
       review of items 1 and 2, then measured: Nuked-OPN2 run on
       tools/fm/fm_eghi_probe.py's notes was equal to this module at rates
       44-48, 52 and 56 and at none of 49-51, 53-55, 57-59; after the
       change at all sixteen.
    Bench: sim/jt12_egstep. docs/OPEN-QUESTIONS.md Q70.

    */

module jt12_eg_step(
    input           attack,
    input [ 4:0]    base_rate,
    input [ 4:0]    keycode,
    input [14:0]    eg_cnt,
    input           cnt_in,
    input [ 1:0]    ks,
    output          cnt_lsb,
    output       reg step,
    output reg [5:0] rate,
    output reg      sum_up
);

reg     [6:0]   pre_rate;

always @(*) begin : pre_rate_calc
    if( base_rate == 5'd0 )
        pre_rate = 7'd0;
    else
        case( ks )
            2'd3:   pre_rate = { base_rate, 1'b0 } + { 1'b0, keycode };
            2'd2:   pre_rate = { base_rate, 1'b0 } + { 2'b0, keycode[4:1] };
            2'd1:   pre_rate = { base_rate, 1'b0 } + { 3'b0, keycode[4:2] };
            2'd0:   pre_rate = { base_rate, 1'b0 } + { 4'b0, keycode[4:3] };
        endcase
end

always @(*)
    rate = pre_rate[6] ? 6'd63 : pre_rate[5:0];

reg [2:0] cnt;

// Modified 2026-11-13 (see the header, 2): one grid for attack and decay,
// over the chip's 12-bit timer (the counter's bits above 11 do not count).
reg [4:0] mux_sel;
always @(*) begin
    mux_sel = {1'b0,rate[5:2]} + 5'd1;
end // always @(*)

always @(*) 
    case( mux_sel )
        5'h1: cnt = { 2'b0, eg_cnt[11] };
        5'h2: cnt = { 1'b0, eg_cnt[11:10] };
        5'h3: cnt = eg_cnt[11: 9];
        5'h4: cnt = eg_cnt[10: 8];
        5'h5: cnt = eg_cnt[ 9: 7];
        5'h6: cnt = eg_cnt[ 8: 6];
        5'h7: cnt = eg_cnt[ 7: 5];
        5'h8: cnt = eg_cnt[ 6: 4];
        5'h9: cnt = eg_cnt[ 5: 3];
        5'ha: cnt = eg_cnt[ 4: 2];
        5'hb: cnt = eg_cnt[ 3: 1];
        default: cnt = eg_cnt[ 2: 0];
    endcase

////////////////////////////////
reg [7:0] step_idx;

always @(*) begin : rate_step
    if( rate[5:4]==2'b11 ) begin // 0 means 1x, 1 means 2x
        if( rate[5:2]==4'hf && attack)
            step_idx = 8'b11111111; // Maximum attack speed, rates 60&61
        else
        case( rate[1:0] )
            2'd0: step_idx = 8'b00000000;
            // Modified 2026-11-13 (see the header, 3): the chip doubles
            // on timer values 0 / 0,2 / 0,1,2 (mod 4), not 3 / 1,3 / 1,2,3
            2'd1: step_idx = 8'b00010001; // 2
            2'd2: step_idx = 8'b01010101; // 4
            2'd3: step_idx = 8'b01110111; // 6
        endcase
    end
    else begin
        // Modified 2026-11-13 (see the header, 2): the chip's table. Slice
        // value odd: always; 2 or 6: rate bit 1; 4: rate bit 0; 0: never.
        case( rate[1:0] )
            2'd0: step_idx = 8'b10101010; // 4
            2'd1: step_idx = 8'b10111010; // 5
            2'd2: step_idx = 8'b11101110; // 6
            2'd3: step_idx = 8'b11111110; // 7
        endcase
    end
    // a rate of zero keeps the level still
    step = rate[5:1]==5'd0 ? 1'b0 : step_idx[ cnt ];
end

// Modified 2026-11-13 (see the header). The operator stores the counter's
// tick bit: its first pass after a tick is the one where that bit has changed.
// The selected slice's lowest bit changes at that tick exactly when the
// counter's bits below the slice are all 0.
reg low_zero;
always @(*)
    case( mux_sel )
        5'h1: low_zero = eg_cnt[10:0]==11'd0;
        5'h2: low_zero = eg_cnt[ 9:0]==10'd0;
        5'h3: low_zero = eg_cnt[ 8:0]== 9'd0;
        5'h4: low_zero = eg_cnt[ 7:0]== 8'd0;
        5'h5: low_zero = eg_cnt[ 6:0]== 7'd0;
        5'h6: low_zero = eg_cnt[ 5:0]== 6'd0;
        5'h7: low_zero = eg_cnt[ 4:0]== 5'd0;
        5'h8: low_zero = eg_cnt[ 3:0]== 4'd0;
        5'h9: low_zero = eg_cnt[ 2:0]== 3'd0;
        5'ha: low_zero = eg_cnt[ 1:0]== 2'd0;
        5'hb: low_zero = eg_cnt[   0]== 1'b0;
        default: low_zero = 1'b1;
    endcase

// eg_cnt[12] toggles at every tick (jt12_eg_cnt.v); bit 0 does not when the
// twelve-bit timer goes from FFF to 1.
assign cnt_lsb = eg_cnt[12];
always @(*) begin
    sum_up = ( eg_cnt[12] != cnt_in ) & low_zero;
end

endmodule // eg_step