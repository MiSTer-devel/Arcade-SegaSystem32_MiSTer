// v60_regs.sv — NEC V60 register file: general registers, banked stack
// pointer, PSW, and privileged registers.
//
// Architecture (NEC manual ch.2; banking behavior cross-checked against
// MAME v60.cpp v60SaveStack/v60ReloadStack):
//   - R0..R31 general registers; R29=AP, R30=FP by convention (plain GPRs).
//   - R31 (SP) is a *view* onto one of five physical stack registers,
//     selected by PSW: ISP when PSW.IS (bit 28) is set, else L0SP..L3SP
//     indexed by PSW.EL (bits 25:24). This module stores SP only in the
//     bank registers and muxes combinationally — equivalent to the
//     manual's save/reload description, without sequencing hazards.
//   - The one place the two are NOT equivalent is LDPR/STPR of the stack
//     pointer that is in use. The manual (p.8-27): "The cache of five stack
//     pointer registers (L0SP-L3SP, ISP) are independent of the user SP
//     (R31). ... Before changing stacks, the contents of the SP register
//     are saved back in the contents of the corresponding stack pointer
//     register. Because the SP is updated by any instruction affecting
//     R31, the contents of the SP and the associated stack pointer register
//     can differ during the execution of a program." So `stpr` of the
//     active one returns what it held at the last stack change (or the
//     last `ldpr` to it), and `ldpr` to it does not move R31; the next
//     stack change overwrites it with SP (MAME's v60SaveStack /
//     v60ReloadStack do the same for ldpr, stpr and PSW changes).
//     `acache` is that register for the active bank; the inactive ones
//     equal their bank. Selected by preg_cache (ldpr, stpr, the debug
//     port); the task walk (ldtask reloads SP from what it loads, sttask
//     saves SP first: sp_save) keeps the view. One corner differs from
//     MAME and is recorded as open (docs/OPEN-QUESTIONS.md Q68): ldtask
//     at IS = 0 with the level in use left out of the walk keeps SP here,
//     where MAME reloads it from the register.
//     Until 2026-11-11 `ldpr` to the active one moved the live SP.
//   - Privileged registers for ldpr/stpr, by the manual's register ID
//     (LDPR p.7-52, STPR p.7-103, Figure 3-2): 0 ISP, 1-4 L0SP..L3SP, 5 SBR,
//     6 TR, 7 SYCW, 8 TKCW, 9 PIR (read-only), 15 PSW2. IDs 10-14 are
//     reserved. IDs 16-28 are the area-table and address-trap registers of
//     the memory-management and debug hardware, which this core does not
//     model: they read 0 and a load is dropped. Before 2026-11-11 the ID
//     was four bits wide, so `ldpr x,#17` (ATLR0) loaded L0SP and #21 the
//     SBR, and PSW2 sat at the reserved ID 10.
//   - PSW[3:0] = {CY,OV,S,Z} flag nibble is updated either by full PSW
//     writes or by the dedicated flags port (per-instruction updates).
//
// Reset values (manual Figure 8-6, p.8-20): PSW = 10000000h (IS set, level
// 0, interrupts masked), SYCW = 00000070h, TKCW = 0000E000h, PSW2 =
// 0000F002h. PIR is the read-only processor ID, 000060xxh for the V60
// (p.3-12: PT = 0110 0000 in bits 15:8, bits 7:0 reserved to NEC); the low
// byte reads 00 here, as in MAME.
//
// Two combinational read ports + one write port cover the microcode
// datapath (one uop reads up to two registers, writes one).
//
// R0..R30 stay flops (docs/corertlcleanup.md C3, tried 2026-10-28): as an
// MLAB they map cleanly (two copies, 907 -> 312 ALUTs, 1,376 -> 453
// registers) once the write is staged through a register with a read
// bypass and a written-since-reset mask keeps the reset value, and every
// bench passes. But the first release fit (seed 11) failed HOLD on the
// core clock by 24 ps from that staging register into the MLAB's write
// address, placed in the adjacent LAB -- the same MLAB write-port hold
// class the S32.qsf works around for jt12 and the HDMI shift registers by
// forcing flops. A register-file write that can race its own address is
// not worth ~600 ALMs at 83% utilisation.

