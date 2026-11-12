// v60_shifter.sv — NEC V60 shift/rotate unit with PSW flag generation.
//
// Reference: NEC V60 Programmer's Reference Manual, SHA p.7-100, SHL
// p.7-101, ROT p.7-89, ROTC p.7-90. Checked against MAME single-step results
// from Golden Axe code where MAME follows the manual; where it does not
// (below) the corestep packer corrects the golden.
// Count is the signed low byte of the source operand, -128..+127: positive
// = left, negative = right, zero = special case (result unchanged; CY/OV
// cleared; S/Z still evaluated from the value).
//
// Flags ({CY,OV,S,Z} = PSW[3:0]):
//   shl : CY = last bit shifted out, OV = 0
//   sha : left  — CY = last bit out; OV = 1 "if the sign of the result
//                 changes at anytime during the execution" (p.7-100): every
//                 bit that passes through the sign position, the one that
//                 ends up there included, must equal the original sign.
//                 A count of n tests the top n+1 bits; a count >= width
//                 tests them all and the zeros that follow. MAME's
//                 SHIFTLEFT_OV tests only the top n bits (the ones shifted
//                 out), so `sha #1` on 40h (result 80h) reads OV = 0 there
//                 and could never set OV; the manual is followed here
//                 (2026-11-11 audit, docs/OPEN-QUESTIONS.md Q68).
//         right — CY = last bit out; OV = 0; sign-fills
//   rot : CY = bit rotated into the far end (LSB after left / MSB after
//         right rotate), OV = 0; count modulo the width
//   rotc: (width+1)-bit rotate through carry, OV = 0
//
// |count| > width (shl, sha): zero, or the sign for sha right, is stored
// (pp.7-100/101) and CY is the last bit shifted, i.e. a filled-in bit.
// The whole range -128..+127 is honoured: before 2026-11-11 only the low
// six bits of the count were used, so +64 shifted by 0 and -65 by 1.
//
// Purely combinational, built from a few wide funnel shifts shared by all
// modes (one shifter per operation would cost several thousand ALMs):
//   - rot  = funnel over the value replicated across 64 bits
//   - rotc = funnel over the (width+1)-bit vector {CY, value} replicated
//            across 66 bits, rotate count mod (width+1)
//   - shl/sha share one 64-bit left shift and one 64-bit right funnel
//     (CY falls out of the funnel's boundary bit in both directions)
//   - sha-left OV = reduction over (value XOR sign) under the top-n mask

