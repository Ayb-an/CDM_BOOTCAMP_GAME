/*
 * Battleship VGA - 2 player hot-seat game for Tiny Tapeout (640x480 VGA + Gamepad Pmod)
 * Copyright (c) 2026 <your name>
 * SPDX-License-Identifier: Apache-2.0
 *
 * Board: 5x5 per player.  Fleet per player: one 3-cell ship + two 2-cell ships.
 *
 * Screen layout
 *   LEFT  board (cyan)   = Player 1's area
 *   RIGHT board (orange) = Player 2's area
 *   Big number at the top = whose turn it is (1 or 2)
 *   Row under each board  = placement: ships placed / battle: hits landed (7 needed)
 *
 * Phase 0 - HELP  : on-screen instructions (controls + how to play).
 *                   Press A or Start to begin placing ships.
 * Phase 1 - PLACE : each player secretly places their fleet (the other looks away).
 *                   D-pad = move, B (or X/Y) = rotate, A = place ship.
 *                   Green preview = OK, red preview = can't place there.
 * Phase 2 - BATTLE: players take turns, one shot each.  Cursor is yellow.
 *                   D-pad = move, A = fire.
 *                   White dot = miss, red cell with white X = hit.
 *                   After every shot the game pauses on a "YOUR TURN" screen so
 *                   the next player can pick up the pad -- press A to continue.
 * Phase 3 - OVER  : winner's number + frame blink, unhit ships are revealed.
 *                   A or Start = new game.  Start restarts at any time.
 */

