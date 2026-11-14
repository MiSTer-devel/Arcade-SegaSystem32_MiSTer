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

	
	Modified 2026-11-13 for the Sega System 32 core (RetroShrimp): the size
	of a decay step at rates under 48 (dr_sum's default line). The ports
	are the original ones.

	A decay, sustain or release step adds 1 to the level (4 under SSG-EG)
	at rates under 48. The original file added 2 (8), on half as many
	ticks; jt12_eg_step.v now steps on the chip's ticks (its header has
	the rule and the references), so the step here is the chip's 1.
	Bench: sim/jt12_egstep. docs/OPEN-QUESTIONS.md Q70.

	Also modified 2026-11-13: the doubled attack step at rates 48 and up
	(ar_fine below). An attack step takes (level >> n) + 1 off the level,
	with n = 4, 3, 2 or 1 as the chip's increment is 1 to 4; on the ticks
	where a rate of 48 or more steps double, the chip shifts by one place
	less. The original file doubled the single step instead, which is one
	level too many whenever (level + 1) leaves 1 to half the step's unit.
	Reference: Nuked-OPN2 OPN2_EnvelopeADSR, inc = (~level << eg_inc) >> 5;
	MAME ymfm clock_envelope, (~attenuation * increment) >> 4.
	Bench: sim/jt12_egpure.

	*/

module jt12_eg_pure(
	input			attack,
	input			step,
	input [ 5:1]	rate,
	input [ 9:0]	eg_in,
	input 			ssg_en,	
	input 			sum_up,
	output reg  [9:0] eg_pure
);

reg [ 3:0] 	dr_sum;
reg [ 9:0]	dr_adj;
reg	[10:0]	dr_result;

always @(*) begin : dr_calculation
	case( rate[5:2] )
		4'b1100: dr_sum = { 2'b0, step, ~step }; // 12
		4'b1101: dr_sum = { 1'b0, step, ~step, 1'b0 }; // 13
		4'b1110: dr_sum = { step, ~step, 2'b0 }; // 14
		4'b1111: dr_sum = 4'd8;// 15
		// Modified 2026-11-13 (see the header): one, not two
		default: dr_sum = { 3'b0, step };
	endcase
	// Decay rate attenuation is multiplied by 4 for SSG operation
	dr_adj = ssg_en ? {4'd0, dr_sum, 2'd0} : {6'd0, dr_sum};
	dr_result = dr_adj + eg_in;
end

reg [ 7:0] ar_sum0;
reg [ 8:0] ar_sum1;
reg [10:0] ar_result;
reg [ 9:0] ar_sum;
reg [ 8:0] ar_fine; // the level shifted one place less: a doubled step

always @(*) begin : ar_calculation
	casez( rate[5:2] )
		default: begin ar_sum0 = {2'd0, eg_in[9:4]}; ar_fine = {2'd0, eg_in[9:3]}; end
		4'b1101: begin ar_sum0 = {1'd0, eg_in[9:3]}; ar_fine = {1'd0, eg_in[9:2]}; end
		4'b111?: begin ar_sum0 = eg_in[9:2];         ar_fine = eg_in[9:1];         end
	endcase
	ar_sum1 = ar_sum0+9'd1;
	if( rate[5:4] == 2'b11 )
		// Modified 2026-11-13 (see the header): not twice the single step
		ar_sum = step ? ( {1'b0, ar_fine} + 10'd1 ) : { 1'b0, ar_sum1 };
	else
		ar_sum = step ? { 1'b0, ar_sum1 } : 10'd0;
	ar_result = eg_in-ar_sum;
end
///////////////////////////////////////////////////////////
// rate not used below this point
reg [9:0] eg_pre_fastar; // pre fast attack rate
always @(*) begin
	if(sum_up) begin
		if( attack  )
			eg_pre_fastar = ar_result[10] ? 10'd0: ar_result[9:0];
		else 
			eg_pre_fastar = dr_result[10] ? 10'h3FF : dr_result[9:0];
	end
	else eg_pre_fastar = eg_in;
	eg_pure = (attack&rate[5:1]==5'h1F) ? 10'd0 : eg_pre_fastar;
end

endmodule // jt12_eg_pure