module v60_shifter (
    input  logic [3:0]  op,        // 10 shl, 11 sha, 12 rot, 13 rotc
    input  logic [1:0]  width,     // 0 byte, 1 half, 2 word
    input  logic [31:0] a,
    input  logic [7:0]  count_in,  // signed
    input  logic [3:0]  flags_in,  // {CY,OV,S,Z}
    output logic [31:0] result,
    output logic [3:0]  flags_out
);

    localparam logic [3:0] OP_SHL = 4'd10, OP_SHA = 4'd11,
                           OP_ROT = 4'd12, OP_ROTC = 4'd13;

    logic signed [7:0] count_s;
    logic [7:0]  mag;            // |count|, 0..128
    logic [5:0]  n;              // |count| for the shifts, saturated at 63
    logic [5:0]  nr;             // |count| mod 64 for rot (width divides 64)
    logic [6:0]  cv;             // |count| reduced toward mod (bits+1), rotc
    logic        left;
    logic [5:0]  bits;           // operation width in bits
    logic [31:0] mask, am;
    logic [5:0]  msb;
    logic        sign;
    logic        cy, ov, s, z;
    logic [31:0] res;

    // shared funnels
    logic [63:0] lsh;            // {0, am} << n
    logic [63:0] rsh;            // {am, 0} >> n
    logic [31:0] nmask;          // mask >> n (0 when n >= bits)
    logic [31:0] nmask1;         // mask >> (n+1)
    logic [63:0] rep;            // am replicated to 64 bits (width-wise)
    logic [5:0]  rot_r;          // right-rotate amount, 0..bits-1
    logic [31:0] rot_res;
    logic [65:0] crep;           // {CY, am} pair replicated (rotc)
    logic [6:0]  cbits;          // bits + 1
    logic [5:0]  crot_r;         // right-rotate amount mod (bits+1)
    logic [32:0] crot;           // rotated (width+1)-bit vector
    logic [5:0]  nmod;

    always_comb begin
        unique case (width)
            2'd0:    begin mask = 32'h0000_00FF; bits = 6'd8;  msb = 6'd7;  end
            2'd1:    begin mask = 32'h0000_FFFF; bits = 6'd16; msb = 6'd15; end
            default: begin mask = 32'hFFFF_FFFF; bits = 6'd32; msb = 6'd31; end
        endcase
        am      = a & mask;
        sign    = am[msb];
        count_s = count_in;
        left    = ~count_s[7];
        mag     = left ? {1'b0, count_in[6:0]} : (~count_in + 8'd1);
        n       = (mag > 8'd63) ? 6'd63 : mag[5:0];   // 63 >= every width
        nr      = mag[5:0];

        // ------------------------------------------------ shared funnels
        lsh   = {32'd0, am} << n;
        rsh   = {am, 32'd0} >> n;
        nmask = (n >= bits) ? 32'd0 : (mask >> n);
        nmask1 = nmask >> 1;

        // value replicated across 64 bits at the operation width
        unique case (width)
            2'd0:    rep = {8{am[7:0]}};
            2'd1:    rep = {4{am[15:0]}};
            default: rep = {2{am}};
        endcase

        // rot: right-rotate amount (left rotate = bits - r); bits is a
        // power of two so mod is a mask
        nmod  = nr & (bits - 6'd1);
        rot_r = left ? ((bits - nmod) & (bits - 6'd1)) : nmod;
        rot_res = 32'((rep >> rot_r)) & mask;

        // rotc: (bits+1)-bit vector {CY, am}, rotate count mod (bits+1).
        // |count| = 64*mag[7:6] + mag[5:0]; the 64s are folded in as their
        // residues (64 = 1 mod 9, 13 mod 17, 31 mod 33; 128 = 2, 9, 29) so
        // the chain of conditional subtractions stays short.
        cbits  = {1'b0, bits} + 7'd1;
        if (bits == 6'd8) begin
            cv = {1'b0, mag[5:0]} + {5'd0, mag[7:6]};            // <= 65
            repeat (7) if (cv >= 7'd9) cv = cv - 7'd9;
        end else if (bits == 6'd16) begin
            cv = {1'b0, mag[5:0]} + (mag[7] ? 7'd9 : mag[6] ? 7'd13 : 7'd0);  // <= 76
            repeat (4) if (cv >= 7'd17) cv = cv - 7'd17;
        end else begin
            cv = {1'b0, mag[5:0]} + (mag[7] ? 7'd29 : mag[6] ? 7'd31 : 7'd0); // <= 94
            repeat (2) if (cv >= 7'd33) cv = cv - 7'd33;
        end
        crot_r = cv[5:0];
        if (!left) begin
            // right rotc by r == left-equivalent handled via right funnel
        end else begin
            // left rotc by r == right rotc by (cbits - r) mod cbits
            crot_r = (crot_r == 6'd0) ? 6'd0 : (6'(cbits) - crot_r);
        end

        // replicate the (bits+1)-bit vector {CY, am} twice and funnel
        unique case (width)
            2'd0:    crep = {30'd0, {4{flags_in[3], am[7:0]}}};
            2'd1:    crep = {32'd0, {2{flags_in[3], am[15:0]}}};
            default: crep = {flags_in[3], am, flags_in[3], am};
        endcase
        crot = 33'(crep >> crot_r);

        // ------------------------------------------------------- results
        res = am;
        cy  = flags_in[3];
        ov  = 1'b0;

        if (count_s == 8'sd0) begin
            // destination unchanged; CY/OV cleared; S/Z from current value
            cy = 1'b0;
            ov = 1'b0;
        end else begin
            unique case (op)
                OP_SHL: begin
                    if (left) begin
                        cy  = lsh[bits];            // am[bits-n], 0 if n>bits
                        res = lsh[31:0] & mask;     // 0 naturally when n>=bits
                    end else begin
                        cy  = (n <= bits) ? rsh[31] : 1'b0;  // am[n-1]
                        res = rsh[63:32] & mask;    // 0 naturally when n>=bits
                    end
                end
                OP_SHA: begin
                    if (left) begin
                        // OV: any of the top min(n+1,bits) bits differs
                        // from the sign, or (n >= bits) a set sign is
                        // replaced by a shifted-in zero
                        ov  = (|((am ^ (sign ? mask : 32'd0)) & mask & ~nmask1))
                            | ((n >= bits) & sign);
                        cy  = lsh[bits];
                        res = lsh[31:0] & mask;
                    end else begin
                        cy  = (n <= bits) ? rsh[31] : sign;
                        res = ((rsh[63:32]) | (sign ? (mask & ~nmask) : 32'd0))
                              & mask;
                    end
                end
                OP_ROT: begin
                    res = rot_res;
                    cy  = left ? res[0] : res[msb];
                end
                default: begin // OP_ROTC
                    res = crot[31:0] & mask;
                    cy  = crot[bits];
                end
            endcase
        end

        s = res[msb];
        z = (res == 32'd0);
        result = res;
        flags_out = {cy, ov, s, z};
    end

endmodule
