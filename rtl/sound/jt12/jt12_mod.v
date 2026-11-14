

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


    Modified 2026-11-13 for the Sega System 32 core (RetroShrimp): which
    operator-1 output operators 2 and 3 take (the six-channel block
    below), together with jt12_kon.v. The ports are the original ones.

    On the chip operator 1 takes a key-on one sample after the other three
    of the same write (OPN2_KeyOn), operators 2 and 4 are modulated by the
    operator-1 output of their own sample, and operator 3 by that of the
    sample before (it is computed before operator 1's result is stored).
    The original files keyed all four operators on together and made up
    for it on two paths: operator 2 got the output of the sample before
    and operator 3, in algorithm 5, the one before that. Those two came
    out as on the chip. But operator 4 (algorithms 2 and 5) and operator
    3 in algorithm 1 had the chip's own taps, so with operator 1 keyed a
    sample early they heard it a sample early; and operator 1 itself,
    which is audible in algorithm 7, sounded a sample before the rest of
    its channel.

    Now jt12_kon.v delays operator 1's key state as the chip does and
    every tap here is the chip's:
      operator 1 (feedback)   its last two outputs      prev1, prevprev1
      operator 3, alg 1, 5    operator 1, last sample   prev1
      operator 3, alg 0-2     operator 2, last sample   prev2
      operator 2              operator 1, this sample   internal
      operator 4, alg 2, 5    operator 1, this sample   prev1 (stored
                                                         since operator 2)
      operator 4, alg 3       operator 2, last sample   prev2
      operator 4, others      operator 3, this sample   internal
    (An earlier change of the same day moved operator 4 to the older
    operator-1 output instead. That matched the chip on the six paths
    probed then and is undone here.)

    References: Nuked-OPN2 ym3438.c (traced from the YM3438 die):
    fm_algorithm; OPN2_FMPrepare / OPN2_FMGenerate (a slot is prepared 11
    cycles before its output is stored, so operator 3, six slots after
    operator 1, still reads the previous fm_op1); OPN2_KeyOn. Found by an
    independent review and measured with Nuked-OPN2 run on the notes of
    tools/fm/fm_alg_probe.py (all eight algorithms, every operator live,
    with and without feedback): before, algorithms 1 and 7 differed in
    every note; after, all sixteen cases are equal sample for sample, as
    are the six single paths of tools/fm/fm_routing_probe.py
    (docs/OPEN-QUESTIONS.md Q70).

    */

module jt12_mod(
    input       s1_enters,
    input       s2_enters,
    input       s3_enters,
    input       s4_enters,
    
    input [2:0] alg_I,
    
    output reg  xuse_prevprev1,
    output reg  xuse_internal,
    output reg  yuse_internal,    
    output reg  xuse_prev2,
    output reg  yuse_prev1,     
    output reg  yuse_prev2      
);

parameter num_ch=6;

reg [7:0] alg_hot;

always @(*) begin
    case( alg_I )
        3'd0: alg_hot = 8'h1;  // D0
        3'd1: alg_hot = 8'h2;  // D1
        3'd2: alg_hot = 8'h4;  // D2
        3'd3: alg_hot = 8'h8;  // D3
        3'd4: alg_hot = 8'h10; // D4
        3'd5: alg_hot = 8'h20; // D5
        3'd6: alg_hot = 8'h40; // D6
        3'd7: alg_hot = 8'h80; // D7
    endcase
end

// prev2 cannot modulate with prevprev1 at the same time
// x = prev2, prevprev1, internal_x
// y = prev1, internal_y

generate
    if( num_ch==6 ) begin
        always @(*) begin
            // Modified 2026-11-13 (see the header): the chip's taps, with
            // operator 1 keyed a sample late in jt12_kon.v. S2 takes S1
            // from this sample (it was prev1) and S3 in algorithm 5 from
            // the last one (it was prevprev1).
            xuse_prevprev1 = s1_enters;
            xuse_prev2 = (s3_enters&(|alg_hot[2:0])) | (s4_enters&alg_hot[3]);
            xuse_internal = s4_enters & alg_hot[2];
            yuse_internal = (s4_enters & (|{alg_hot[4:3],alg_hot[1:0]})) |
                (s2_enters&(|{alg_hot[6:3],alg_hot[0]}));
            yuse_prev1 = s1_enters | (s3_enters&(|{alg_hot[5],alg_hot[1]})) |
                (s4_enters&(|{alg_hot[5],alg_hot[2]}));
            yuse_prev2 = 1'b0; // unused for 6 channels
        end     
    end else begin
        reg [2:0] xuse_s4, xuse_s3, xuse_s2, xuse_s1;
        reg [2:0] yuse_s4, yuse_s3, yuse_s2, yuse_s1;
        always @(*) begin // 3 ch
            // S1
            { xuse_s1, yuse_s1 } = { 3'b001, 3'b100 };
            // S2
            casez( 1'b1 )
                // S2 modulated by S1
                alg_hot[6], alg_hot[5], alg_hot[4], alg_hot[3], alg_hot[0]:
                    { xuse_s2, yuse_s2 } = { 3'b000, 3'b100 }; // prev1
                default:  { xuse_s2, yuse_s2 } =  6'd0;
            endcase
            // S3
            casez( 1'b1 )
                // S3 modulated by S1
                alg_hot[5]:
                    { xuse_s3, yuse_s3 } = { 3'b000, 3'b100 }; // prev1
                // S3 modulated by S2
                alg_hot[2], alg_hot[0]:
                    { xuse_s3, yuse_s3 } = { 3'b000, 3'b010 }; // prev2
                // S3 modulated by S2+S1
                alg_hot[1]:
                    { xuse_s3, yuse_s3 } = { 3'b010, 3'b100 }; // prev2 + prev1                   
                default:  { xuse_s3, yuse_s3 } =  6'd0;
            endcase  
            // S4
            casez( 1'b1 )
                // S4 modulated by S1
                alg_hot[5]:
                    { xuse_s4, yuse_s4 } = { 3'b000, 3'b100 }; // prev1
                // S4 modulated by S3
                alg_hot[4], alg_hot[1], alg_hot[0]:
                    { xuse_s4, yuse_s4 } = { 3'b100, 3'b000 }; // prevprev1
                // S4 modulated by S3+S2
                alg_hot[3]:
                    { xuse_s4, yuse_s4 } = { 3'b100, 3'b010 }; // prevprev1+prev2                    
                // S4 modulated by S3+S1
                alg_hot[2]:
                    { xuse_s4, yuse_s4 } = { 3'b100, 3'b100 }; // prevprev1+prev1
                default:  { xuse_s4, yuse_s4 } =  6'd0;
            endcase                       
            case( {s4_enters, s3_enters, s2_enters, s1_enters})
                4'b1000: begin
                    {xuse_prevprev1, xuse_prev2, xuse_internal} = xuse_s4;
                    {yuse_prev1, yuse_prev2, yuse_internal    } = yuse_s4;
                end
                4'b0100: begin
                    {xuse_prevprev1, xuse_prev2, xuse_internal} = xuse_s3;
                    {yuse_prev1, yuse_prev2, yuse_internal    } = yuse_s3;
                end             
                4'b0010: begin
                    {xuse_prevprev1, xuse_prev2, xuse_internal} = xuse_s2;
                    {yuse_prev1, yuse_prev2, yuse_internal    } = yuse_s2;
                end
                4'b0001: begin
                    {xuse_prevprev1, xuse_prev2, xuse_internal} = xuse_s1;
                    {yuse_prev1, yuse_prev2, yuse_internal    } = yuse_s1;
                end
                default: begin
                    {xuse_prevprev1, xuse_prev2, xuse_internal} = 3'b0;
                    {yuse_prev1, yuse_prev2, yuse_internal    } = 3'b0;
                end
            endcase
        end     
    end
endgenerate

// Control signals for simulation: should be 2'b0 or 2'b1
// wire [1:0] xusage = xuse_prevprev1+xuse_prev2+xuse_internal;
// wire [1:0] yusage = yuse_prev1+yuse_internal;
// 
// always @(xusage,yusage)
//     if( xusage>2'b1 || yusage>2'b1 ) begin
//         $display("ERROR: x/y over use in jt12_mod");
//         $finish;
//     end

endmodule
