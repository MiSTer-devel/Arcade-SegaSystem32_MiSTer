// s32_sound.sv — System 32 sound CPU section: the Z80, ROM banking, the
// sound interrupt controller and the chip selects.
//
// References: MAME segas32.cpp (Z80 memory and I/O maps). The sound chip
// register writes were compared with MAME's, write for write, over the
// game's boot. The FM chips and the RF5C68 connect through external ports
// (s32_soundtop).
//
// Memory map (Z80): 0000-9FFF fixed ROM, A000-BFFF banked window
// (OUT A0 = bank[5:0], OUT B0 = {b1b0 -> bank[8:7], b2 -> bank[6]},
// 8KB pages over the 4MB region), C000-DFFF RF5C68 window (external),
// E000-FFFF shared RAM (one single-port SRAM on the Z80 bus on the board,
// which the V60 reaches by taking the Z80's bus: see "Bus takeover" and
// "shared RAM" below).
// I/O: 80-8F YM1, 90-9F YM2, A0-AF/B0-BF bank, C0-CF int-lo,
// D0-D7 int-hi (D0-D3 mirrored at D4-D7; D8-DF unknown, writes dropped),
// F1 dummy.
//
// Clocking: cen paces the Z80 (8.053975 MHz = 32.2159 MHz / 4). The ROM
// is read through s32_zromcache, which stalls cen on a miss.

