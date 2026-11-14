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

	Modified 2026-11-13 for the Sega System 32 core (RetroShrimp): the
	polarity of the LFO's amplitude-modulation triangle (one line, marked
	below). The ports are the original ones.

	The chip's AM value is the LFO step counter's low six bits, INVERTED
	while bit 6 is 0: it starts at its maximum (63) when the counter is 0
	and falls. The original file inverted them while bit 6 is 1, so its
	triangle started at 0 and rose. The two differ by more than phase: the
	counter is held at 0 while the LFO is disabled (register 22 bit 3
	clear), so on the chip an operator with AM enabled, in a channel whose
	AMS is not 0, is attenuated by the full depth for as long as the LFO is
	off (1.4 / 5.9 / 11.8 dB for AMS 1 / 2 / 3), and the original file
	attenuated it by nothing. Holosseum does exactly that for eighteen
	seconds of one tune (docs/OPEN-QUESTIONS.md Q70).

	References:
	  - Nuked-OPN2 ym3438.c, OPN2_Clock / OPN2_EnvelopePrepare (traced from
	    the YM3438 die): lfo_am = (lfo_cnt & 0x40) ? lfo_cnt & 0x3f :
	    lfo_cnt ^ 0x3f, doubled, then shifted right by 7 / 3 / 1 / 0 for
	    AMS 0-3; lfo_cnt is forced to 0 while the LFO is disabled.
	  - MAME ymfm_opn.cpp, opn_registers_base::clock_noise_and_lfo ("first
	    half of the AM period (bit 6 == 0) is inverted"; with the LFO
	    disabled the AM value is 0x3f).
	  - The note quoted in jt12_lfo.v's own header says the same: the
	    counter's bits 0:5 "XORed with inversion of bit 6".
	Bench: sim/jt12_egfinal.

	*/

module jt12_eg_final(
	input [ 6:0] lfo_mod,
	input        amsen,
	input [ 1:0] ams,
	input [ 6:0] tl,
	input [ 9:0] eg_pure_in,
	input 		 ssg_inv,
	output reg	[9:0] eg_limited
);

reg	[ 8:0]	am_final;
reg	[11:0]	sum_eg_tl;
reg	[11:0]	sum_eg_tl_am;
reg	[ 5:0]	am_inverted;
reg [ 9:0]	eg_pream;

// Modified 2026-11-13 (see the header): inverted while bit 6 is 0, as the
// chip. The original line was
//	am_inverted = lfo_mod[6] ? ~lfo_mod[5:0] : lfo_mod[5:0];
always @(*) begin
	am_inverted = lfo_mod[6] ? lfo_mod[5:0] : ~lfo_mod[5:0];
end

always @(*) begin
	casez( {amsen, ams } )
		default: am_final = 9'd0;
		3'b1_01: am_final = { 5'd0, am_inverted[5:2]	};
		3'b1_10: am_final = { 3'd0, am_inverted 		};
		3'b1_11: am_final = { 2'd0, am_inverted, 1'b0	};
	endcase
	eg_pream = ssg_inv ? (10'h200-eg_pure_in) : eg_pure_in;
	sum_eg_tl = {  1'b0, tl,   3'd0 } + {1'b0, eg_pream}; // leading zeros needed to compute correctly
	sum_eg_tl_am = sum_eg_tl + { 3'd0, am_final };
end

always @(*)  
	eg_limited = sum_eg_tl_am[11:10]==2'd0 ? sum_eg_tl_am[9:0] : 10'h3ff;

endmodule // jt12_eg_final