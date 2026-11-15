/*  This file is part of jt12.

    jt12 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    jt12 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with jt12.  If not, see <http://www.gnu.org/licenses/>.
	
	Author: Jose Tejada Gomez. Twitter: @topapate
	Version: 1.0
	Date: 25-2-2017

	Modified 2026-11-13 for the Sega System 32 core (RetroShrimp): the LFO's
	divider, in the always block at the end of the file. The ports are the
	original ones.

	The chip's LFO step counter advances every 108 / 77 / 71 / 67 / 62 /
	44 / 8 / 5 samples for rates 0-7. The original file counted from 0 to
	those values inclusive, one sample more (109 ... 6), which is the
	application manual's table of frequencies; the chip is that one sample
	faster (0.9 % at rate 0, 1.4 % at rate 2, 20 % at rate 7). Two smaller
	things follow the chip as well: the divider compares by "all the bits
	of the value are set" and not by equality, and it is not reset while
	the LFO is disabled (only the step counter is held at 0).

	References:
	  - Nuked-OPN2 ym3438.c (traced from the YM3438 die), OPN2_UpdateLFO,
	    run every cycle, with lfo_inc set in cycle 23 only:
	        if ((lfo_quotient & lfo_cycles[freq]) == lfo_cycles[freq])
	            { lfo_quotient = 0; lfo_cnt++; }
	        else lfo_quotient += lfo_inc;
	        lfo_cnt &= lfo_en;
	    lfo_cycles = { 108, 77, 71, 67, 62, 44, 8, 5 }. The quotient reaches
	    the value in cycle 23 of a sample and is cleared in the next cycle,
	    so a step takes that many samples, not one more.
	  - MAME ymfm_opn.cpp, opn_registers_base::clock_noise_and_lfo: "tests
	    on the hardware and nuked bear out an off-by-one error exists that
	    causes the max LFO rate to be faster than published" (its counter
	    gives the same 108 ... 5).
	  - Against: the YM3438 application manual's LFO table (3.98 ... 72.2
	    Hz), which is the 109 ... 6 the original file had.
	Bench: sim/jt12_lfo. docs/OPEN-QUESTIONS.md Q70.

	Modified 2026-11-14: the divider leaves reset at 1, not 0, so its
	phase against the envelope timer and the register writes is the
	chip's (one sample ahead of what the original reset gave). Measured,
	not read from the die's netlist: against Nuked-OPN2 with the two
	models' writes aligned by the envelope (every envelope-only probe
	equal), the LFO stepped one sample later here, and every LFO probe
	(tools/fm/fm_lfo_probe.py, fm_misc_probe.py's lfotest and vibrato)
	is equal to it with this reset value and jt12_top.v's phase-generator
	copy, but for one sample at a write that stops the LFO and the known
	key-on pass-order samples (OPEN-QUESTIONS Q70). It only sets where the divider stands after
	reset; the step period is unchanged.
	*/