module s32_sound (
    input  logic        clk,
    input  logic        rst,
    input  logic        cen,          // 8.054 MHz Z80 enable

    // sound ROM region (4MB)
    output logic [21:0] rom_addr,
    input  logic [7:0]  rom_data,
    output logic        rom_rd,      // ROM read in flight (cache hold)

    // RF5C68 window (C000-DFFF)
    output logic        pcm_sel,      // access strobe (Z80 timing)
    output logic        pcm_we,
    output logic [12:0] pcm_addr,
    output logic [7:0]  pcm_wdata,
    input  logic [7:0]  pcm_rdata,

    // YM3438 pair (address bit 1:0 = chip A1/A0)
    output logic        ym1_cs, ym2_cs,
    output logic        ym_we,
    output logic [1:0]  ym_a,
    output logic [7:0]  ym_wdata,
    input  logic [7:0]  ym1_rdata,
    input  logic [7:0]  ym2_rdata,
    input  logic        ym_irq,       // chip 1 IRQ; chip 2's /IRQ is not
                                      // connected on the board
                                      // (schematic)

    // V60-side shared RAM port (byte, 8KB)
    // shm_req/shm_gnt: the 315-5385's takeover of the Z80 bus (sheet 7/9:
    // /ZBRQ -> Z80 /BUSRQ, /BUSAK -> /ZBAK). The V60 side holds shm_req
    // for the whole access and strobes only once shm_gnt is high.
    input  logic        shm_req,
    output logic        shm_gnt,
    input  logic        shm_sel,
    input  logic        shm_we,
    input  logic [12:0] shm_addr,
    input  logic [7:0]  shm_wdata,
    output logic [7:0]  shm_rdata,

    // Save/restore port: the 8K shared RAM is battery-backed on the
    // board, so the MiSTer NVRAM file carries it (S32.sv places it after
    // the EEPROM). An M10K has only two ports, so this one borrows the V60
    // side's port on idle cycles (the V60's accesses are one-cycle
    // strobes; restores run under reset, when the V60 is silent; saves
    // read nv_rdata long after the read settles).
    input  logic        nv_sel,
    input  logic        nv_we,
    input  logic [12:0] nv_addr,
    input  logic [7:0]  nv_wdata,
    output logic [7:0]  nv_rdata,

    // V60 command event ($D0000C-F touched) and Z80->V60 interrupt
    input  logic        v60_cmd,
    output logic        v60_irq_pulse
);

    // ------------------------------------------------------------- tv80
    logic        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n;
    logic        busak_n, int_n;
    logic [15:0] A;
    logic [7:0]  di, dout;

    // Bus takeover (OPEN-QUESTIONS Q65). The shared RAM is one single-port
    // SRAM on the Z80's bus (IC16, sheet 7/9), and the V60's address
    // reaches that bus only through the IC15/IC14 buffers, so a V60 access
    // must wait until the Z80 has released the bus: /BUSRQ in, /BUSAK out.
    // tv80 samples /BUSRQ on cen and grants at the end of the machine
    // cycle in progress (T_Res), as a Z80 does at the last T-state, then
    // stays stopped until the request drops. That latency (about 1 to 7
    // Z80 T-states) is the whole modelled cost: the 315-5385's own
    // overhead is unknown and taken as zero, so this is a lower bound.
    //   Under sound reset (CNT bit 2 low, rst high) a Z80 drives no
    // /BUSAK, but it also floats its buses; whether the 315-5385 then
    // waits forever is not known, so the grant is given at once, as
    // before this change (no hang). The RAM itself stays the dual-port
    // M10K below: the handshake supplies the timing, the RAM block is an
    // implementation detail (the Z80 is stopped whenever the V60 port is
    // live, so the two ports are never used at once outside reset).
    assign shm_gnt = !busak_n || rst;

    // cen paces the Z80 (8.054 MHz from s32_sys)
    tv80s u_z80 (
        .reset_n(!rst), .clk(clk), .cen_in(cen),
        .wait_n(1'b1), .int_n(int_n), .nmi_n(1'b1), .busrq_n(!shm_req),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n),
        .rd_n(rd_n), .wr_n(wr_n), .rfsh_n(rfsh_n),
        .halt_n(halt_n), .busak_n(busak_n),
        .A(A), .di(di), .dout(dout)
    );

    // ---------------------------------------------------------- banking
    logic [8:0] bank;

    // write-pulse edge detect (wr_n stays low for several clocks)
    logic wr_n_q;
    always_ff @(posedge clk) wr_n_q <= wr_n;
    logic wr_ev;
    assign wr_ev = !wr_n && wr_n_q;

    // ------------------------------------------------------- shared RAM
    // Synchronous reads on both ports, so it maps to a RAM block; a tv80
    // read cycle spans several clocks, so the registered data is in time.
    // One true dual-port M10K serves both CPUs. The real board has a
    // single-port 8K SRAM (IC16, sheet 7/9) on the Z80's bus, which the
    // V60 reaches only by taking that bus through the 315-5385's
    // /BUSRQ -> /BUSAK handshake. The handshake is modelled above
    // (shm_req/shm_gnt), so the Z80 is stopped whenever port B serves the
    // V60 (OPEN-QUESTIONS Q65). It is the explicit s32_tdp: the
    // save/restore address mux on port B would make Quartus 17 build it
    // from registers.
    // Port A = Z80, port B = fabric + idle-cycle NVRAM grant. The
    // grant shadow keeps nv off the port for two cycles after any
    // fabric strobe, so q_b is stable through the fabric's strobe+2
    // capture window; nv reads latch into their own register one
    // cycle after the grant, immune to later fabric reads.
    logic        shm_z80_we;
    assign shm_z80_we = !mreq_n && wr_ev && A[15:13] == 3'b111;
    logic [1:0]  shm_recent;
    always_ff @(posedge clk)
        shm_recent <= {shm_recent[0], shm_sel};
    wire        nv_grant = nv_sel && !shm_sel && shm_recent == 2'b00;
    wire [12:0] pb_addr  = nv_grant ? nv_addr  : shm_addr;
    wire        pb_we    = nv_grant ? nv_we    : (shm_sel && shm_we);
    wire [7:0]  pb_wd    = nv_grant ? nv_wdata : shm_wdata;
    logic [7:0]  shm_q_z80, pb_q;
    s32_tdp #(.AW(13), .DW(8)) u_shm (
        .clk(clk),
        .we_a(shm_z80_we), .addr_a(A[12:0]), .d_a(dout), .q_a(shm_q_z80),
        .we_b(pb_we), .addr_b(pb_addr), .d_b(pb_wd), .q_b(pb_q)
    );
    assign shm_rdata = pb_q;
    logic nv_gnt_q;
    always_ff @(posedge clk) begin
        nv_gnt_q <= nv_grant && !nv_we;
        if (nv_gnt_q) nv_rdata <= pb_q;
    end

    // ------------------------------------------------------ bus decode
    logic io_we, io_re, mem_re;
    assign io_we  = !iorq_n && wr_ev && m1_n;
    assign io_re  = !iorq_n && !rd_n && m1_n;
    assign mem_re = !mreq_n && !rd_n;
    assign rom_rd = mem_re && A < 16'hC000;

    // -------------------------------------------------------- int ctl
    logic [7:0] int_vector;
    logic       intack;
    assign intack = !m1_n && !iorq_n;

    s32_sndint u_int (
        .clk(clk), .rst(rst),
        .lo_we(io_we && A[7:4] == 4'hC), .lo_off(A[3:0]),
        .lo_data(dout),
        // D0-D3 mirrored at D4-D7 only. s32tech "Port mirroring": "The
        // interupt control registers at $D0-$D3 are mirrored at $D4-D7. The
        // registers at $D8-$DF are unknown (used in some games, $D8 is
        // initialized to $0B or $06)"; MAME maps 0xd0-0xd3 mirror 0x04 and
        // leaves D8-DF unmapped. Decoding all of D0-DF on A[1:0] aliased
        // D8 onto D0: Super Visual Football's driver writes D0<-00 (vector 0
        // = YM timer) then D8<-0B, which overwrote vector 0's source, so the
        // YM timer never interrupted the Z80 and the game was silent
        // (2026-10-18). D8-DF writes are dropped here (OPEN-QUESTIONS Q42).
        .hi_we(io_we && A[7:3] == 5'b11010), .hi_off(A[1:0]),
        .hi_data(dout),
        .ym_irq(ym_irq), .v60_cmd(v60_cmd),
        .int_n(int_n), .int_vector(int_vector),
        .v60_irq_pulse(v60_irq_pulse)
    );

    assign rom_addr = (A < 16'hA000) ? {6'd0, A}
                                     : {bank, A[12:0]};

    assign pcm_sel   = (!mreq_n && (A[15:13] == 3'b110)) &&
                       (wr_ev || !rd_n);
    assign pcm_we    = !wr_n;
    assign pcm_addr  = A[12:0];
    assign pcm_wdata = dout;

    assign ym1_cs   = !iorq_n && m1_n && A[7:4] == 4'h8;
    assign ym2_cs   = !iorq_n && m1_n && A[7:4] == 4'h9;
    assign ym_we    = wr_ev;
    assign ym_a     = A[1:0];
    assign ym_wdata = dout;

    always_ff @(posedge clk) begin
        if (rst)
            bank <= 9'd0;
        else if (io_we) begin
            if (A[7:4] == 4'hA)
                bank <= {bank[8:6], dout[5:0]};
            if (A[7:4] == 4'hB)
                bank <= {dout[1:0], dout[2], bank[5:0]};
        end
    end

    // read mux
    always_comb begin
        di = 8'hFF;
        if (intack)
            di = int_vector;
        else if (mem_re) begin
            if (A[15:13] == 3'b111)      di = shm_q_z80;
            else if (A[15:13] == 3'b110) di = pcm_rdata;
            else                         di = rom_data;
        end else if (io_re) begin
            if (A[7:4] == 4'h8) di = ym1_rdata;
            else if (A[7:4] == 4'h9) di = ym2_rdata;
        end
    end

endmodule
