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
    Date: 14-2-2017

    Modified 2026-11-13 for the Sega System 32 core (RetroShrimp): the
    frequency latches (latch_fnum3 and the "CH3 special registers" case
    below). The ports are the original ones.

    The high byte of a frequency is held in a latch until its low byte is
    written. The chip has two latches, each shared by all channels and
    both banks: one for A4-A6 (the channels' frequencies) and one for
    AC-AE (channel 3's per-operator frequencies). And a write to A8-AA on
    bank 1 does not reach channel 3's operators: the chip files it under
    channels 4-6, where nothing reads it. The original file had one latch
    for both kinds, so a channel's low byte written after an AC-AE high
    byte (or an operator's after an A4-A6 one) took the wrong block and
    F-number bits, and it took A8-AA from either bank.

    Reference: Nuked-OPN2 ym3438.c, OPN2_DoRegWrite (traced from the
    YM3438 die): case 0xa4 sets reg_a4, case 0xac sets reg_ac; case 0xa0
    builds fnum[channel] from reg_a4, case 0xa8 fnum_3ch[channel] from
    reg_ac, with channel 3-5 for bank 1; the special mode reads
    fnum_3ch[0..2] only. MAME's ymfm keeps the two kinds apart as well
    (ymfm_opn.cpp, opn_registers_base::write, latchindex).
    Check: tools/fm/fm_latch_probe.py (docs/OPEN-QUESTIONS.md Q70).

    Also modified 2026-11-13: which data port a mode register takes its
    data from (mode_wr below). The address write fixes the register and
    its bank. For the FM registers (30 and up) the data may then come
    through either data port; for the mode registers (21-2C: test, LFO,
    timers, key-on, DAC) the chip takes it only if both the address and
    the data were written on bank 0. The original file never looked at
    the data write's bank, and took the DAC registers 2A-2C from either
    address bank.

    Reference: Nuked-OPN2 ym3438.c, OPN2_DoIO: the mode-register switch
    runs under "write_d_en && (write_data & 0x100) == 0" on
    write_fm_mode_a (the address with its bank bit), while
    write_fm_data, which commits the FM registers, is set by any data
    write after an FM address write. Upstream jt12 (commit 1076fae,
    2026-08-30) and MAME's ymfm drop every data write whose bank differs
    from the address's, the FM registers' too; the die-traced model does
    not, and that is what is followed here.

    Also modified 2026-11-14: the DAC value's lowest bit (REG_PCM below).
    The DAC value is nine bits: a write to 2A sets the upper eight (bit 7
    inverted) and leaves bit 0 alone, which only test register 2C bit 3
    sets (0 from reset). The original file set bit 0 to 1 at every 2A
    write, one code of 512 above the chip's.
    Reference: Nuked-OPN2 OPN2_DoIO, case 0x2a: dacdata &= 0x01; dacdata
    |= (write_data ^ 0x80) << 1; case 0x2c: dacdata &= 0x1fe; dacdata |=
    mode_test_2c[3]. Found by the 2026-11-13 independent review. Check:
    tools/fm/fm_dac_probe.py (docs/OPEN-QUESTIONS.md Q70).
    */


module jt12_mmr(
    input           rst,
    input           clk,
    input           cen /* synthesis direct_enable */,
    output          clk_en,
    output          clk_en_2,
    output          clk_en_ssg,
    output          clk_en_666,
    output          clk_en_111,
    output          clk_en_55,
    input   [7:0]   din,
    input           write,
    input   [1:0]   addr,
    output  reg     busy,
    output          ch6op,
    output  [2:0]   cur_ch,
    output  [1:0]   cur_op,
    // LFO
    output  reg [2:0]   lfo_freq,
    output  reg         lfo_en,
    // Timers
    output  reg [9:0]   value_A,
    output  reg [7:0]   value_B,
    output  reg         load_A,
    output  reg         load_B,
    output  reg         enable_irq_A,
    output  reg         enable_irq_B,
    output  reg         clr_flag_A,
    output  reg         clr_flag_B,
    output  reg         fast_timers,
    input               flag_A,
    input               overflow_A, 
    output  reg [1:0]   div_setting,
    // PCM
    output  reg [8:0]   pcm,
    output  reg         pcm_en,
    output  reg         pcm_wr, // high for one clock cycle when PCM is written
    // ADPCM-A
    output  reg  [ 7:0] aon_a,      // ON
    output  reg  [ 5:0] atl_a,      // TL
    output  reg  [16:0] addr_a,     // address latch
    output  reg  [ 7:0] lracl,      // L/R ADPCM Channel Level
    output  reg         up_start,   // write enable start address latch
    output  reg         up_end,     // write enable end address latch
    output  reg  [ 2:0] up_addr,    // write enable end address latch
    output  reg  [ 2:0] up_lracl,
    output  reg         up_aon,     // There was a write AON register
    // ADPCM-B
    output  reg         acmd_on_b,  // Control - Process start, Key On
    output  reg         acmd_rep_b, // Control - Repeat
    output  reg         acmd_rst_b, // Control - Reset
    output  reg         acmd_up_b,  // Control - New cmd received
    output  reg  [ 1:0] alr_b,      // Left / Right
    output  reg  [15:0] astart_b,   // Start address
    output  reg  [15:0] aend_b,     // End   address
    output  reg  [15:0] adeltan_b,  // Delta-N
    output  reg  [ 7:0] aeg_b,      // Envelope Generator Control
    output  reg  [ 6:0] flag_ctl,
    output  reg  [ 6:0] flag_mask,
    // Operator
    output          xuse_prevprev1,
    output          xuse_internal,
    output          yuse_internal, 
    output          xuse_prev2,
    output          yuse_prev1,
    output          yuse_prev2,
    // PG
    output  [10:0]  fnum_I,
    output  [ 2:0]  block_I,
    output  reg     pg_stop,
    // REG
    output  [ 1:0]  rl,
    output  [ 2:0]  fb_II,
    output  [ 2:0]  alg_I,
    output  [ 2:0]  pms_I,
    output  [ 1:0]  ams_IV,
    output          amsen_IV,
    output  [ 2:0]  dt1_I,
    output  [ 3:0]  mul_II,
    output  [ 6:0]  tl_IV,
    output  reg     eg_stop,

    output  [ 4:0]  ar_I,
    output  [ 4:0]  d1r_I,
    output  [ 4:0]  d2r_I,
    output  [ 3:0]  rr_I,
    output  [ 3:0]  sl_I,
    output  [ 1:0]  ks_II,
    // SSG operation
    output          ssg_en_I,
    output  [2:0]   ssg_eg_I,

    output          keyon_I,

    // Operator
    output          zero,
    output          s1_enters,
    output          s2_enters,
    output          s3_enters,
    output          s4_enters,

    // PSG interace
    output  [3:0]   psg_addr,
    output  [7:0]   psg_data,
    output  reg     psg_wr_n,
    input   [7:0]   debug_bus
);

parameter use_ssg=0, num_ch=6, use_pcm=1, use_adpcm=0, mask_div=1;

jt12_div #(.use_ssg(use_ssg)) u_div (
    .rst            ( rst             ),
    .clk            ( clk             ),
    .cen            ( cen             ),
    .div_setting    ( div_setting     ),
    .clk_en         ( clk_en          ),
    .clk_en_2       ( clk_en_2        ),
    .clk_en_ssg     ( clk_en_ssg      ),
    .clk_en_666     ( clk_en_666      ),
    .clk_en_111     ( clk_en_111      ),
    .clk_en_55      ( clk_en_55       )
);

reg [7:0]   selected_register;

/*
reg     irq_zero_en, irq_brdy_en, irq_eos_en,
        irq_tb_en, irq_ta_en;
        */
reg [6:0] up_opreg; // hot-one encoding. tells which operator register gets updated next
reg [2:0] up_chreg; // hot-one encoding. tells which channel register gets updated next
reg up_keyon;

localparam  REG_TESTYM  =   8'h21,
            REG_LFO     =   8'h22,
            REG_CLKA1   =   8'h24,
            REG_CLKA2   =   8'h25,
            REG_CLKB    =   8'h26,
            REG_TIMER   =   8'h27,
            REG_KON     =   8'h28,
            REG_IRQMASK =   8'h29,
            REG_PCM     =   8'h2A,
            REG_PCM_EN  =   8'h2B,
            REG_DACTEST =   8'h2C,
            REG_CLK_N6  =   8'h2D,
            REG_CLK_N3  =   8'h2E,
            REG_CLK_N2  =   8'h2F,
            // ADPCM (YM2610)
            REG_ADPCMA_ON   = 8'h00,
            REG_ADPCMA_TL   = 8'h01,
            REG_ADPCMA_TEST = 8'h02;

reg csm, effect;

reg [ 2:0] block_ch3op2,  block_ch3op3,  block_ch3op1;
reg [10:0] fnum_ch3op2, fnum_ch3op3, fnum_ch3op1;
reg [ 5:0] latch_fnum;
reg [ 5:0] latch_fnum3; // AC-AE: channel 3's operators (modified 2026-11-13)


reg [2:0] up_ch;
reg [1:0] up_op;

reg [7:0] op_din, ch_din;

generate
    if( use_ssg ) begin
        assign psg_addr = selected_register[3:0];
        assign psg_data = ch_din;
    end else begin
        assign psg_addr = 4'd0;
        assign psg_data = 8'd0;
    end
endgenerate

reg part;
// Modified 2026-11-13 (see the header): a mode register is written only
// with its address and this data write both on bank 0
wire mode_wr = !part && !addr[1];
reg [5:0] exbank;

`ifdef SIMULATION
always @(posedge clk) if( write && rst ) begin
    $display("WARNING [JT12]: detected write request while in reset.\nThis is likely a glue-logic error in the CPU-FM module.");
    $finish;
end
`endif

wire [2:0] ch_sel = {part, selected_register[1:0]};

// this runs at clk speed, no clock gating here
// if I try to make this an async rst it fails to map it
// as flip flops but uses latches instead. So I keep it as sync. reset
always @(posedge clk) begin : memory_mapped_registers
    if( rst ) begin
        selected_register   <= 0;
        div_setting         <= 2'b10; // FM=1/6, SSG=1/4
        up_ch               <= 0;
        up_op               <= 0;
        up_keyon            <= 0;
        up_opreg            <= 0;
        up_chreg            <= 0;
        // IRQ Mask
        /*{ irq_zero_en, irq_brdy_en, irq_eos_en,
            irq_tb_en, irq_ta_en } = 5'h1f; */
        // timers
        { value_A, value_B } <= 0;
        { clr_flag_B, clr_flag_A,
        enable_irq_B, enable_irq_A, load_B, load_A } <= 0;
        fast_timers <= 0;
        // LFO
        lfo_freq    <= 0;
        lfo_en      <= 0;
        csm         <= 0;
        effect      <= 0;
        // PCM
        pcm         <= 0;
        pcm_en      <= 0;
        pcm_wr      <= 0;
        // ADPCM-A
        aon_a       <= 0;
        atl_a       <= 0;
        up_start    <= 0;
        up_end      <= 0;
        up_addr     <= 7;
        up_lracl    <= 7;
        up_aon      <= 0;
        lracl       <= 0;
        addr_a      <= 0;
        // ADPCM-B
        acmd_on_b   <= 0;
        acmd_rep_b  <= 0;
        acmd_rst_b  <= 0;
        alr_b       <= 0;
        flag_ctl    <= 0;
        astart_b    <= 0;
        aend_b      <= 0;
        adeltan_b   <= 0;
        flag_mask   <= 0;
        aeg_b       <= 8'hff;
        // Original test features
        eg_stop     <= 0;
        pg_stop     <= 0;
        psg_wr_n    <= 1;
        // 
        { block_ch3op1, fnum_ch3op1 } <= {3'd0, 11'd0 };
        { block_ch3op3, fnum_ch3op3 } <= {3'd0, 11'd0 };
        { block_ch3op2, fnum_ch3op2 } <= {3'd0, 11'd0 };
        latch_fnum <= 0;
        latch_fnum3 <= 0;
        op_din     <= 0;
        part       <= 0;
    end else begin
        up_chreg   <= 0;
        // WRITE IN REGISTERS
        if( write ) begin
            if( !addr[0] ) begin
                selected_register <= din;  
                part <= addr[1];        
                if (!mask_div)
                case(din)
                    // clock divider: should work only for ym2203
                    // and ym2608.
                    // clock divider works just by selecting the register
                    REG_CLK_N6: div_setting[1] <= 1'b1; // 2D
                    REG_CLK_N3: div_setting[0] <= 1'b1; // 2E
                    REG_CLK_N2: div_setting    <= 2'b0; // 2F
                    default:;
                endcase
            end else begin
                // Global registers
                ch_din <= din;
                if( selected_register == REG_KON && mode_wr ) begin
                    up_keyon <= 1;
                    op_din   <= din;
                end else begin
                    up_keyon <= 0;
                end
                // General control (<0x20 registers and A0==0)
                if( mode_wr ) begin
                    casez( selected_register)
                        //REG_TEST: lfo_rst <= 1'b1; // regardless of din
                        8'h0?: psg_wr_n <= 1'b0;
                        REG_TESTYM: begin
                            eg_stop <= din[5];
                            pg_stop <= din[3];
                            fast_timers <= din[2];
                            end
                        REG_CLKA1:  value_A[9:2]<= din;
                        REG_CLKA2:  value_A[1:0]<= din[1:0];
                        REG_CLKB:   value_B     <= din;
                        REG_TIMER: begin
                            effect  <= |din[7:6];
                            csm     <= din[7:6] == 2'b10;
                            { clr_flag_B, clr_flag_A,
                              enable_irq_B, enable_irq_A,
                              load_B, load_A } <= din[5:0];
                            end
                        `ifndef NOLFO                   
                        REG_LFO:    { lfo_en, lfo_freq } <= din[3:0];
                        `endif
                        default:;
                    endcase
                end

                // CH3 special registers
                // Modified 2026-11-13 (see the header): A8-AA take the AC-AE
                // latch and are bank 0's only; A4-A6 and AC-AE latch apart.
                casez( selected_register)
                    8'hA9: if(!part) { block_ch3op1, fnum_ch3op1 } <= { latch_fnum3, din };
                    8'hA8: if(!part) { block_ch3op3, fnum_ch3op3 } <= { latch_fnum3, din };
                    8'hAA: if(!part) { block_ch3op2, fnum_ch3op2 } <= { latch_fnum3, din };
                    // According to http://www.mjsstuf.x10host.com/pages/vgmPlay/vgmPlay.htm
                    // There is a single fnum latch for all channels
                    8'hA4, 8'hA5, 8'hA6: latch_fnum  <= din[5:0];
                    8'hAC, 8'hAD, 8'hAE: latch_fnum3 <= din[5:0];
                    default:;   // avoid incomplete-case warning
                endcase

                // YM2612 PCM support
                if( use_pcm==1 && mode_wr ) begin
                    casez( selected_register)
                        REG_DACTEST: pcm[0] <= din[3];
                        REG_PCM:
                            // Modified 2026-11-14 (see the header): bit 0 kept
                            pcm <= { ~din[7], din[6:0], pcm[0] };
                        REG_PCM_EN:  pcm_en  <= din[7];
                        default:;
                    endcase
                    pcm_wr <= selected_register==REG_PCM;
                end
                if( use_adpcm==1 ) begin
                    // YM2610 ADPCM-A support, A1=1, regs 0-2D
                    if(part && selected_register[7:6]==2'b0) begin
                        casez( selected_register[5:0] )
                            6'h0: begin
                                aon_a  <= din;
                                up_aon <= 1'b1;
                            end
                            6'h1: atl_a <= din[5:0];
                            // LRACL
                            6'h8, 6'h9, 6'hA, 6'hB, 6'hC, 6'hD: begin
                                lracl <= din;
                                up_lracl <= selected_register[2:0];
				exbank[selected_register[2:0]] <= &din[7:4];
                            end
                            6'b01_????, 6'b10_????: begin
                                if( !selected_register[3] ) addr_a[ 7:0] <= din;
                                if( selected_register[3]  ) addr_a[16:8] <= {exbank[selected_register[2:0]], din};
                                case( selected_register[5:4] )
                                    2'b01, 2'b10: begin
                                        {up_end, up_start } <= selected_register[5:4];
                                        up_addr <= selected_register[2:0];
                                    end
                                    default: begin
                                        up_start <= 1'b0;
                                        up_end   <= 1'b0;
                                    end
                                endcase
                            end
                            default:;
                        endcase
                    end
                    if( !part && selected_register[7:4]==4'h1 ) begin
                        // YM2610 ADPCM-B support, A1=0, regs 1x
                        case(selected_register[3:0])
                            4'd0: {acmd_up_b, acmd_on_b, acmd_rep_b,acmd_rst_b} <= {1'd1,din[7],din[4],din[0]};
                            4'd1: alr_b  <= din[7:6];
                            4'd2: astart_b [ 7:0] <= din;
                            4'd3: astart_b [15:8] <= din;
                            4'd4: aend_b   [ 7:0] <= din;
                            4'd5: aend_b   [15:8] <= din;
                            4'h9: adeltan_b[ 7:0] <= din;
                            4'ha: adeltan_b[15:8] <= din;
                            4'hb: aeg_b           <= din;
                            4'hc: begin
                               flag_mask   <= ~{din[7],din[5:0]};
                               flag_ctl    <= {din[7],din[5:0]}; // this lasts a single clock cycle
                           end
                            default:;
                        endcase
                    end
                end
                if( selected_register[1:0]==2'b11 ) 
                    { up_chreg, up_opreg } <= { 3'h0, 7'h0 };
                else begin
                    casez( selected_register )
                        // channel registers
                        8'hA0, 8'hA1, 8'hA2:    { up_chreg, up_opreg } <= { 3'h1, 7'd0 }; // up_fnumlo
                        // FB + Algorithm
                        8'hB0, 8'hB1, 8'hB2: { up_chreg, up_opreg } <= { 3'h2, 7'd0 }; // up_alg
                        8'hB4, 8'hB5, 8'hB6: { up_chreg, up_opreg } <= { 3'h4, 7'd0 }; // up_pms
                        // operator registers
                        8'h3?: { up_chreg, up_opreg } <= { 3'h0, 7'h01 }; // up_dt1
                        8'h4?: { up_chreg, up_opreg } <= { 3'h0, 7'h02 }; // up_tl
                        8'h5?: { up_chreg, up_opreg } <= { 3'h0, 7'h04 }; // up_ks_ar
                        8'h6?: { up_chreg, up_opreg } <= { 3'h0, 7'h08 }; // up_amen_dr
                        8'h7?: { up_chreg, up_opreg } <= { 3'h0, 7'h10 }; // up_sr
                        8'h8?: { up_chreg, up_opreg } <= { 3'h0, 7'h20 }; // up_sl
                        8'h9?: { up_chreg, up_opreg } <= { 3'h0, 7'h40 }; // up_ssgeg
                        default: { up_chreg, up_opreg } <= { 3'h0, 7'h0 };
                    endcase // selected_register
                    if( selected_register[7:4]>=3 && selected_register[7:4]<=9 ) begin
                        op_din <= din;
                        up_ch <= {part, selected_register[1:0]};
                        up_op <= selected_register[3:2]; // 0=S1,1=S3,2=S2,3=S4
                    end
                end
            end
        end
        else if(clk_en) begin /* clear once-only bits */
            // lfo_rst <= 1'b0;
            { clr_flag_B, clr_flag_A } <= 2'd0;
            psg_wr_n <= 1'b1;
            pcm_wr   <= 1'b0;
            flag_ctl <= 'd0;
            up_aon   <= 1'b0;
            acmd_up_b <= 1'b0;
        end
    end
end

// Modified 2026-11-15 for the Sega System 32 core (RetroShrimp): the busy
// flag follows the die. A data write is seen at the next internal cycle
// (bsy_wr, the die's write_d_en), which starts the 32-cycle count; the
// status bit (busy) shows the count one cycle later; and a data write that
// lands while the count runs neither restarts nor extends it. The count is
// never cleared: it wraps to 0 on the cycle that ends the busy period.
// The original file restarted the count at every data write and set the
// status bit in the write's own clock, so back-to-back writes stretched
// busy and it rose about two cycles early.
// Reference: Nuked-OPN2 ym3438.c, OPN2_DoIO: busy = write_busy;
// write_busy_cnt += write_busy; write_busy = (write_busy &&
// !(write_busy_cnt >> 5)) || write_d_en; write_busy_cnt &= 0x1f.
// Of the library only Slip Stream reads status bit 7 (its FM write routine
// waits on it after every write); the other drivers poll the timer flags.
// Check: sim/jt12_busy against the die-traced model
// (docs/OPEN-QUESTIONS.md Q70). `write` must be one clock per data write
// (s32_sound's wr_ev): a held level counts as a write every cycle.
reg  [4:0] busy_cnt; // busy lasts for 32 synthesizer clock cycles
reg        bsy_wr;   // a data write since the last internal cycle
reg        bsy_run;  // the die's write_busy
wire [5:0] nx_busy = {1'd0,busy_cnt}+{5'd0,bsy_run};

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        busy     <= 0;
        busy_cnt <= 0;
        bsy_wr   <= 0;
        bsy_run  <= 0;
    end else begin
        if( clk_en ) begin
            busy     <= bsy_run;
            busy_cnt <= nx_busy[4:0];
            bsy_run  <= (bsy_run & ~nx_busy[5]) | bsy_wr;
            bsy_wr   <= write & addr[0];
        end else if( write&addr[0] )
            bsy_wr   <= 1;
    end
end

jt12_reg #(.num_ch(num_ch)) u_reg(
    .rst        ( rst       ),
    .clk        ( clk       ),      // P1
    .clk_en     ( clk_en    ),

    // channel udpates
    .ch_sel     ( ch_sel        ),
    .ch_din     ( ch_din        ),
    .up_fnumlo  ( up_chreg[0]   ),
    .up_alg     ( up_chreg[1]   ),
    .up_pms     ( up_chreg[2]   ),

    // operator updates
    .din        ( op_din        ),
    .up_keyon   ( up_keyon      ),
    .up_dt1     ( up_opreg[0]   ),
    .up_tl      ( up_opreg[1]   ),
    .up_ks_ar   ( up_opreg[2]   ),
    .up_amen_dr ( up_opreg[3]   ),
    .up_sr      ( up_opreg[4]   ),
    .up_sl_rr   ( up_opreg[5]   ),
    .up_ssgeg   ( up_opreg[6]   ),

    .op         ( up_op     ),      // operator to update
    .ch         ( up_ch     ),      // channel to update

    .csm        ( csm       ),
    .flag_A     ( flag_A    ),
    .overflow_A ( overflow_A),

    .ch6op      ( ch6op     ),
    .cur_ch     ( cur_ch    ),
    .cur_op     ( cur_op    ),
    // CH3 Effect-mode operation
    .effect     ( effect    ),      // allows independent freq. for CH 3
    .fnum_ch3op2( fnum_ch3op2 ),
    .fnum_ch3op3( fnum_ch3op3 ),
    .fnum_ch3op1( fnum_ch3op1 ),
    .block_ch3op2( block_ch3op2 ),
    .block_ch3op3( block_ch3op3 ),
    .block_ch3op1( block_ch3op1 ),
    .latch_fnum ( latch_fnum    ),
    // Operator
    .xuse_prevprev1 ( xuse_prevprev1  ),
    .xuse_internal  ( xuse_internal   ),
    .yuse_internal  ( yuse_internal   ),  
    .xuse_prev2     ( xuse_prev2      ),
    .yuse_prev1     ( yuse_prev1      ),
    .yuse_prev2     ( yuse_prev2      ),
    // PG
    .fnum_I     (   fnum_I  ),
    .block_I    (   block_I ),
    .mul_II     (   mul_II  ),
    .dt1_I      (   dt1_I   ),

    // EG
    .ar_I       (ar_I       ), // attack  rate
    .d1r_I      (d1r_I      ), // decay   rate
    .d2r_I      (d2r_I      ), // sustain rate
    .rr_I       (rr_I       ), // release rate
    .sl_I       (sl_I       ), // sustain level
    .ks_II      (ks_II      ), // key scale
    // SSG operation
    .ssg_en_I   ( ssg_en_I  ),
    .ssg_eg_I   ( ssg_eg_I  ),
    // envelope number
    .tl_IV      (tl_IV      ),
    .pms_I      (pms_I      ),
    .ams_IV     (ams_IV     ),
    .amsen_IV   (amsen_IV   ),
    // channel configuration
    .rl         ( rl        ),
    .fb_II      ( fb_II     ),
    .alg_I      ( alg_I     ),
    .keyon_I    ( keyon_I   ),

    .zero       ( zero      ),
    .s1_enters  ( s1_enters ),
    .s2_enters  ( s2_enters ),
    .s3_enters  ( s3_enters ),
    .s4_enters  ( s4_enters )
);

endmodule
