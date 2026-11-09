// s32_dpad_axis.sv — one self-centring potentiometer driven by two
// direction buttons: a d-pad standing in for a wheel or a flight stick on
// the 837-7536 A/D board.
//
// References:
//   MAME latest master src/mame/sega/segas32.cpp: INPUT_PORTS_START(radm)
//     ANALOG1 (IPT_PADDLE, the wheel) and INPUT_PORTS_START(arescue)
//     ANALOG1/ANALOG2 (IPT_AD_STICK_X/Y, the flight stick): both centre
//     $80, both driven from digital controls by PORT_KEYDELTA steps and
//     self-centring when the keys are released (MAME's default centre
//     delta, the key delta). arescue's PORT_KEYDELTA(10) at 60 Hz is ~600
//     counts a second; this module's 3 counts a tick at S32.sv's adc_tick
//     (~250 Hz) is ~750.
//   docs/radm-bringup.md (the wheel), docs/arescue-bringup.md §6 (the
//   flight stick). Bench: sim/s32_dpad_axis.
//
// While `plus` alone is held the position rises 3 counts a `tick` to $FF,
// while `minus` alone is held it falls 3 a tick to $00; with neither (or
// both) it returns 3 a tick towards $80 and lands on $80 exactly once
// within 3 of it. Reset centres it. The rate is a usability setting, not
// hardware: the real controls are potentiometers the MSM6253 converts
// continuously.
//
// Cost: an 8-bit register, its step adder and four compares.

module s32_dpad_axis (
    input  logic       clk,
    input  logic       rst,
    input  logic       tick,
    input  logic       plus,
    input  logic       minus,
    output logic [7:0] pos      // offset binary, $80 = centre
);

    initial pos = 8'h80;

    always_ff @(posedge clk) begin
        if (rst)
            pos <= 8'h80;
        else if (tick) begin
            if (plus & ~minus)
                pos <= (pos > 8'hFC) ? 8'hFF : pos + 8'd3;
            else if (minus & ~plus)
                pos <= (pos < 8'h03) ? 8'h00 : pos - 8'd3;
            else if (pos > 8'h83)  pos <= pos - 8'd3;
            else if (pos < 8'h7D)  pos <= pos + 8'd3;
            else                   pos <= 8'h80;
        end
    end

endmodule
