/* This file is part of JT12.


    JT12 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT12 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT12.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 27-1-2017

    Modified 2026-11-13 for the Sega System 32 core (RetroShrimp): the
    channel accumulator of the YM3438. The ports are the original ones.
    (The core changes several JT12 files; the README beside them lists
    which, what and why.)

    The chip adds a channel's carrier operators, each cut to its top nine
    bits, in a NINE-BIT accumulator that saturates at every add, and puts
    the six channels on the DAC one after another. The original file added
    every carrier of every channel in one 12-bit accumulator, so a channel
    whose carriers pass the nine-bit rail (two or more loud carriers:
    algorithms 4 to 7) came out unclipped and up to four times too loud.

    References:
      - Nuked-OPN2 ym3438.c, OPN2_ChGenerate (traced from the YM3438 die):
        the accumulator is cleared at the channel's first slot, adds
        fm_out >> 5 for each carrier slot in slot order (S1, S3, S2, S4)
        and is clamped to -256..255 after each add; the channel's output
        is taken when its first slot comes round again.
      - MAME ymfm_opn.cpp ym3438::generate ("OPN2C is 9-bit with
        intermediate clipping") and ymfm_fm.ipp fm_channel::output_4op
        (rshift 5, clipmax 256, a clamp after each carrier is added).
        MAME adds S4 first; the chip's slot order is used here, which
        differs only when one add saturates and a later one of the other
        sign pulls back.
      - docs/OPEN-QUESTIONS.md Q69 (what the games do with it).
    Bench: sim/jt12_acc (reference model of the chip's rule).
*/

/* altshift_taps would put the six-deep channel line in a memory block;
   the board has none to spare (S32.qsf, the 2026-10-28 jt12 note) */
(* altera_attribute = "-name AUTO_SHIFT_REGISTER_RECOGNITION OFF" *)
module jt12_acc(
    input               rst,
    input               clk,
    input               clk_en /* synthesis direct_enable */,
    input signed [8:0]  op_result,
    input        [ 1:0] rl,
    input               zero,
    input               s1_enters,
    input               s2_enters,
    input               s3_enters,
    input               s4_enters,
    input               ch6op,
    input   [2:0]       alg,
    input               pcm_en, // only enabled for channel 6
    input   signed [8:0] pcm,
    // combined output
    output reg signed   [11:0]  left,
    output reg signed   [11:0]  right
);

// sN_enters here names the operator whose RESULT is on op_result (jt12_top
// swaps the names for the operator pipeline's twelve-slot delay). For one
// channel the results arrive S1, S3, S2, S4, six slots apart, which is the
// chip's slot order; S1 opens a channel sample and S4 closes it.
reg sum_en;

always @(*) begin
    case ( alg )
        default: sum_en = s4_enters;
        3'd4: sum_en = s2_enters | s4_enters;
        3'd5,3'd6: sum_en = ~s1_enters;
        3'd7: sum_en = 1'b1;
    endcase
end

// ------------------------------------------------ channel accumulator
// Six channels share the adder; each one's running sum comes back round
// six slots later.
reg signed [8:0] ch_acc0, ch_acc1, ch_acc2, ch_acc3, ch_acc4, ch_acc5;

wire signed [8:0] ch_prev = s1_enters ? 9'sd0 : ch_acc5;
wire signed [8:0] ch_add  = sum_en    ? op_result : 9'sd0;
wire signed [9:0] ch_sum  = {ch_prev[8], ch_prev} + {ch_add[8], ch_add};
// -256..255: the two top bits differ exactly when the sum left nine bits
wire signed [8:0] ch_sat  = ch_sum[9] != ch_sum[8] ?
                            { ch_sum[9], {8{~ch_sum[9]}} } : ch_sum[8:0];

// ------------------------------------------------------- DAC slots
// The chip gives each channel its own DAC slot; the sum of the six is
// the level the output filter sees. Channel 6's slot carries the DAC
// register when that is enabled.
wire signed [8:0]  ch_out = (ch6op && pcm_en) ? pcm : ch_sat;
wire signed [11:0] ch_ext = { {3{ch_out[8]}}, ch_out };
wire signed [11:0] add_l  = (s4_enters && rl[1]) ? ch_ext : 12'sd0;
wire signed [11:0] add_r  = (s4_enters && rl[0]) ? ch_ext : 12'sd0;

// six channels of -256..255 stay inside twelve bits: no saturation here
reg signed [11:0] tot_l, tot_r, pre_left, pre_right;

initial begin
    ch_acc0 = 9'd0; ch_acc1 = 9'd0; ch_acc2 = 9'd0;
    ch_acc3 = 9'd0; ch_acc4 = 9'd0; ch_acc5 = 9'd0;
    tot_l = 12'd0; tot_r = 12'd0; pre_left = 12'd0; pre_right = 12'd0;
    left = 12'd0; right = 12'd0;
end

always @(posedge clk) if(clk_en) begin
    ch_acc0 <= ch_sat;
    ch_acc1 <= ch_acc0;
    ch_acc2 <= ch_acc1;
    ch_acc3 <= ch_acc2;
    ch_acc4 <= ch_acc3;
    ch_acc5 <= ch_acc4;
    if( zero ) begin
        pre_left  <= tot_l;
        pre_right <= tot_r;
        tot_l     <= add_l;
        tot_r     <= add_r;
    end else begin
        tot_l     <= tot_l + add_l;
        tot_r     <= tot_r + add_r;
    end
    // Output can be amplied by 8/6=1.33 to use full range
    // an easy alternative is to add 1/4th and get 1.25 amplification
    left  <= pre_left  + { {2{pre_left [11]}}, pre_left [11:2] };
    right <= pre_right + { {2{pre_right[11]}}, pre_right[11:2] };
end

endmodule
