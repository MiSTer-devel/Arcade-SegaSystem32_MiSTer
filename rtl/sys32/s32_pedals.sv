// s32_pedals.sv — the driving cabinets' accelerator and brake, as A/D
// channels 1 and 2 of the 837-7536 board read them.
//
// References:
//   MAME latest master src/mame/sega/segas32.cpp INPUT_PORTS_START(radm):
//     ANALOG2 IPT_PEDAL (accelerator), ANALOG3 IPT_PEDAL2 (brake), both
//     released $00; the same channels in (radr), (slipstrm), (f1lap) and
//     (f1en). docs/radm-bringup.md. Bench: sim/s32_pedals.
//   MiSTer Main input.cpp (QUIRK_WHEEL, mister_framework/main @915ca33,
//     lines 3952-3985): a recognised wheel sends its steering on the left
//     stick X, its accelerator on the LEFT stick Y and its brake on the
//     RIGHT stick Y, each pedal 0 released .. -127 fully pressed (a
//     wheel with one shared pedal axis is split onto the same two). So a
//     wheel's brake pedal arrives as the right stick pushed "up".
//
// Each pedal is a potentiometer converted continuously, so each channel is
// the control's current travel:
//   accelerator: button 1 (full), or the left stick pushed up;
//   brake:       button 2 (full), or the left stick pulled down, or the
//                right stick pushed up (a wheel's brake pedal), whichever
//                is further.
// A stick's half axis (0..127, from a gamepad or a wheel's pedal) is scaled
// x2 onto the pedal's $00..$FE, -128 reads $FF; |value| < 8 is a dead zone.
// The mapping is a usability setting, not hardware.
//
// Cost: combinational; two negators, a compare and the muxes.

module s32_pedals (
    input  logic [7:0] ly,          // left stick Y, signed, negative = up
    input  logic [7:0] ry,          // right stick Y, signed, negative = up
    input  logic       btn_accel,
    input  logic       btn_brake,
    output logic [7:0] accel,
    output logic [7:0] brake
);

    function automatic [7:0] dz (input [7:0] v);
        dz = ($signed(v) > 8'sd7 || $signed(v) < -8'sd7) ? v : 8'd0;
    endfunction
    // travel of a half axis: up (negative) or down (positive), x2, saturating
    function automatic [7:0] up_travel (input [7:0] v);
        logic [8:0] t;
        t = $signed(v) < 0 ? {-v, 1'b0} : 9'd0;
        up_travel = t[8] ? 8'hFF : t[7:0];
    endfunction
    function automatic [7:0] dn_travel (input [7:0] v);
        logic [8:0] t;
        t = $signed(v) > 0 ? {v, 1'b0} : 9'd0;
        dn_travel = t[8] ? 8'hFF : t[7:0];
    endfunction

    wire [7:0] l_up = up_travel(dz(ly));
    wire [7:0] l_dn = dn_travel(dz(ly));
    wire [7:0] r_up = up_travel(dz(ry));
    assign accel = btn_accel ? 8'hFF : l_up;
    assign brake = btn_brake ? 8'hFF : (r_up > l_dn) ? r_up : l_dn;

endmodule
