// s32_gun_aim.sv — the aim of Alien3's two positional guns, as the four
// MSM6253 channels of the 837-7536 A/D board read it.
//
// References:
//   MAME latest master src/mame/sega/segas32.cpp INPUT_PORTS_START(alien3):
//     ANALOG1/ANALOG2 P1 gun X/Y, ANALOG3/ANALOG4 P2 gun X/Y
//     (IPT_AD_STICK_X/Y, centre $80; Y PORT_MINMAX(0x01, 0xff));
//     sega_system32_analog: adc.set_input_tag<0..3>("ANALOG1".."ANALOG4").
//   ROM_START(alien3) comment: "A/D BD NO. 837-7536" (Rad Mobile's board).
//   docs/alien3-bringup.md §3. Bench: sim/s32_gun_aim.
//   INPUT_PORTS_START(jpark): the same four ports with no PORT_MINMAX, so
//     Jurassic Park's Y runs $00-$FF (y_lo = $00; docs/jpark-bringup.md §3).
//
// Each gun turns two potentiometers, so the converter reads its position:
// X left $00 .. right $FF, Y top .. bottom, never below y_lo in Y. A mounted gun
// stays where it is pointed, so each gun has ONE aim, and whichever control
// moved last sets it:
//   - the player's left analog stick, or a lightgun reporting its aim as
//     that stick, is an absolute pointer: $80 + its value. While it has the
//     aim, the aim is its value exactly, every count, with no dead zone (a
//     lightgun has to track through the middle of the screen too).
//   - the d-pad moves the aim 3 counts per `tick` (S32.sv's adc_tick,
//     ~250 Hz: ~0.34 s across the range), and for P1 the mouse moves it one
//     count per mouse count. Either takes the aim from the stick, and it
//     stays where it is left.
//   - the stick takes the aim back once it moves more than STICK_GRAB counts
//     on either axis from where it stood when it lost it, so a thumbstick
//     resting slightly off centre does not drag a d-pad aim back.
// That is the default, `rel` = 0. With `rel` = 1, 2 or 3 (S32.sv's OSD
// "Stick aim", Relative slow / medium / fast) the stick instead MOVES the
// aim, as the d-pad does, and the aim stays where it is left: every `tick`
// each axis adds its deflection x 1, 2 or 4 / 128 counts (|deflection| < 8
// is a dead zone; the fraction carries over, starting from one half so the
// two directions round alike), so full deflection crosses
// the range in ~1.0 / 0.5 / 0.26 s at ~250 Hz. The stick then never owns
// the aim, which suits a thumbstick but not a lightgun, which needs 0. The
// d-pad and the mouse work as before in every mode. Changing the mode keeps
// the aim where it stands.
// With `win` = 1 (Jurassic Park), every aim that is MOVED (relative stick,
// d-pad, mouse) stays inside $40-$C0 on both axes, and the relative stick
// moves at half the count rate. The game maps only that window to the
// screen and pins the sight to the edge outside it: its sight set-up at
// $C8C86 / $C8D76 takes each gun's limits from R25+$763C / $7640, $40/$C0
// on a fresh EEPROM (the input test's STICK LEFT/RIGHT MAX), and $C8B83
// clamps (docs/jpark-bringup.md §3). Without the window a moved aim walks
// on to $00/$FF, so the sight sits in the corner until the aim comes back
// a quarter of the range, and each count crosses twice Alien3's distance.
// That made relative aim stick to the corners and jump (owner, silicon
// 2026-11-09). Half the rate gives the same sight speed as Alien3's. The
// stick as a pointer (rel 0) is untouched: it keeps the whole range
// exactly, as the potentiometers do, for a lightgun. A GUN ADJUSTMENT that
// sets limits outside $40-$C0 puts the screen edge beyond a moved aim's
// reach; the stick pointer still reaches it.
// Reset centres the aim and gives it to the stick. The game maps the range
// to the screen with its own GUN ADJUSTMENT (service mode; the factory
// EEPROM carries a calibration), which also calibrates a lightgun. The rates,
// the grab threshold and the mouse scale are usability settings, not
// hardware.
//
// Cost: per gun an 8-bit X/Y aim, the stick's reference X/Y, an owner bit
// and two 8-bit relative-mode fractions; their step/clamp adders and
// compares.
//
// Timing: the stick, y_lo, rel and win go through one register stage
// (p_q, ylo_q, rel_q, win_q), and so does the relative step: sx_q / sy_q
// hold fraction + scaled deflection, worked out every clock, so a tick only
// adds their whole part to the aim. Without that, stick -> dead zone ->
// shift -> fraction add -> clamp -> d-pad step -> mouse add -> window was
// one 15.5 ns path, and it failed setup by up to 2.6 ns on all six seeds
// of the 0450da2 publish sweep (core/archive/publish_sweep_20261109_jpaim.out).
// The stage costs one clock (15.5 ns) of input lag, far below one MiSTer
// joystick report. sx_q / sy_q read the fraction one clock late, which is
// exact as long as two ticks are at least two clocks apart; S32.sv's
// adc_tick is ~250 Hz, the bench's two clocks.

