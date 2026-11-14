

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

    Modified 2026-11-13 for the Sega System 32 core (RetroShrimp): in the
    six-channel block operator 1 takes a key-on or key-off one sample
    after the other three operators of the same write, as on the YM3438.
    The ports are the original ones.

    The chip keeps one key bit per slot and latches each slot's bit as the
    slot comes round. A write to register 28 is handed out to the
    channel's four slots at the moment its first slot, operator 1's, is
    being latched, so that latch still takes the old bit: operators 3, 2
    and 4 follow the write in this sample and operator 1 in the next
    (Nuked-OPN2 ym3438.c OPN2_KeyOn, traced from the die: eg_kon_latch is
    read before mode_kon is written). The original file handed the four
    bits out so that operator 1 came first, in the same sample as the
    others, and jt12_mod.v made up for it on some modulation paths and not
    on others. Now the bit that comes out for an operator-1 slot is the
    one that slot had on its previous pass (s1_line), and jt12_mod.v has
    the chip's taps throughout.

    Found by an independent review of jt12_mod.v and measured with
    Nuked-OPN2 run on tools/fm/fm_alg_probe.py's notes (all eight
    algorithms, every operator live): before, algorithms 1 and 7 differed
    in every note; after, all are equal sample for sample
    (docs/OPEN-QUESTIONS.md Q70). CSM key-on (unused by the games) is
    not delayed, as on the chip.

*/

module jt12_kon(
    input           rst,
    input           clk,
    input           clk_en /* synthesis direct_enable */,
    input   [3:0]   keyon_op,
    input   [2:0]   keyon_ch,
    input   [1:0]   next_op,
    input   [2:0]   next_ch,
    input           up_keyon,
    input           csm,
    // input            flag_A,
    input           overflow_A,

    output  reg     keyon_I
);

parameter num_ch=6;

wire csr_out;

generate
if(num_ch==6) begin
    // capture overflow signal so it lasts long enough
    reg overflow2;
    reg [4:0] overflow_cycle;

    always @(posedge clk) if( clk_en ) begin
        if(overflow_A) begin
            overflow2 <= 1'b1;
            overflow_cycle <= { next_op, next_ch };
        end else begin
            if(overflow_cycle == {next_op, next_ch}) overflow2<=1'b0;
        end
    end

    // Modified 2026-11-13 (see the header). csr_out carries the key bit of
    // operator next_op of channel next_ch; an operator-1 slot (next_op 0)
    // gets the bit it had one pass, 24 slots, ago.
    reg  [5:0] s1_line;
    wire       s1_slot = next_op == 2'd0;
    wire       kon_now = s1_slot ? s1_line[5] : csr_out;

    always @(posedge clk) if( clk_en ) begin
        if( rst )
            s1_line <= 6'd0;
        else if( s1_slot )
            s1_line <= { s1_line[4:0], csr_out };
        keyon_I <= (csm&&next_ch==3'd2&&overflow2) || kon_now;
    end

    reg        up_keyon_reg;
    reg  [3:0] tkeyon_op;
    reg  [2:0] tkeyon_ch;
    wire       key_upnow;

    assign key_upnow = up_keyon_reg && (tkeyon_ch==next_ch) && (next_op == 2'd3);

    always @(posedge clk) if( clk_en ) begin
        if (rst)
            up_keyon_reg <= 1'b0;
        if (up_keyon) begin
            up_keyon_reg <= 1'b1;
            tkeyon_op <= keyon_op;
            tkeyon_ch <= keyon_ch;      end
        else if (key_upnow)
            up_keyon_reg <= 1'b0;
     end


    wire middle1;
    wire middle2;
    wire middle3;
    wire din      = key_upnow ? tkeyon_op[3] : csr_out;
    wire mid_din2 = key_upnow ? tkeyon_op[1] : middle1;
    wire mid_din3 = key_upnow ? tkeyon_op[2] : middle2;
    wire mid_din4 = key_upnow ? tkeyon_op[0] : middle3;

    jt12_sh_rst #(.width(1),.stages(6),.rstval(1'b0)) u_konch0(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( din       ),
        .drop   ( middle1   )
    );

    jt12_sh_rst #(.width(1),.stages(6),.rstval(1'b0)) u_konch1(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( mid_din2  ),
        .drop   ( middle2   )
    );

    jt12_sh_rst #(.width(1),.stages(6),.rstval(1'b0)) u_konch2(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( mid_din3  ),
        .drop   ( middle3   )
    );

    jt12_sh_rst #(.width(1),.stages(6),.rstval(1'b0)) u_konch3(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( mid_din4  ),
        .drop   ( csr_out   )
    );
end
else begin // 3 channels
    reg din;
    reg [3:0] next_op_hot;

    always @(*) begin
        case( next_op )
            2'd0: next_op_hot = 4'b0001; // S1
            2'd1: next_op_hot = 4'b0100; // S3
            2'd2: next_op_hot = 4'b0010; // S2
            2'd3: next_op_hot = 4'b1000; // S4
        endcase
        din = keyon_ch[1:0]==next_ch[1:0] && up_keyon ? |(keyon_op&next_op_hot) : csr_out;
    end

    always @(posedge clk) if( clk_en )
        keyon_I <= csr_out; // No CSM for YM2203

    jt12_sh_rst #(.width(1),.stages(12),.rstval(1'b0)) u_konch1(
        .clk    ( clk       ),
        .clk_en ( clk_en    ),
        .rst    ( rst       ),
        .din    ( din       ),
        .drop   ( csr_out   )
    );
end
endgenerate


endmodule
