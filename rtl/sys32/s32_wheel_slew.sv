// s32_wheel_slew.sv — the wheel channel of the 837-7536 A/D board turns
// no faster than a wheel can: the value handed to the MSM6253 model moves
// toward the control's position by at most 3 counts a `tick`.
//
// Why: Rad Mobile filters its wheel reading in software (program $70333,
// mirrored every $20000; docs/radm-bringup.md §3). Every second frame it
// converts the four channels into work RAM $20F028-$20F02B and compares
// the new wheel byte with the last one it accepted ($20F02C): when the
// change, modulo 256, is outside -$3F..+$40 it throws the reading away and
// writes the old value back over it ($7034F-$70358). A cabinet's wheel,
// a potentiometer on a sprung column, cannot cross $40 counts in two
// frames, so the filter only drops noise there. A thumbstick crosses it in
// one: let the stick go from full lock and the reading jumps back to $80,
// is refused, and the car keeps full lock until the stick comes within
// $40 of it again (a user's report, 2026-11-14: Rad Mobile "oversteers or
// pulls into the right or left"; Rad Rally has no such filter). MAME shows
// it the same way (tools/mame/radm_wheel_probe.lua: the wheel snapped
// $FF -> $80 leaves $20F02C at $FF). F1 Exhaust Note and F1 Super Lap run
// the same comparison but go on with the raw byte (their filtered copy has
// no other reader), so they never hold it.
//
// Rate: S32.sv's adc_tick is 2^18 clk_sys (~246 Hz), so 3 counts a tick is
// ~737 counts a second, ~12.4 a frame: ~25 between two of Rad Mobile's
// reads, and inside $3F for gaps up to five frames. Centre to full lock
// takes ~0.17 s, the rate the d-pad already turns the wheel at
// (s32_dpad_axis). A usability setting standing in for the column's
// mechanics, not a measured figure. Every driving game on the A/D board
// takes it; none can see a faster wheel on its own cabinet.
//
// Bench: sim/s32_wheel_slew (the step bound, the target reached exactly,
// reset, and Rad Mobile's filter fed from it never refusing a reading).
//
// Cost: an 8-bit register, a subtractor and two compares.

module s32_wheel_slew (
    input  logic       clk,
    input  logic       rst,
    input  logic       tick,
    input  logic [7:0] target,   // the control's position, $80 = centre
    output logic [7:0] pos       // what the A/D board converts
);

    initial pos = 8'h80;

    always_ff @(posedge clk) begin
        if (rst)
            pos <= 8'h80;
        else if (tick) begin
            if (target > pos)
                pos <= (target - pos > 8'd3) ? pos + 8'd3 : target;
            else if (target < pos)
                pos <= (pos - target > 8'd3) ? pos - 8'd3 : target;
        end
    end

endmodule