module v60_regs (
    input  logic        clk,
    input  logic        rst,

    // general register ports (R31 resolves to the active stack bank)
    input  logic [4:0]  raddr_a,
    output logic [31:0] rdata_a,
    input  logic [4:0]  raddr_b,
    output logic [31:0] rdata_b,
    input  logic        wen,
    input  logic [4:0]  waddr,
    input  logic [31:0] wdata,

    // PSW access
    output logic [31:0] psw,
    input  logic        psw_wen,      // full write (updpsw/retis/trap entry)
    input  logic [31:0] psw_wdata,
    input  logic        flags_wen,    // flag-nibble-only update from datapath
    input  logic [3:0]  flags_wdata,  // {CY,OV,S,Z}

    // privileged register access (ldpr/stpr), register ID 0..31
    input  logic [4:0]  preg_sel,
    output logic [31:0] preg_rdata,
    input  logic        preg_wen,
    input  logic [31:0] preg_wdata,
    input  logic        preg_cache,   // 1: ldpr/stpr (cache); 0: task walk (view)
    input  logic        sp_save,      // sttask: active cache <- SP
    // SYCW, always visible: ldtask/sttask need its SPSI field (bits 11:8)
    // in the same cycle as the TR read/write on the preg port
    output logic [31:0] sycw_o
);

    // privileged register numbering (stpr/ldpr operand values)
    localparam int PR_ISP  = 0,
                   PR_L0SP = 1, PR_L1SP = 2, PR_L2SP = 3, PR_L3SP = 4,
                   PR_SBR  = 5, PR_TR   = 6, PR_SYCW = 7, PR_TKCW = 8,
                   PR_PIR  = 9, PR_PSW2 = 15;

    logic [31:0] gpr [0:30];         // R0..R30 (R31 lives in the banks)
    logic [31:0] sbank [0:4];        // ISP, L0SP..L3SP
    logic [31:0] psw_q;
    logic [31:0] sbr, tr, sycw, tkcw, psw2;
    localparam logic [31:0] PIR_V60 = 32'h0000_6000;

    // active stack bank: ISP when PSW.IS, else L0SP+EL
    logic [2:0] sp_sel;
    assign sp_sel = psw_q[28] ? 3'd0 : (3'd1 + {1'b0, psw_q[25:24]});

    logic [31:0] sp_view;
    assign sp_view = sbank[sp_sel];

    // the active bank's stack-pointer register (header)
    logic [31:0] acache;
    logic        pr_stack, pr_act, pr_bankwr;
    logic [2:0]  sp_sel_n;
    assign pr_stack  = (preg_sel <= 5'd4);
    assign pr_act    = pr_stack && (preg_sel[2:0] == sp_sel);
    assign pr_bankwr = preg_wen && pr_stack && !(preg_cache && pr_act);
    assign sp_sel_n  = psw_wdata[28] ? 3'd0 : (3'd1 + {1'b0, psw_wdata[25:24]});

    assign rdata_a = (raddr_a == 5'd31) ? sp_view : gpr[raddr_a];
    assign rdata_b = (raddr_b == 5'd31) ? sp_view : gpr[raddr_b];
    assign psw = psw_q;
    assign sycw_o = sycw;

    always_comb begin
        unique case (preg_sel)
            PR_ISP, PR_L0SP, PR_L1SP, PR_L2SP, PR_L3SP:
                     preg_rdata = (preg_cache && pr_act) ? acache
                                                         : sbank[preg_sel[2:0]];
            PR_SBR:  preg_rdata = sbr;
            PR_TR:   preg_rdata = tr;
            PR_SYCW: preg_rdata = sycw;
            PR_TKCW: preg_rdata = tkcw;
            PR_PIR:  preg_rdata = PIR_V60;
            PR_PSW2: preg_rdata = psw2;
            default: preg_rdata = 32'd0;
        endcase
    end

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 31; i = i + 1) gpr[i] <= 32'd0;
            for (i = 0; i < 5; i = i + 1) sbank[i] <= 32'd0;
            acache <= 32'd0;
            psw_q <= 32'h1000_0000;   // IS=1, EL=0, flags clear
            sycw  <= 32'h0000_0070;
            sbr   <= 32'd0;
            tr    <= 32'd0;
            tkcw  <= 32'h0000_E000;
            psw2  <= 32'h0000_F002;
        end else begin
            if (wen) begin
                if (waddr == 5'd31)
                    sbank[sp_sel] <= wdata;
                else
                    gpr[waddr] <= wdata;
            end
            if (psw_wen)
                psw_q <= psw_wdata;
            else if (flags_wen)
                psw_q[3:0] <= flags_wdata;
            if (preg_wen) begin
                unique case (preg_sel)
                    PR_ISP, PR_L0SP, PR_L1SP, PR_L2SP, PR_L3SP: begin
                        if (pr_bankwr) sbank[preg_sel[2:0]] <= preg_wdata;
                        if (pr_act)    acache <= preg_wdata;
                    end
                    PR_SBR:  sbr  <= preg_wdata;
                    PR_TR:   tr   <= preg_wdata;
                    PR_SYCW: sycw <= preg_wdata;
                    PR_TKCW: tkcw <= preg_wdata;
                    PR_PSW2: psw2 <= preg_wdata;
                    default: ;
                endcase
            end
            // sttask saves SP back before it stores the stack pointers
            if (sp_save)
                acache <= (wen && waddr == 5'd31) ? wdata : sbank[sp_sel];
            // a stack change reloads SP from the new bank's register: from
            // here on that register and SP agree again (last, so it wins)
            if (psw_wen && sp_sel_n != sp_sel)
                acache <= (pr_bankwr && preg_sel[2:0] == sp_sel_n)
                              ? preg_wdata : sbank[sp_sel_n];
        end
    end

endmodule
