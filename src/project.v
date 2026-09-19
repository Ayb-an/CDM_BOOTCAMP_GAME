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
 * Phase 0 - PLACE : each player secretly places their fleet (the other looks away).
 *                   D-pad = move, B (or X/Y) = rotate, A = place ship.
 *                   Green preview = OK, red preview = can't place there.
 * Phase 1 - BATTLE: players take turns, one shot each.  Cursor is yellow.
 *                   D-pad = move, A = fire.  White dot = miss, red cell with
 *                   white X = hit.
 * Phase 2 - OVER  : winner's number + frame blink white, unhit ships revealed.
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

    localparam       HIT_AGAIN  = 1'b0;  // 1 = a hit lets the same player shoot again
    localparam [2:0] TOTAL_HITS = 3'd7;  // total ship cells per fleet (3 + 2 + 2)

    localparam [1:0] PH_PLACE  = 2'd0;
    localparam [1:0] PH_BATTLE = 2'd1;
    localparam [1:0] PH_OVER   = 2'd2;

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
    // Gamepad Pmod
    // ------------------------------------------------------------------
    wire inp_b, inp_y, inp_select, inp_start;
    wire inp_up, inp_down, inp_left, inp_right;
    wire inp_a, inp_x, inp_l, inp_r;
    wire inp_is_present;

    gamepad_pmod_single gamepad (
        .clk       (clk),
        .rst_n     (rst_n),
        .pmod_data (ui_in[6]),
        .pmod_clk  (ui_in[5]),
        .pmod_latch(ui_in[4]),
        .b(inp_b), .y(inp_y), .select(inp_select), .start(inp_start),
        .up(inp_up), .down(inp_down), .left(inp_left), .right(inp_right),
        .a(inp_a), .x(inp_x), .l(inp_l), .r(inp_r),
        .is_present(inp_is_present)
    );

    // Only the 7 buttons we actually use get an edge-detect flop (B/X/Y are
    // merged into one "rotate" button before the register).
    wire btn_rot = inp_b | inp_x | inp_y;
    wire [6:0] btn = {inp_a, btn_rot, inp_start, inp_right, inp_left, inp_down, inp_up};
    reg  [6:0] btn_prev;
    wire [6:0] press = btn & ~btn_prev;

    wire press_up    = press[0];
    wire press_down  = press[1];
    wire press_left  = press[2];
    wire press_right = press[3];
    wire press_start = press[4];
    wire press_rot   = press[5];
    wire press_a     = press[6];

    wire frame_tick = (hpos == 10'd0) && (vpos == 10'd0);

    // ------------------------------------------------------------------
    // Game state
    // ------------------------------------------------------------------
    reg [24:0] ships_a, ships_b;   // fleet maps      (bit = y*5 + x)
    reg [24:0] shots_a, shots_b;   // shots fired BY player A / B
    reg [2:0]  hits_a,  hits_b;
    reg [1:0]  phase;
    reg        turn;               // placer / shooter / winner (0 = P1, 1 = P2)
    reg [1:0]  ship_n;             // ships already placed by the current placer
    reg [2:0]  cur_x, cur_y;       // cursor 0..4
    reg        orient;             // 0 = horizontal, 1 = vertical
    reg [4:0]  frame_cnt;          // free running frame counter (blinking)

    // ------------------------------------------------------------------
    // 25-bit board helpers
    //
    // The old version built cell0 / place_mask / pix_onehot from 25 copies of
    // a pair of 3-bit comparators.  Here the cursor cell is decoded once into
    // two 5-bit one-hots, ships are grown with constant shifts, and per-pixel
    // lookups are plain 5:1 -> 5:1 mux trees (bit_sel) instead of 25 AND gates
    // plus an OR reduction each.
    // ------------------------------------------------------------------
    wire [4:0] xoh = 5'b00001 << cur_x;
    wire [4:0] yoh = 5'b00001 << cur_y;

    wire [24:0] cell0;
    genvar gi;
    generate
        for (gi = 0; gi < 25; gi = gi + 1) begin : g_cells
            localparam integer GX = gi % 5;
            localparam integer GY = gi / 5;
            assign cell0[gi] = xoh[GX] & yoh[GY];
        end
    endgenerate

    // one 25-bit mux serves both jobs: my fleet while placing, the enemy
    // fleet while shooting
    wire        ships_pick = (phase == PH_PLACE) ? turn : ~turn;
    wire [24:0] ships_sel  = ships_pick ? ships_b : ships_a;

    wire has3 = (ship_n == 2'd0);                 // first ship is 3 cells long
    wire [2:0] axis = orient ? cur_y : cur_x;     // the axis the ship grows along
    wire in1  = (axis <= 3'd3);
    wire in2  = (axis <= 3'd2);
    wire fits = has3 ? in2 : in1;

    wire [24:0] grow1 = orient ? {cell0[19:0], 5'd0}  : {cell0[23:0], 1'd0};
    wire [24:0] grow2 = orient ? {cell0[14:0], 10'd0} : {cell0[22:0], 2'd0};
    wire [24:0] place_mask = cell0
                           | (grow1 & {25{in1}})
                           | (grow2 & {25{has3 & in2}});

    wire place_ok = fits && ((place_mask & ships_sel) == 25'd0);

    // ---- battle helpers ----
    wire [4:0]  cur_idx  = {cur_y, 2'b00} + {2'b00, cur_y} + {2'b00, cur_x}; // y*5+x
    wire [24:0] my_shots = turn ? shots_b : shots_a;
    wire already  = my_shots[cur_idx];
    wire is_hit   = ships_sel[cur_idx];
    wire last_hit = is_hit && ((turn ? hits_b : hits_a) == (TOTAL_HITS - 3'd1));

    wire restart = press_start | ((phase == PH_OVER) & press_a);

    // ------------------------------------------------------------------
    // Game logic (runs once per frame)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (~rst_n) begin
            ships_a   <= 25'd0;
            ships_b   <= 25'd0;
            shots_a   <= 25'd0;
            shots_b   <= 25'd0;
            hits_a    <= 3'd0;
            hits_b    <= 3'd0;
            phase     <= PH_PLACE;
            turn      <= 1'b0;
            ship_n    <= 2'd0;
            cur_x     <= 3'd0;
            cur_y     <= 3'd0;
            orient    <= 1'b0;
            btn_prev  <= 7'd0;
            frame_cnt <= 5'd0;
        end else if (frame_tick) begin
            btn_prev  <= btn;
            frame_cnt <= frame_cnt + 5'd1;

            if (restart) begin
                ships_a <= 25'd0;
                ships_b <= 25'd0;
                shots_a <= 25'd0;
                shots_b <= 25'd0;
                hits_a  <= 3'd0;
                hits_b  <= 3'd0;
                phase   <= PH_PLACE;
                turn    <= 1'b0;
                ship_n  <= 2'd0;
                cur_x   <= 3'd0;
                cur_y   <= 3'd0;
                orient  <= 1'b0;
            end else begin
                // cursor movement, frozen on the game-over screen
                if (phase != PH_OVER) begin
                    if (press_left  && cur_x != 3'd0) cur_x <= cur_x - 3'd1;
                    if (press_right && cur_x != 3'd4) cur_x <= cur_x + 3'd1;
                    if (press_up    && cur_y != 3'd0) cur_y <= cur_y - 3'd1;
                    if (press_down  && cur_y != 3'd4) cur_y <= cur_y + 3'd1;
                end

                if (phase == PH_PLACE) begin
                    if (press_rot) orient <= ~orient;

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
                                turn  <= 1'b0;          // Player 1 fires first
                                phase <= PH_BATTLE;
                            end
                        end else begin
                            ship_n <= ship_n + 2'd1;
                        end
                    end

                end else if (phase == PH_BATTLE) begin
                    if (press_a && !already) begin
                        if (~turn) shots_a <= shots_a | cell0;
                        else       shots_b <= shots_b | cell0;

                        if (is_hit) begin
                            if (~turn) hits_a <= hits_a + 3'd1;
                            else       hits_b <= hits_b + 3'd1;
                        end

                        if (last_hit) begin
                            phase <= PH_OVER;           // 'turn' stays = winner
                        end else if (!(HIT_AGAIN & is_hit)) begin
                            turn <= ~turn;
                        end
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Rendering
    // ------------------------------------------------------------------
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
    localparam [9:0] IND_Y    = 10'd328;
    localparam [9:0] DIG_X    = 10'd304;
    localparam [9:0] DIG_Y    = 10'd40;

    wire blink = frame_cnt[4];

    // pick one bit out of a 25-bit board map: 5:1 row mux then 5:1 column mux
    function bit_sel;
        input [24:0] v;
        input [2:0]  bx, by;
        reg   [4:0]  row;
        begin
            case (by)
                3'd0:    row = v[4:0];
                3'd1:    row = v[9:5];
                3'd2:    row = v[14:10];
                3'd3:    row = v[19:15];
                default: row = v[24:20];
            endcase
            case (bx)
                3'd0:    bit_sel = row[0];
                3'd1:    bit_sel = row[1];
                3'd2:    bit_sel = row[2];
                3'd3:    bit_sel = row[3];
                default: bit_sel = row[4];
            endcase
        end
    endfunction

    // which board is the pixel in?
    wire in_rows  = (vpos >= BOARD_Y) && (vpos < BOARD_Y + BOARD_SZ);
    wire in_col_l = (hpos >= LEFT_X)  && (hpos < LEFT_X  + BOARD_SZ);
    wire in_col_r = (hpos >= RIGHT_X) && (hpos < RIGHT_X + BOARD_SZ);
    wire in_board = in_rows && (in_col_l || in_col_r);
    wire side     = in_col_r;                  // 0 = left/P1 board, 1 = right/P2

    // 8-bit board-relative coordinates (mod-256 wrap is harmless here: the
    // offsets are always < 256 inside a board, and this drops two 10-bit
    // subtractors down to 8 bits)
    wire [7:0] rel_x = hpos[7:0] - (side ? RIGHT_X[7:0] : LEFT_X[7:0]);
    wire [7:0] rel_y = vpos[7:0] - BOARD_Y[7:0];

    wire [2:0] cell_x = rel_x[7:5];
    wire [2:0] cell_y = rel_y[7:5];
    wire [4:0] in_x   = rel_x[4:0];
    wire [4:0] in_y   = rel_y[4:0];
    wire [2:0] qx     = in_x[4:2];             // 4-pixel quantised position
    wire [2:0] qy     = in_y[4:2];

    wire grid_line   = (in_x < 5'd2) || (in_y < 5'd2);
    wire cursor_edge = (qx == 3'd0) || (qx == 3'd7) || (qy == 3'd0) || (qy == 3'd7);
    wire dot         = (qx[2:1] == 2'b01) && (qy[2:1] == 2'b01);   // qx,qy in 2..3
    wire xmark       = (qx == qy) || ((qx + qy) == 3'd7);

    // per-cell lookups (one 25-bit mux + one bit_sel each)
    wire [24:0] side_shots = side ? shots_b : shots_a;
    wire        view_pick  = (phase == PH_PLACE) ? side : ~side;
    wire [24:0] ships_view = view_pick ? ships_b : ships_a;

    wire shot_here = bit_sel(side_shots, cell_x, cell_y);
    wire ship_here = bit_sel(ships_view, cell_x, cell_y);  // own ship / target
    wire prev_here = bit_sel(place_mask, cell_x, cell_y);

    // frames around the boards
    wire in_outer_rows = (vpos >= BOARD_Y - 10'd4) && (vpos < BOARD_Y + BOARD_SZ + 10'd4);
    wire in_outer_l = in_outer_rows && (hpos >= LEFT_X  - 10'd4) && (hpos < LEFT_X  + BOARD_SZ + 10'd4);
    wire in_outer_r = in_outer_rows && (hpos >= RIGHT_X - 10'd4) && (hpos < RIGHT_X + BOARD_SZ + 10'd4);
    wire flash_off = (phase == PH_OVER) && !blink;

    // indicator row under the boards
    wire in_ind_row = (vpos >= IND_Y) && (vpos < IND_Y + 10'd16) && (in_col_l || in_col_r);

    // big player number (7-segment style)
    wire       in_digit = (hpos >= DIG_X) && (hpos < DIG_X + 10'd32) &&
                          (vpos >= DIG_Y) && (vpos < DIG_Y + 10'd48);
    wire [7:0] dig_x = hpos[7:0] - DIG_X[7:0];
    wire [7:0] dig_y = vpos[7:0] - DIG_Y[7:0];
    wire seg_a = (dig_y < 8'd6);
    wire seg_g = (dig_y >= 8'd21) && (dig_y < 8'd27);
    wire seg_d = (dig_y >= 8'd42);
    wire seg_b = (dig_x >= 8'd26) && (dig_y < 8'd24);
    wire seg_e = (dig_x < 8'd6)   && (dig_y >= 8'd24);
    wire seg_c = (dig_x >= 8'd26) && (dig_y >= 8'd24);
    wire digit_on = turn ? (seg_a | seg_b | seg_g | seg_e | seg_d)   // "2"
                         : (seg_b | seg_c);                          // "1"

    // placement icons under the board (3, 2, 2 cells wide)
    wire blk0   = (rel_x >= 8'd16)  && (rel_x < 8'd64);
    wire blk1   = (rel_x >= 8'd72)  && (rel_x < 8'd104);
    wire blk2   = (rel_x >= 8'd112) && (rel_x < 8'd144);
    wire blk_on = blk0 | blk1 | blk2;
    wire [1:0] blk_k = blk0 ? 2'd0 : (blk1 ? 2'd1 : 2'd2);

    // battle pips: 7 squares on a 16 px pitch, so the index is a bit slice
    // instead of seven range comparators
    wire [2:0] pip_hits = side ? hits_b : hits_a;
    wire [7:0] pip_off  = rel_x - 8'd24;
    wire       pip_area = (rel_x >= 8'd24) && (rel_x < 8'd136);
    wire [2:0] pip_i    = pip_off[6:4];
    wire       pip_body = (pip_off[3:0] >= 4'd2) && (pip_off[3:0] < 4'd14);
    wire       pip_lit  = (pip_hits > pip_i);

    reg [5:0] rgb;

    always @* begin
        rgb = C_BLACK;

        if (video_active) begin
            rgb = C_SEA;

            // ---- player number (winner blinks white) ----
            if (in_digit && digit_on)
                rgb = flash_off ? C_MISS : (turn ? C_P2 : C_P1);

            // ---- board frames (active player = bright) ----
            if (in_outer_l && !in_board)
                rgb = (turn == 1'b0) ? (flash_off ? C_MISS : C_P1) : C_P1_DIM;
            if (in_outer_r && !in_board)
                rgb = (turn == 1'b1) ? (flash_off ? C_MISS : C_P2) : C_P2_DIM;

            // ---- indicator row ----
            if (in_ind_row) begin
                if (phase == PH_PLACE) begin
                    if (blk_on && (side == turn)) begin
                        if (blk_k < ship_n)       rgb = C_OK;
                        else if (blk_k == ship_n) rgb = blink ? C_CURSOR : (turn ? C_P2 : C_P1);
                        else                      rgb = C_DIM;
                    end
                end else begin
                    if (pip_area && pip_body) rgb = pip_lit ? C_HIT : C_DIM;
                end
            end

            // ---- boards ----
            if (in_board) begin
                if (phase == PH_PLACE && side != turn) begin
                    rgb = C_BLACK;                       // hidden from the other player
                end else begin
                    rgb = C_WATER;
                    if (grid_line) begin
                        rgb = C_SEA;
                    end else if (phase == PH_PLACE) begin
                        if (ship_here) rgb = C_SHIP;
                        if (prev_here) rgb = place_ok ? C_OK : C_BAD;
                    end else begin
                        if (shot_here) begin
                            if (ship_here) rgb = xmark ? C_MISS : C_HIT;
                            else if (dot)  rgb = C_MISS;
                        end else if (phase == PH_OVER && ship_here) begin
                            rgb = C_SHIP;                // reveal what was left
                        end
                        if (phase == PH_BATTLE && side == turn &&
                            cell_x == cur_x && cell_y == cur_y && cursor_edge)
                            rgb = C_CURSOR;
                    end
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

    wire _unused = &{ena, uio_in, ui_in[7], ui_in[3:0], inp_is_present,
                     inp_select, inp_l, inp_r, 1'b0};

endmodule