/*

	Does the LFO frequency depend on the pre-scaler for YM2608 ?

	From spritesmind.net:
	"That would be 7-bit LFO step counter (which is incremented on each LFO clock and reset when LFO enable bit is cleared). 
	LFO AM value indeed corresponds to LFO step counter bits 0:5 shifted left by one 
	and XORed with inversion of bit 6 (to generate an inverted triangle waveform)
	
	LFO AM sensitivity (2 bits) indicates to EG how much LFO AM value is shifted before adding to EG output
	[...] 
	LFO PM step (0-31), which takes bits 2:6 of LFO step counter (0-127) and goes to LFO PM calcuation unit
	"

	From Sauraen:

The LFO seems to have 3 sections:

	[*] 7-bit linear prescaler. The test bit 0x21:1 goes into what looks like the carry-in or something similar; 
	it could go into the reset, I can't quite tell with more detailed analysis. The 7-bit output (plus maybe carry-out) 
	gets logiced together into 8 lines (evidently perform "== N" with N hardcoded for each line), and these go into a 
	little selector unit which is also fed by the LFO Speed and LFO Enable bits. I can't quite see the output of this, 
	but I do see there's some sort of feedback to the prescaler's reset. So this clearly seems like a divide-by-N prescaler. 
	I can try to read the eight N's for you if you want, but you should be able to reverse engineer them from knowing what the LFO speeds are.

	[*] 7-bit linear counter, with an 8-bit unit after the output (possibly inverts the output after each cycle to make a triangle wave?). 
	Bits 1:6 of the output of this go to the EG, and stick into its pipeline at the same place where the LFO->Amplitude two bits go. 
	(Elsewhere the operator LFO enable flag simply forces these two bits to zero for operators not affected by the LFO.) 
	Some modified version of the 8-bit signal between the counter and the inverter unit thing goes to the third unit of the LFO.

	[*] Highly complex unit which modifies the frequency data as it goes from the channel registers to the PG. The block bits bypass this, 
	but all the frequency bits get modified by it. There's a bitslice portion corresponding to bits 0:6, and then what appears to be 
	the same logic folded over to process bits 7:A. But the interesting part is that bits 4:A of the frequency data go into the 
	bitslices 0:6. That is, the bitslice unit for bit 0 has bit 0 enter at the middle and leave (to the PG) at the bottom. But it also has bit 4 enter at the top. 
	And so on through bit 6 having bit A enter at the top. It looks like the top portion is some sort of shifter for bits 4:A--the wires go diagonally 
	so that bit 4 only gets used once, bit 5 gets used in bitslice 1 and 0, bit 6 gets used in bitslices 2:0, and so on so that bit A gets used in all of them. 
	I'm guessing this whole unit is basically a multiplier, multiplying bits 4:A of the frequency value by bits 0:7 of the LFO state, and then adding the result 
	to bits 0:6 of the frequency value (with carry up to the higher bits). It looks like, between the multiplied output and the adder, there's another shifter 
	whose value is based on the the LFO->Frequency bits. But it looks like it's a bit more complex than I'm describing.

*/

module jt12_lfo(
	input			 	rst,
	input			 	clk,
	input				clk_en,
	input				zero,
	input				lfo_rst,
	input				lfo_en,
	input		[2:0]	lfo_freq,
	output	reg	[6:0]	lfo_mod		// 7-bit width according to spritesmind.net
);

reg [6:0] cnt, limit;

always @(*)
	case( lfo_freq )	// the chip's compare values (Nuked-OPN2 lfo_cycles)
		3'd0: limit = 7'd108;
		3'd1: limit = 7'd77;
		3'd2: limit = 7'd71;
		3'd3: limit = 7'd67;
		3'd4: limit = 7'd62;
		3'd5: limit = 7'd44;
		3'd6: limit = 7'd8;
		3'd7: limit = 7'd5;
	endcase

// Modified 2026-11-13 (see the header). The chip's process, cycle for
// cycle: the divider is compared in every cycle and, when every bit of
// `limit` is set in it, cleared with a step of the LFO counter; otherwise
// it counts once a sample. It reaches `limit` in the counting cycle and is
// cleared in the next one, so a step takes `limit` samples. The step
// counter is held at 0 while the LFO is disabled; the divider runs on.
// It leaves reset at 1 (2026-11-14, see the header).
wire hit = (cnt & limit) == limit;

always @(posedge clk)
	if( rst )
		{ lfo_mod, cnt } <= 14'd1;	// Modified 2026-11-14: cnt from 1 (see the header)
	else begin
		if( clk_en ) begin
			if( hit ) begin
				cnt     <= 7'd0;
				lfo_mod <= lfo_mod + 1'b1;
			end else if( zero )
				cnt <= cnt + 1'b1;
		end
		if( !lfo_en ) lfo_mod <= 7'd0;
	end

endmodule
