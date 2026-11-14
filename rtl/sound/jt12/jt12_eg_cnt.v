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
	counter is the chip's twelve-bit envelope timer. The port is the
	original one.

	The chip's envelope timer has twelve bits and adds its own carry back
	in half a sample later, so it goes from FFF to 1 and never rests at 0:
	4,095 states. The original file was a plain 15-bit counter (the slices
	above bit 11 only served rates 0-7), one state more in every 4,096
	ticks, so every envelope's steps fell one tick later than the chip's
	every 12,288 samples. Here eg_cnt[11:0] is that timer, eg_cnt[12]
	toggles at every tick (jt12_eg_step.v finds the tick with it: bit 0
	does not change from FFF to 1) and eg_cnt[14:13] are 0.

	Reference: Nuked-OPN2 ym3438.c (traced from the YM3438 die),
	OPN2_Clock cycles 1 and 13: eg_timer += eg_timer_inc; eg_timer_inc =
	eg_timer >> 12; eg_timer &= 0xfff. Checked by running it on the notes
	of tools/fm/fm_eg_probe.py (docs/OPEN-QUESTIONS.md Q70).

	*/

module jt12_eg_cnt(
	input rst,
	input clk,
	input clk_en /* synthesis direct_enable */,
	input zero,
	output reg [14:0] eg_cnt
);

reg	[1:0] eg_cnt_base;

always @(posedge clk, posedge rst) begin : envelope_counter
	if( rst ) begin
		eg_cnt_base	<= 2'd0;
		eg_cnt		<=15'd0;
	end
	else begin
		if( zero && clk_en ) begin
			// envelope counter increases every 3 output samples,
			// there is one sample every 24 clock ticks
			if( eg_cnt_base == 2'd2 ) begin
				// Modified 2026-11-13 (see the header)
				eg_cnt[11:0]	<= eg_cnt[11:0]==12'hfff ? 12'd1 : eg_cnt[11:0] + 12'd1;
				eg_cnt[12]	<= ~eg_cnt[12];
				eg_cnt[14:13]	<= 2'd0;
				eg_cnt_base	<= 2'd0;
			end
			else eg_cnt_base <= eg_cnt_base + 1'b1;
		end
	end
end

endmodule // jt12_eg_cnt