module s32_gun_aim #(
    parameter logic [7:0] STICK_GRAB = 8'd4
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        tick,          // d-pad step strobe
    input  logic [7:0]  y_lo,          // Y's lowest value (Alien3 $01)
    input  logic [1:0]  rel,           // 0 stick points; 1-3 stick moves
    input  logic        win,           // 1: moved aims in $40-$C0, half rate
    input  logic [3:0]  dpad1,         // MiSTer order: [0]R [1]L [2]D [3]U
    input  logic [3:0]  dpad2,
    input  logic [15:0] stick1,        // left stick: [7:0] X, [15:8] Y,
    input  logic [15:0] stick2,        //   signed, positive right / down
    input  logic        mouse_ev,      // one PS/2 packet (P1 only)
    input  logic [8:0]  mouse_dx,      // signed, positive right
    input  logic [8:0]  mouse_dy,      // signed, positive UP
    output logic [31:0] ain            // {P2 Y, P2 X, P1 Y, P1 X}
);

    function automatic [7:0] aim_step (input [7:0] v, input up, input dn,
                                       input [7:0] lo);
        aim_step = (up & ~dn) ? ((v > 8'hFC) ? 8'hFF : v + 8'd3)
                 : (dn & ~up) ? ((v < lo + 8'd3) ? lo : v - 8'd3) : v;
    endfunction
    function automatic [7:0] aim_add (input [7:0] v, input [9:0] d,
                                      input [7:0] lo);
        logic signed [10:0] s;
        s = $signed({3'b000, v}) + $signed({d[9], d});
        aim_add = (s > 11'sd255) ? 8'hFF
                : (s < $signed({3'b000, lo})) ? lo : s[7:0];
    endfunction
    // the stick as a pointer: {Y, X}, Y kept at or above y_lo as MAME's
    // port is
    function automatic [15:0] point (input [15:0] stick, input [7:0] lo);
        logic [7:0] y;
        y = stick[15:8] ^ 8'h80;
        point = {(y < lo) ? lo : y, stick[7:0] ^ 8'h80};
    endfunction
    function automatic logic far (input [7:0] a, input [7:0] b);
        far = ((a > b) ? a - b : b - a) > STICK_GRAB;
    endfunction

    // relative mode: a stick axis' deflection, dead-zoned, times the rate,
    // in 1/256 counts: x 2/4/8 (1, 2, 4 per 128), or half that with `w`
    function automatic signed [11:0] rel_in (input [7:0] v, input [1:0] r,
                                             input w);
        logic signed [11:0] d;
        d = ($signed(v) > 8'sd7 || $signed(v) < -8'sd7)
          ? $signed({{4{v[7]}}, v}) : 12'sd0;
        if (!w) d = d <<< 1;
        rel_in = (r == 2'd3) ? d <<< 2 : (r == 2'd2) ? d <<< 1 : d;
    endfunction
    // Jurassic Park's window for a moved aim
    function automatic [7:0] in_win (input [7:0] v, input w);
        in_win = !w ? v : (v < 8'h40) ? 8'h40 : (v > 8'hC0) ? 8'hC0 : v;
    endfunction

    logic [15:0] aim [0:1];                  // {Y, X}
    logic  [7:0] frac [0:1][0:1];            // [gun][X,Y] 1/256 counts
    logic [15:0] ref_q [0:1];                // the stick when it lost the aim
    logic        own [0:1];                  // 1 = the stick has the aim
    // input stage (see Timing above)
    logic [15:0] p_q [0:1];                  // point(stick)
    logic signed [11:0] sx_q [0:1], sy_q [0:1];   // frac + rel_in(stick)
    logic  [7:0] ylo_q;                      // reload every clock, no power-up value
    logic  [1:0] rel_q;
    logic        win_q;
    initial for (int n = 0; n < 2; n++) begin
        aim[n] = 16'h8080; ref_q[n] = 16'h8080; own[n] = 1'b1;
        frac[n][0] = 8'h80; frac[n][1] = 8'h80;
        p_q[n] = 16'h8080; sx_q[n] = 12'sh080; sy_q[n] = 12'sh080;
    end

    always_ff @(posedge clk) begin
        ylo_q <= y_lo;
        rel_q <= rel;
        win_q <= win;
        for (int n = 0; n < 2; n++) begin
            p_q[n]  <= point(n == 0 ? stick1 : stick2, ylo_q);
            sx_q[n] <= $signed({4'd0, frac[n][0]})
                     + rel_in(n == 0 ? stick1[7:0]  : stick2[7:0],  rel_q, win_q);
            sy_q[n] <= $signed({4'd0, frac[n][1]})
                     + rel_in(n == 0 ? stick1[15:8] : stick2[15:8], rel_q, win_q);
        end
    end

    always_ff @(posedge clk) begin
        for (int n = 0; n < 2; n++) begin
            logic [15:0] p, a;
            logic [3:0]  dp;
            logic        dmove, mmove;
            logic signed [11:0] sx, sy;      // relative mode: frac + step
            p  = p_q[n];
            dp = (n == 0) ? dpad1 : dpad2;
            dmove = tick & |dp;
            mmove = (n == 0) & mouse_ev & (|mouse_dx | |mouse_dy);
            a = aim[n];
            // relative mode, a d-pad step or a mouse packet: the aim moves
            // from where it stands and stays there
            if (rel_q != 2'd0 || dmove || mmove) begin
                if (own[n]) a = p;           // carry on from the stick's aim
                if (rel_q != 2'd0 && tick) begin // the stick moves it
                    sx = sx_q[n];
                    sy = sy_q[n];
                    frac[n][0] <= sx[7:0];
                    frac[n][1] <= sy[7:0];
                    a[7:0]  = aim_add(a[7:0],  {{6{sx[11]}}, sx[11:8]}, 8'h00);
                    a[15:8] = aim_add(a[15:8], {{6{sy[11]}}, sy[11:8]}, ylo_q);
                end
                if (dmove) begin
                    a[7:0]  = aim_step(a[7:0],  dp[0], dp[1], 8'h00);  // R / L
                    a[15:8] = aim_step(a[15:8], dp[2], dp[3], ylo_q); // D / U
                end
                if (mmove) begin             // screen Y runs down
                    a[7:0]  = aim_add(a[7:0],  {mouse_dx[8], mouse_dx}, 8'h00);
                    a[15:8] = aim_add(a[15:8], -{mouse_dy[8], mouse_dy}, ylo_q);
                end
                a = {in_win(a[15:8], win_q), in_win(a[7:0], win_q)};
                aim[n] <= a;
                own[n] <= 1'b0;
                ref_q[n] <= p;
            end else if (own[n]) begin
                aim[n] <= p;
            end else if (far(p[7:0], ref_q[n][7:0]) || far(p[15:8], ref_q[n][15:8])) begin
                aim[n] <= p;
                own[n] <= 1'b1;
            end
        end
        if (rst) for (int n = 0; n < 2; n++) begin
            aim[n] <= 16'h8080; ref_q[n] <= 16'h8080; own[n] <= 1'b1;
        end
        // the fractions only carry while relative; reset re-halves them too
        if (rst || rel_q == 2'd0)
            for (int n = 0; n < 2; n++) begin
                frac[n][0] <= 8'h80; frac[n][1] <= 8'h80;
            end
    end

    // the stick's aim one clock after it moves; a held aim from its register
    assign ain = {own[1] ? p_q[1] : aim[1],
                  own[0] ? p_q[0] : aim[0]};

endmodule