`default_nettype none

module tt_um_vga_example (
    input  wire [7:0] ui_in,    // Dedicated inputs  (gamepad pmod on ui_in[6:4])
    output wire [7:0] uo_out,   // Dedicated outputs (VGA)
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered
    input  wire       clk,      // clock (25.175 MHz)
    input  wire       rst_n     // reset_n - low to reset
);

    // ------------------------------------------------------------------
    // Settings you can tweak
    // ------------------------------------------------------------------
    localparam       HIT_AGAIN  = 1'b0;  // 1 = a hit lets the same player shoot again
    localparam [2:0] TOTAL_HITS = 3'd7;  // total ship cells per fleet (3 + 2 + 2)

    localparam [1:0] PH_PLACE  = 2'd0;
    localparam [1:0] PH_BATTLE = 2'd1;
    localparam [1:0] PH_OVER   = 2'd2;
    localparam [1:0] PH_HELP   = 2'd3;

    // ------------------------------------------------------------------
    // VGA timing
    // ------------------------------------------------------------------
    wire       hsync, vsync, video_active;
    wire [9:0] hpos, vpos;

    hvsync_generator hvsync_gen (
        .clk       (clk),
        .reset     (~rst_n),
        .hsync     (hsync),
        .vsync     (vsync),
        .display_on(video_active),
        .hpos      (hpos),
        .vpos      (vpos)
    );

    // ------------------------------------------------------------------
    // Gamepad Pmod (driver comes from gamepad_pmod.v)
    // ------------------------------------------------------------------
    wire inp_b, inp_y, inp_select, inp_start;
    wire inp_up, inp_down, inp_left, inp_right;
    wire inp_a, inp_x, inp_l, inp_r;

    gamepad_pmod_single gamepad (
        .clk       (clk),
        .rst_n     (rst_n),
        .pmod_data (ui_in[6]),
        .pmod_clk  (ui_in[5]),
        .pmod_latch(ui_in[4]),
        .b(inp_b), .y(inp_y), .select(inp_select), .start(inp_start),
        .up(inp_up), .down(inp_down), .left(inp_left), .right(inp_right),
        .a(inp_a), .x(inp_x), .l(inp_l), .r(inp_r)
    );

    // Buttons are sampled once per frame; "press" = new press this frame.
    wire [11:0] btn = {inp_r, inp_l, inp_x, inp_y, inp_a, inp_b,
                       inp_start, inp_select, inp_right, inp_left, inp_down, inp_up};
    reg  [11:0] btn_prev;
    wire [11:0] press = btn & ~btn_prev;

    wire press_up    = press[0];
    wire press_down  = press[1];
    wire press_left  = press[2];
    wire press_right = press[3];
    wire press_start = press[5];
    wire press_b     = press[6];
    wire press_a     = press[7];
    wire press_y     = press[8];
    wire press_x     = press[9];

    wire frame_tick = (hpos == 10'd0) && (vpos == 10'd0);

    // ------------------------------------------------------------------
    // Game state
    // ------------------------------------------------------------------
    reg [24:0] ships_a, ships_b;   // fleet maps      (bit = y*5 + x)
    reg [24:0] shots_a, shots_b;   // shots fired BY player A / B
    reg [2:0]  hits_a,  hits_b;    // hits landed BY player A / B
    reg [1:0]  phase;
    reg        turn;               // placing player / shooting player / winner (0 = P1, 1 = P2)
    reg [1:0]  ship_n;             // ships already placed by the current placer (0..2)
    reg [2:0]  cur_x, cur_y;       // cursor 0..4
    reg        orient;             // 0 = horizontal, 1 = vertical
    reg [5:0]  frame_cnt;          // free running frame counter (blinking)
    reg        battle_wait;        // 1 = paused on a "YOUR TURN" hand-off screen
    reg [6:0]  wait_cnt;           // frames spent on the hand-off screen so far

    localparam [6:0] HANDOFF_FRAMES = 7'd60;  // ~1 second at 60Hz; auto-continues

    // ---- placement helpers ----
    wire [24:0] my_ships = turn ? ships_b : ships_a;

    wire [2:0] x1 = cur_x + (orient ? 3'd0 : 3'd1);
    wire [2:0] y1 = cur_y + (orient ? 3'd1 : 3'd0);
    wire [2:0] x2 = cur_x + (orient ? 3'd0 : 3'd2);
    wire [2:0] y2 = cur_y + (orient ? 3'd2 : 3'd0);

    wire has3 = (ship_n == 2'd0);                       // first ship has 3 cells, others 2
    wire in1  = (x1 <= 3'd4) && (y1 <= 3'd4);
    wire in2  = (x2 <= 3'd4) && (y2 <= 3'd4);
    wire fits = in1 && (~has3 || in2);

    wire [24:0] cell0;
    wire [24:0] place_mask;
    genvar gi;
    generate
        for (gi = 0; gi < 25; gi = gi + 1) begin : g_cells
            localparam [2:0] GX = gi % 5;
            localparam [2:0] GY = gi / 5;
            assign cell0[gi]      = (cur_x == GX) && (cur_y == GY);
            assign place_mask[gi] = cell0[gi]
                                  | (in1 && (x1 == GX) && (y1 == GY))
                                  | (has3 && in2 && (x2 == GX) && (y2 == GY));
        end
    endgenerate
    wire place_ok = fits && ((place_mask & my_ships) == 25'd0);

    // ---- battle helpers ----
    wire [24:0] my_shots    = turn ? shots_b : shots_a;
    wire [24:0] enemy_ships = turn ? ships_a : ships_b;
    wire already  = |(my_shots    & cell0);
    wire is_hit   = |(enemy_ships & cell0);
    wire last_hit = is_hit && ((turn ? hits_b : hits_a) == (TOTAL_HITS - 3'd1));

    wire restart = press_start | ((phase == PH_OVER) & press_a);

    // ------------------------------------------------------------------
    // Game logic (runs once per frame)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (~rst_n) begin
            ships_a     <= 25'd0;
            ships_b     <= 25'd0;
            shots_a     <= 25'd0;
            shots_b     <= 25'd0;
            hits_a      <= 3'd0;
            hits_b      <= 3'd0;
            phase       <= PH_HELP;
            turn        <= 1'b0;
            ship_n      <= 2'd0;
            cur_x       <= 3'd0;
            cur_y       <= 3'd0;
            orient      <= 1'b0;
            btn_prev    <= 12'd0;
            frame_cnt   <= 6'd0;
            battle_wait <= 1'b0;
            wait_cnt    <= 7'd0;
        end else if (frame_tick) begin
            btn_prev  <= btn;
            frame_cnt <= frame_cnt + 6'd1;

            if (restart) begin
                ships_a     <= 25'd0;
                ships_b     <= 25'd0;
                shots_a     <= 25'd0;
                shots_b     <= 25'd0;
                hits_a      <= 3'd0;
                hits_b      <= 3'd0;
                phase       <= PH_PLACE;
                turn        <= 1'b0;
                ship_n      <= 2'd0;
                cur_x       <= 3'd0;
                cur_y       <= 3'd0;
                orient      <= 1'b0;
                battle_wait <= 1'b0;
                wait_cnt    <= 7'd0;
            end else begin
                // cursor movement (clamped to the 5x5 grid); frozen on the help
                // screen, the game-over screen, and during the turn hand-off pause
                if (phase == PH_PLACE || (phase == PH_BATTLE && !battle_wait)) begin
                    if (press_left  && cur_x != 3'd0) cur_x <= cur_x - 3'd1;
                    if (press_right && cur_x != 3'd4) cur_x <= cur_x + 3'd1;
                    if (press_up    && cur_y != 3'd0) cur_y <= cur_y - 3'd1;
                    if (press_down  && cur_y != 3'd4) cur_y <= cur_y + 3'd1;
                end

                if (phase == PH_HELP) begin
                    if (press_a) phase <= PH_PLACE;

                end else if (phase == PH_PLACE) begin
                    if (press_b | press_x | press_y) orient <= ~orient;

                    if (press_a && place_ok) begin
                        if (~turn) ships_a <= ships_a | place_mask;
                        else       ships_b <= ships_b | place_mask;

                        if (ship_n == 2'd2) begin       // fleet complete
                            ship_n <= 2'd0;
                            cur_x  <= 3'd0;
                            cur_y  <= 3'd0;
                            orient <= 1'b0;
                            if (~turn) begin
                                turn <= 1'b1;           // Player 2 places next
                            end else begin
                                turn  <= 1'b0;          // both done: Player 1 fires first
                                phase <= PH_BATTLE;
                            end
                        end else begin
                            ship_n <= ship_n + 2'd1;
                        end
                    end

                end else if (phase == PH_BATTLE) begin
                    if (battle_wait) begin
                        // briefly shows "YOUR TURN" so it's obvious the turn
                        // switched, then continues on its own -- no button
                        // press required (though A skips it early if you're
                        // in a hurry).
                        wait_cnt <= wait_cnt + 7'd1;
                        if (press_a || (wait_cnt >= HANDOFF_FRAMES))
                            battle_wait <= 1'b0;
                    end else if (press_a && !already) begin
                        if (~turn) shots_a <= shots_a | cell0;
                        else       shots_b <= shots_b | cell0;

                        if (is_hit) begin
                            if (~turn) hits_a <= hits_a + 3'd1;
                            else       hits_b <= hits_b + 3'd1;
                        end

                        if (last_hit) begin
                            phase <= PH_OVER;           // 'turn' stays = winner
                        end else if (HIT_AGAIN & is_hit) begin
                            // same player fires again immediately, no hand-off
                        end else begin
                            turn        <= ~turn;
                            battle_wait <= 1'b1;        // brief hand-off pause
                            wait_cnt    <= 7'd0;
                        end
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Rendering
    // ------------------------------------------------------------------
    // colours are {R[1:0], G[1:0], B[1:0]}
    localparam [5:0] C_BLACK  = 6'b00_00_00;
    localparam [5:0] C_SEA    = 6'b00_00_01;   // background / grid lines
    localparam [5:0] C_WATER  = 6'b00_01_10;   // empty cell
    localparam [5:0] C_P1     = 6'b00_11_11;   // cyan
    localparam [5:0] C_P2     = 6'b11_10_00;   // orange
    localparam [5:0] C_P1_DIM = 6'b00_01_01;
    localparam [5:0] C_P2_DIM = 6'b01_01_00;
    localparam [5:0] C_DIM    = 6'b01_01_01;   // grey
    localparam [5:0] C_SHIP   = 6'b10_10_10;   // ship (light grey)
    localparam [5:0] C_HIT    = 6'b11_00_00;   // red
    localparam [5:0] C_MISS   = 6'b11_11_11;   // white
    localparam [5:0] C_OK     = 6'b00_11_00;   // green
    localparam [5:0] C_BAD    = 6'b11_00_01;   // red/pink
    localparam [5:0] C_CURSOR = 6'b11_11_00;   // yellow

    localparam [9:0] BOARD_Y  = 10'd136;
    localparam [9:0] LEFT_X   = 10'd96;
    localparam [9:0] RIGHT_X  = 10'd384;
    localparam [9:0] BOARD_SZ = 10'd160;       // 5 cells * 32 px
    localparam [9:0] IND_Y    = 10'd328;       // indicator row under the boards
    localparam [9:0] DIG_X    = 10'd304;
    localparam [9:0] DIG_Y    = 10'd40;

    wire blink = frame_cnt[4];

    // ------------------------------------------------------------------
    // Tiny 5x7 text renderer, used only for the help screen and the two
    // short turn-hand-off / winner banners. Character codes 0-19 cover the
    // letters those messages need; 31 (or anything unlisted) renders blank.
    // ------------------------------------------------------------------
    function [4:0] font_row;
        input [4:0] ch;
        input [2:0] row;
        reg [34:0] g;
        begin
            case (ch)
                5'd0 : g = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001}; // A
                5'd1 : g = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110}; // B
                5'd2 : g = {5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111}; // C
                5'd3 : g = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110}; // D
                5'd4 : g = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111}; // E
                5'd5 : g = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000}; // F
                5'd6 : g = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001}; // H
                5'd7 : g = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111}; // I
                5'd8 : g = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111}; // L
                5'd9 : g = {5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001}; // M
                5'd10: g = {5'b10001,5'b11001,5'b10101,5'b10101,5'b10011,5'b10001,5'b10001}; // N
                5'd11: g = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110}; // O
                5'd12: g = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000}; // P
                5'd13: g = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001}; // R
                5'd14: g = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110}; // S
                5'd15: g = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100}; // T
                5'd16: g = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110}; // U
                5'd17: g = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100}; // V
                5'd18: g = {5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b11011,5'b10001}; // W
                5'd19: g = {5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100}; // Y
                default: g = 35'd0; // space / unknown -> blank
            endcase
            case (row)
                3'd0: font_row = g[34:30];
                3'd1: font_row = g[29:25];
                3'd2: font_row = g[24:20];
                3'd3: font_row = g[19:15];
                3'd4: font_row = g[14:10];
                3'd5: font_row = g[9:5];
                default: font_row = g[4:0];   // row 6 (and any stray value)
            endcase
        end
    endfunction

    // 8 fixed messages, 12 characters each (padded with space = code 31)
    function [4:0] msg_char;
        input [3:0] line_id;
        input [3:0] pos;
        begin
            case (line_id)
                4'd0: case (pos) // "BATTLESHIP"
                        4'd0:msg_char=1; 4'd1:msg_char=0; 4'd2:msg_char=15; 4'd3:msg_char=15;
                        4'd4:msg_char=8; 4'd5:msg_char=4; 4'd6:msg_char=14; 4'd7:msg_char=6;
                        4'd8:msg_char=7; 4'd9:msg_char=12; default: msg_char=31;
                      endcase
                4'd1: case (pos) // "PAD MOVE"
                        4'd0:msg_char=12; 4'd1:msg_char=0; 4'd2:msg_char=3; 4'd3:msg_char=31;
                        4'd4:msg_char=9;  4'd5:msg_char=11; 4'd6:msg_char=17; 4'd7:msg_char=4;
                        default: msg_char=31;
                      endcase
                4'd2: case (pos) // "B ROTATE"
                        4'd0:msg_char=1; 4'd1:msg_char=31; 4'd2:msg_char=13; 4'd3:msg_char=11;
                        4'd4:msg_char=15; 4'd5:msg_char=0; 4'd6:msg_char=15; 4'd7:msg_char=4;
                        default: msg_char=31;
                      endcase
                4'd3: case (pos) // "A FIRE"
                        4'd0:msg_char=0; 4'd1:msg_char=31; 4'd2:msg_char=5; 4'd3:msg_char=7;
                        4'd4:msg_char=13; 4'd5:msg_char=4; default: msg_char=31;
                      endcase
                4'd4: case (pos) // "PRESS START"
                        4'd0:msg_char=12; 4'd1:msg_char=13; 4'd2:msg_char=4; 4'd3:msg_char=14;
                        4'd4:msg_char=14; 4'd5:msg_char=31; 4'd6:msg_char=14; 4'd7:msg_char=15;
                        4'd8:msg_char=0; 4'd9:msg_char=13; 4'd10:msg_char=15; default: msg_char=31;
                      endcase
                4'd5: case (pos) // "YOUR TURN"
                        4'd0:msg_char=19; 4'd1:msg_char=11; 4'd2:msg_char=16; 4'd3:msg_char=13;
                        4'd4:msg_char=31; 4'd5:msg_char=15; 4'd6:msg_char=16; 4'd7:msg_char=13;
                        4'd8:msg_char=10; default: msg_char=31;
                      endcase
                4'd6: case (pos) // "PRESS A"
                        4'd0:msg_char=12; 4'd1:msg_char=13; 4'd2:msg_char=4; 4'd3:msg_char=14;
                        4'd4:msg_char=14; 4'd5:msg_char=31; 4'd6:msg_char=0; default: msg_char=31;
                      endcase
                default: case (pos) // line 7: "PLAYER WINS"
                        4'd0:msg_char=12; 4'd1:msg_char=8; 4'd2:msg_char=0; 4'd3:msg_char=19;
                        4'd4:msg_char=4; 4'd5:msg_char=13; 4'd6:msg_char=31; 4'd7:msg_char=18;
                        4'd8:msg_char=7; 4'd9:msg_char=10; 4'd10:msg_char=14; default: msg_char=31;
                      endcase
            endcase
        end
    endfunction

    // 1 = the pixel at (hpos_,vpos_) is lit for message `line_id` drawn with
    // its top-left corner at (tx,ty), scaled up by TXT_SCALE.
    localparam [3:0] TXT_SCALE = 4'd3;
    localparam [9:0] CHAR_W    = 10'd18;   // 6 * TXT_SCALE (5px glyph + 1px gap)
    localparam [9:0] CHAR_H    = 10'd21;   // 7 * TXT_SCALE

    function line_pixel;
        input [9:0] hpos_, vpos_, tx, ty;
        input [3:0] line_id;
        reg [9:0] rx, ry;
        reg [3:0] cidx, cx, cy;
        reg [4:0] frow;
        begin
            line_pixel = 1'b0;
            if (hpos_ >= tx && vpos_ >= ty) begin
                rx = hpos_ - tx;
                ry = vpos_ - ty;
                if (ry < CHAR_H && rx < 12*CHAR_W) begin
                    cidx = rx / CHAR_W;
                    cx   = (rx - cidx*CHAR_W) / TXT_SCALE;
                    cy   = ry / TXT_SCALE;
                    if (cx < 4'd5) begin
                        frow = font_row(msg_char(line_id, cidx), cy[2:0]);
                        line_pixel = frow[4-cx];
                    end
                end
            end
        end
    endfunction

    // ---- instructions screen (5 lines, centred) ----
    localparam [9:0] TXT_X   = 10'd212;   // (640 - 12*CHAR_W) / 2
    localparam [9:0] LINE_SP = 10'd32;

    wire help_l0 = line_pixel(hpos, vpos, TXT_X, 10'd90 + 0*LINE_SP, 4'd0);
    wire help_l1 = line_pixel(hpos, vpos, TXT_X, 10'd90 + 1*LINE_SP, 4'd1);
    wire help_l2 = line_pixel(hpos, vpos, TXT_X, 10'd90 + 2*LINE_SP, 4'd2);
    wire help_l3 = line_pixel(hpos, vpos, TXT_X, 10'd90 + 3*LINE_SP, 4'd3);
    wire help_l4 = line_pixel(hpos, vpos, TXT_X, 10'd90 + 4*LINE_SP, 4'd4);

    // ---- turn hand-off banner (2 lines, on a black box) ----
    localparam [9:0] WAIT_TY = 10'd190;
    wire wait_l0  = line_pixel(hpos, vpos, TXT_X, WAIT_TY,           4'd5);
    wire wait_l1  = line_pixel(hpos, vpos, TXT_X, WAIT_TY + LINE_SP, 4'd6);
    wire wait_box = (vpos >= WAIT_TY - 10'd8) && (vpos < WAIT_TY + 2*LINE_SP) &&
                    (hpos >= TXT_X  - 10'd8) && (hpos < TXT_X + 12*CHAR_W + 10'd8);

    // ---- winner banner (1 line, on a black box) ----
    localparam [9:0] WIN_TY = 10'd190;
    wire win_l0  = line_pixel(hpos, vpos, TXT_X, WIN_TY, 4'd7);
    wire win_box = (vpos >= WIN_TY - 10'd8) && (vpos < WIN_TY + LINE_SP) &&
                   (hpos >= TXT_X - 10'd8) && (hpos < TXT_X + 12*CHAR_W + 10'd8);

    // which board is the pixel in?
    wire in_rows  = (vpos >= BOARD_Y) && (vpos < BOARD_Y + BOARD_SZ);
    wire in_col_l = (hpos >= LEFT_X)  && (hpos < LEFT_X  + BOARD_SZ);
    wire in_col_r = (hpos >= RIGHT_X) && (hpos < RIGHT_X + BOARD_SZ);
    wire in_board = in_rows && (in_col_l || in_col_r);
    wire side     = in_col_r;                  // 0 = left/P1 board, 1 = right/P2 board

    wire [9:0] rel_x = hpos - (side ? RIGHT_X : LEFT_X);
    wire [9:0] rel_y = vpos - BOARD_Y;

    wire [2:0] cell_x = rel_x[7:5];
    wire [2:0] cell_y = rel_y[7:5];
    wire [4:0] in_x   = rel_x[4:0];
    wire [4:0] in_y   = rel_y[4:0];

    wire grid_line   = (in_x < 5'd2) || (in_y < 5'd2);
    wire cursor_edge = (in_x < 5'd3) || (in_x >= 5'd29) || (in_y < 5'd3) || (in_y >= 5'd29);
    wire dot         = (in_x >= 5'd12) && (in_x < 5'd20) && (in_y >= 5'd12) && (in_y < 5'd20);

    wire [4:0] dxy   = (in_x > in_y) ? (in_x - in_y) : (in_y - in_x);
    wire [5:0] sxy   = {1'b0, in_x} + {1'b0, in_y};
    wire       xmark = (dxy < 5'd4) || ((sxy >= 6'd28) && (sxy <= 6'd34));

    // per-cell lookups
    wire [24:0] side_shots   = side ? shots_b : shots_a;
    wire [24:0] side_targets = side ? ships_a : ships_b;
    wire [24:0] pix_onehot;
    genvar gj;
    generate
        for (gj = 0; gj < 25; gj = gj + 1) begin : g_pix
            localparam [2:0] PX = gj % 5;
            localparam [2:0] PY = gj / 5;
            assign pix_onehot[gj] = in_board && (cell_x == PX) && (cell_y == PY);
        end
    endgenerate

    wire shot_here   = |(side_shots   & pix_onehot);
    wire target_here = |(side_targets & pix_onehot);
    wire own_ship    = |(my_ships     & pix_onehot);
    wire prev_here   = |(place_mask   & pix_onehot);

    // frames around the boards
    wire in_outer_rows = (vpos >= BOARD_Y - 10'd4) && (vpos < BOARD_Y + BOARD_SZ + 10'd4);
    wire in_outer_l = in_outer_rows && (hpos >= LEFT_X  - 10'd4) && (hpos < LEFT_X  + BOARD_SZ + 10'd4);
    wire in_outer_r = in_outer_rows && (hpos >= RIGHT_X - 10'd4) && (hpos < RIGHT_X + BOARD_SZ + 10'd4);
    wire act_l = (turn == 1'b0);
    wire act_r = (turn == 1'b1);
    wire flash_off = (phase == PH_OVER) && !blink;

    // indicator row under the boards
    wire in_ind_row = (vpos >= IND_Y) && (vpos < IND_Y + 10'd16) && (in_col_l || in_col_r);

    // big player number (7-segment style)
    wire       in_digit = (hpos >= DIG_X) && (hpos < DIG_X + 10'd32) &&
                          (vpos >= DIG_Y) && (vpos < DIG_Y + 10'd48);
    wire [9:0] dig_x = hpos - DIG_X;
    wire [9:0] dig_y = vpos - DIG_Y;
    wire seg_a = (dig_y < 10'd6);
    wire seg_g = (dig_y >= 10'd21) && (dig_y < 10'd27);
    wire seg_d = (dig_y >= 10'd42);
    wire seg_b = (dig_x >= 10'd26) && (dig_y < 10'd24);
    wire seg_e = (dig_x < 10'd6)   && (dig_y >= 10'd24);
    wire seg_c = (dig_x >= 10'd26) && (dig_y >= 10'd24);
    wire digit_on = turn ? (seg_a | seg_b | seg_g | seg_e | seg_d)   // "2"
                         : (seg_b | seg_c);                          // "1"

    // placement icons under the board (3, 2, 2 cells wide)
    wire blk0   = (rel_x >= 10'd16)  && (rel_x < 10'd64);
    wire blk1   = (rel_x >= 10'd72)  && (rel_x < 10'd104);
    wire blk2   = (rel_x >= 10'd112) && (rel_x < 10'd144);
    wire blk_on = blk0 | blk1 | blk2;
    wire [1:0] blk_k = blk0 ? 2'd0 : (blk1 ? 2'd1 : 2'd2);

    // battle pips: 7 small squares = hits landed by that board's shooter
    wire [2:0] pip_hits = in_col_r ? hits_b : hits_a;
    wire [6:0] pip_on;
    wire [6:0] pip_lit;
    genvar gp;
    generate
        for (gp = 0; gp < 7; gp = gp + 1) begin : g_pips
            localparam [9:0] PIP_X = 4 + 22 * gp;
            localparam [2:0] PIP_I = gp;
            assign pip_on[gp]  = (rel_x >= PIP_X) && (rel_x < PIP_X + 10'd20);
            assign pip_lit[gp] = (pip_hits > PIP_I);
        end
    endgenerate

    reg [5:0] rgb;

    always @* begin
        rgb = C_BLACK;

        if (video_active) begin
            if (phase == PH_HELP) begin
                // ---- instructions screen ----
                rgb = C_BLACK;
                if (help_l0)                      rgb = C_MISS;                  // title
                if (help_l1 | help_l2 | help_l3)  rgb = C_SHIP;                  // controls
                if (help_l4)                      rgb = blink ? C_CURSOR : C_DIM; // blinking prompt

            end else begin
                rgb = C_SEA;

                // ---- player number ----
                if (in_digit && digit_on)
                    rgb = flash_off ? C_MISS : (turn ? C_P2 : C_P1);

                // ---- board frames (active player = bright) ----
                if (in_outer_l && !in_board)
                    rgb = act_l ? (flash_off ? C_MISS : C_P1) : C_P1_DIM;
                if (in_outer_r && !in_board)
                    rgb = act_r ? (flash_off ? C_MISS : C_P2) : C_P2_DIM;

                // ---- indicator row ----
                if (in_ind_row) begin
                    if (phase == PH_PLACE) begin
                        if (blk_on && (side == turn)) begin
                            if (blk_k < ship_n)       rgb = C_OK;
                            else if (blk_k == ship_n) rgb = blink ? C_CURSOR : (turn ? C_P2 : C_P1);
                            else                       rgb = C_DIM;
                        end
                    end else begin
                        if (|pip_on) rgb = (|(pip_on & pip_lit)) ? C_HIT : C_DIM;
                    end
                end

                // ---- boards ----
                if (in_board) begin
                    if (phase == PH_PLACE && side != turn) begin
                        rgb = C_BLACK;                       // hidden while the other player places
                    end else begin
                        rgb = C_WATER;
                        if (grid_line) begin
                            rgb = C_SEA;
                        end else if (phase == PH_PLACE) begin
                            if (own_ship)  rgb = C_SHIP;
                            if (prev_here) rgb = place_ok ? C_OK : C_BAD;
                        end else begin
                            if (shot_here) begin
                                if (target_here) rgb = xmark ? C_MISS : C_HIT;
                                else if (dot)    rgb = C_MISS;
                            end else if (phase == PH_OVER && target_here) begin
                                rgb = C_SHIP;                // reveal what was left
                            end
                            if (phase == PH_BATTLE && side == turn && !battle_wait &&
                                cell_x == cur_x && cell_y == cur_y && cursor_edge)
                                rgb = C_CURSOR;
                        end
                    end
                end

                // ---- turn hand-off pause ----
                if (phase == PH_BATTLE && battle_wait) begin
                    if (wait_box)          rgb = C_BLACK;
                    if (wait_l0 | wait_l1) rgb = turn ? C_P2 : C_P1;
                end

                // ---- winner banner ----
                if (phase == PH_OVER) begin
                    if (win_box) rgb = C_BLACK;
                    if (win_l0)  rgb = flash_off ? C_MISS : (turn ? C_P2 : C_P1);
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Outputs (Tiny VGA Pmod pin order), registered for clean timing
    // ------------------------------------------------------------------
    reg [7:0] uo_reg;
    always @(posedge clk) begin
        uo_reg <= {hsync, rgb[0], rgb[2], rgb[4], vsync, rgb[1], rgb[3], rgb[5]};
    end

    assign uo_out  = uo_reg;
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    wire _unused = &{ena, uio_in, ui_in[7], ui_in[3:0], press[4], press[10], press[11], 1'b0};

endmodule