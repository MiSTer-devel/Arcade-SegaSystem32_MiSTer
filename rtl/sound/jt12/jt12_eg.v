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
    Date: 29-10-2018

    Modified 2026-11-13 for the Sega System 32 core (RetroShrimp): the
    envelope level at a key-off that arrives while SSG-EG has the output
    inverted (eg_koff_I below, and the one line that uses it). The ports
    are the original ones.

    While SSG-EG inverts an operator, its output attenuation is 200h minus
    the stored level. When the key goes off the chip stores that inverted
    value as the level and releases from it, so the sound carries on from
    where it was. The original file dropped the inversion and kept the
    stored level (jt12_eg_ctrl.v says so: "this can produce a glitch in
    the output"): a note released low on an inverted ramp jumped up to
    full level, one released near its top was cut by up to 48 dB.

    References:
      - Nuked-OPN2 ym3438.c, OPN2_EnvelopeADSR (traced from the YM3438
        die): ssg_level = eg_ssg_inv ? (512 - level) & 0x3ff : level;
        if (koff_event) level = ssg_level;
      - MAME ymfm_fm.ipp, fm_operator::start_release: "if attenuation if
        inverted due to SSG-EG, snap the inverted attenuation as the
        starting point".
    Check: tools/fm/fm_ssg_probe.py (docs/OPEN-QUESTIONS.md Q70).

    Also modified 2026-11-14: fresh_I and its two pipeline copies, which
    tell jt12_eg_pure that an attack begins in this pass, the only pass in
    which rates 62 and 63 zero the level (that file's header has the rule).
    An attack begins at a key-on and, while the key is held, in every pass
    in which SSG-EG is on without hold and the level has bit 9 set: the
    die's kon_event = (nkon && !okon) || (okon && eg_ssg_repeat_latch),
    with the repeat latch set from (eg_level & 0x200) && !(ssg_eg & 1) in
    any envelope state (Nuked-OPN2 OPN2_EnvelopeSSGEG and
    OPN2_EnvelopeADSR). In decay that is the SSG-EG restart jt12_eg_ctrl
    already makes; in an attack that starts from above 200h it matters
    only at rates 62 and 63. MAME's ymfm differs in that last case
    (start_attack returns at once in an attack); the die trace is followed.

    Also modified 2026-11-14: the envelope-off rule, off_I and its two
    pipeline copies. Outside an attack, unless an attack begins in this
    pass or SSG-EG's hold-up holds the level (the key down in mode B or
    D), an envelope whose level is "off" goes to release at 3FFh at once.
    Off is bit 9 under SSG-EG (the level at 200h or beyond) and the top
    six bits all set without it (3F0h, about 90 dB down). The level tested
    is the one the pass releases from (eg_koff_I). Under SSG-EG this is
    audible: in the hold-at-the-bottom modes 9 and F the chip falls silent
    where the original file held the level at 200h (about -48 dB) for as
    long as the key was down, and a released note goes silent at 200h
    where the original file carried on down at four levels a step.
    Reference: Nuked-OPN2 ym3438.c (traced from the YM3438 die),
    OPN2_EnvelopeADSR: eg_off = ssg_enable ? level >> 9 : (level & 0x3f0)
    == 0x3f0; "Envelope off": if (!kon_event && !eg_ssg_hold_up_latch &&
    eg_state != eg_num_attack && eg_off) { nextstate = eg_num_release;
    nextlevel = 0x3ff; }, with the hold-up latch from OPN2_EnvelopeSSGEG
    (eg_kon_latch && ((ssg_eg & 7) == 5 || (ssg_eg & 7) == 3)). The
    forced release also clears the SSG-EG inversion, as the chip's does
    for these modes (its eg_ssg_inv is 0 for 9 and F and after a key-off).
    Check: tools/fm/fm_ssg_probe.py against Nuked-OPN2 (OPEN-QUESTIONS
    Q70).

    */

module jt12_eg (
    input               rst,
    input               clk,
    input               clk_en /* synthesis direct_enable */,
    input               zero,
    input               eg_stop,
    // envelope configuration
    input       [4:0]   keycode_II,
    input       [4:0]   arate_I, // attack  rate
    input       [4:0]   rate1_I, // decay   rate
    input       [4:0]   rate2_I, // sustain rate
    input       [3:0]   rrate_I, // release rate
    input       [3:0]   sl_I,   // sustain level
    input       [1:0]   ks_II,     // key scale
    // SSG operation
    input               ssg_en_I,
    input       [2:0]   ssg_eg_I,
    // envelope operation
    input               keyon_I,
    // envelope number
    input       [6:0]   lfo_mod,
    input               amsen_IV,
    input       [1:0]   ams_IV,
    input       [6:0]   tl_IV,

    output  reg [9:0]   eg_V,
    output  reg         pg_rst_II
);

parameter num_ch=6;

wire [14:0] eg_cnt;

jt12_eg_cnt u_egcnt(
    .rst    ( rst   ),
    .clk    ( clk   ),
    .clk_en ( clk_en & ~eg_stop ),
    .zero   ( zero  ),
    .eg_cnt ( eg_cnt)
);

wire keyon_last_I;
wire keyon_now_I  = !keyon_last_I && keyon_I;
wire keyoff_now_I = keyon_last_I && !keyon_I;

wire cnt_in_II, cnt_lsb_II, step_II, pg_rst_I;

wire ssg_inv_in_I, ssg_inv_out_I;
reg  ssg_inv_II, ssg_inv_III, ssg_inv_IV;
wire [2:0] state_in_I, state_next_I;

reg attack_II, attack_III;
wire [4:0] base_rate_I;
reg  [4:0] base_rate_II;
wire  [5:0] rate_out_II;
reg  [5:1] rate_in_III;
reg step_III, ssg_en_II, ssg_en_III;
wire sum_out_II;
reg sum_in_III;

wire [9:0] eg_in_I, pure_eg_out_III, eg_next_III, eg_out_IV;
reg  [9:0] eg_in_II, eg_in_III, eg_in_IV;

// Modified 2026-11-13 (see the header): a key-off during an inverted SSG-EG
// phase takes the inverted value as the level the release starts from.
wire [9:0] eg_koff_I = ( keyoff_now_I && ssg_inv_in_I ) ?
                       ( 10'h200 - eg_in_I ) : eg_in_I;

// Modified 2026-11-14 (see the header): an attack begins in this pass
wire fresh_I = state_next_I[0] & ( keyon_now_I |
               ( keyon_last_I & keyon_I & ssg_en_I & eg_in_I[9] & ~ssg_eg_I[0] ) );
reg  fresh_II, fresh_III;

// Modified 2026-11-14 (see the header): the envelope-off rule
wire eg_off_I   = ssg_en_I ? eg_koff_I[9] : &eg_koff_I[9:4];
wire kon_ev_I   = keyon_now_I | ( keyon_last_I & ssg_en_I & eg_in_I[9] & ~ssg_eg_I[0] );
wire hold_up_I  = keyon_I & ssg_en_I & ( ssg_eg_I==3'b101 || ssg_eg_I==3'b011 );
wire off_I      = eg_off_I & ~kon_ev_I & ~hold_up_I & ~state_in_I[0];
wire [2:0] state_eg_I = off_I ? 3'b000 : state_next_I;   // RELEASE
reg  off_II, off_III;



jt12_eg_comb u_comb(
    ///////////////////////////////////
    // I
    .keyon_now      ( keyon_now_I   ),
    .keyoff_now     ( keyoff_now_I  ),
    .state_in       ( state_in_I    ),
    .eg_in          ( eg_in_I       ),
    // envelope configuration   
    .arate          ( arate_I       ), // attack  rate
    .rate1          ( rate1_I       ), // decay   rate
    .rate2          ( rate2_I       ), // sustain rate
    .rrate          ( rrate_I       ),
    .sl             ( sl_I          ),   // sustain level
    // SSG operation
    .ssg_en         ( ssg_en_I      ),
    .ssg_eg         ( ssg_eg_I      ),
    // SSG output inversion
    .ssg_inv_in     ( ssg_inv_in_I  ),
    .ssg_inv_out    ( ssg_inv_out_I ),

    .base_rate      ( base_rate_I   ),
    .state_next     ( state_next_I  ),
    .pg_rst         ( pg_rst_I      ),
    ///////////////////////////////////
    // II
    .step_attack    ( attack_II     ),
    .step_rate_in   ( base_rate_II  ),
    .keycode        ( keycode_II    ),
    .eg_cnt         ( eg_cnt        ),
    .cnt_in         ( cnt_in_II     ),
    .ks             ( ks_II         ),
    .cnt_lsb        ( cnt_lsb_II    ),
    .step           ( step_II       ),
    .step_rate_out  ( rate_out_II   ),
    .sum_up_out     ( sum_out_II    ),
    ///////////////////////////////////
    // III
    .pure_attack    ( attack_III        ),
    .pure_fresh     ( fresh_III         ),
    .pure_step      ( step_III          ),
    .pure_rate      ( rate_in_III[5:1]  ),
    .pure_ssg_en    ( ssg_en_III        ), 
    .pure_eg_in     ( eg_in_III         ),
    .pure_eg_out    ( pure_eg_out_III   ),
    .sum_up_in      ( sum_in_III        ),
    ///////////////////////////////////
    // IV
    .lfo_mod        ( lfo_mod       ),
    .amsen          ( amsen_IV      ),
    .ams            ( ams_IV        ),
    .tl             ( tl_IV         ),
    .final_ssg_inv  ( ssg_inv_IV    ), 
    .final_eg_in    ( eg_in_IV      ),
    .final_eg_out   ( eg_out_IV     )
);

always @(posedge clk) if(clk_en) begin
    eg_in_II    <= eg_koff_I;
    attack_II   <= state_eg_I[0];
    fresh_II    <= fresh_I;
    off_II      <= off_I;
    base_rate_II<= base_rate_I;
    ssg_en_II   <= ssg_en_I;
    ssg_inv_II  <= ssg_inv_out_I & ~off_I;
    pg_rst_II   <= pg_rst_I;

    eg_in_III   <= eg_in_II;
    attack_III  <= attack_II;
    fresh_III   <= fresh_II;
    off_III     <= off_II;
    rate_in_III <= rate_out_II[5:1];
    ssg_en_III  <= ssg_en_II;
    ssg_inv_III <= ssg_inv_II;
    step_III    <= step_II;
    sum_in_III  <= sum_out_II;

    ssg_inv_IV  <= ssg_inv_III;
    eg_in_IV    <= off_III ? 10'h3FF : pure_eg_out_III;
    eg_V        <= eg_out_IV;
end

jt12_sh #( .width(1), .stages(4*num_ch) ) u_cntsh(
    .clk    ( clk       ),
    .clk_en ( clk_en    ),
    .din    ( cnt_lsb_II),
    .drop   ( cnt_in_II )
);

jt12_sh_rst #( .width(10), .stages(4*num_ch-3), .rstval(1'b1) ) u_egsh(
    .clk    ( clk       ),
    .clk_en ( clk_en    ),
    .rst    ( rst       ),
    .din    ( eg_in_IV  ),
    .drop   ( eg_in_I   )
);

jt12_sh_rst #( .width(3), .stages(4*num_ch), .rstval(1'b1) ) u_egstate(
    .clk    ( clk       ),
    .clk_en ( clk_en    ),
    .rst    ( rst       ),
    .din    ( state_eg_I    ),   // Modified 2026-11-14 (see the header)
    .drop   ( state_in_I    )
);

jt12_sh_rst #( .width(1), .stages(4*num_ch-3), .rstval(1'b0) ) u_ssg_inv(
    .clk    ( clk           ),
    .clk_en ( clk_en        ),
    .rst    ( rst           ),
    .din    ( ssg_inv_IV    ),
    .drop   ( ssg_inv_in_I  )
);

jt12_sh_rst #( .width(1), .stages(4*num_ch), .rstval(1'b0) ) u_konsh(
    .clk    ( clk       ),
    .clk_en ( clk_en    ),
    .rst    ( rst       ),  
    .din    ( keyon_I   ),
    .drop   ( keyon_last_I  )
);


endmodule // jt12_eg