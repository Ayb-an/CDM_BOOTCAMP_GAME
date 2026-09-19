/*
 * Battleship VGA - 2 player hot-seat game for Tiny Tapeout (640x480 VGA + Gamepad Pmod)
 * Copyright (c) 2026 <your name>
 * SPDX-License-Identifier: Apache-2.0
 *
 * Board: 4x4 per player.  Fleet per player: one 3-cell ship + one 2-cell ship,
 * so 5 hits wins.
 *
 * Screen layout
 *   LEFT  board (cyan)   = Player 1's area
 *   RIGHT board (orange) = Player 2's area
 *   Bright board frame   = whose turn it is
 *   Row under each board = placement: ships placed / battle: hits landed
 *
 * Phase 0 - PLACE : each player secretly places their fleet (the other looks
 *                   away).  D-pad = move, B/X/Y = rotate, A = place.
 *                   Green preview = OK, red preview = can't place there.
 * Phase 1 - BATTLE: one shot each, turn switches after every shot.
 *                   D-pad = move, A = fire.  White dot = miss, red cell with
 *                   white X = hit.
 * Phase 2 - OVER  : winner's frame blinks white, unhit ships are revealed.
 *                   A or Start = new game.  Start restarts at any time.
 */

`default_nettype none

module tt_um_vga_example (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    localparam [2:0] TOTAL_HITS = 3'd5;
    localparam [1:0] PH_PLACE = 2'd0;
    localparam [1:0] PH_BATTLE = 2'd1;
    localparam [1:0] PH_OVER = 2'd2;

    wire hsync, vsync, video_active;
    wire [9:0] hpos, vpos;

    hvsync_generator hvsync_gen (
        .clk(clk), .reset(~rst_n), .hsync(hsync), .vsync(vsync),
        .display_on(video_active), .hpos(hpos), .vpos(vpos)
    );

    wire inp_b, inp_y, inp_select, inp_start;
    wire inp_up, inp_down, inp_left, inp_right;
    wire inp_a, inp_x, inp_l, inp_r;
    wire inp_is_present;

    gamepad_pmod_single gamepad (
        .clk(clk), .rst_n(rst_n), .pmod_data(ui_in[6]),
        .pmod_clk(ui_in[5]), .pmod_latch(ui_in[4]),
        .b(inp_b), .y(inp_y), .select(inp_select), .start(inp_start),
        .up(inp_up), .down(inp_down), .left(inp_left), .right(inp_right),
        .a(inp_a), .x(inp_x), .l(inp_l), .r(inp_r),
        .is_present(inp_is_present)
    );

    wire btn_rot = inp_b | inp_x | inp_y;
    wire [6:0] btn = {inp_a, btn_rot, inp_start, inp_right, inp_left, inp_down, inp_up};
    reg [6:0] btn_prev;
    wire [6:0] press = btn & ~btn_prev;
    wire press_up = press[0], press_down = press[1], press_left = press[2];
    wire press_right = press[3], press_start = press[4], press_rot = press[5];
    wire press_a = press[6];
    wire frame_tick = (hpos == 10'd0) && (vpos == 10'd0);

    reg [15:0] ships_a, ships_b, shots_a, shots_b;
    reg [2:0] hits_a, hits_b;
    reg [1:0] phase;
    reg turn, ship_n;
    reg [1:0] cur_x, cur_y;
    reg orient;
    reg [4:0] frame_cnt;

    wire [3:0] cur_idx = {cur_y, cur_x};
    wire [15:0] cell0 = 16'd1 << cur_idx;
    wire ships_pick = (phase == PH_PLACE) ? turn : ~turn;
    wire [15:0] ships_sel = ships_pick ? ships_b : ships_a;
    wire has3 = (ship_n == 1'b0);
    wire [1:0] axis = orient ? cur_y : cur_x;
    wire in1 = (axis <= 2'd2), in2 = (axis <= 2'd1);
    wire fits = has3 ? in2 : in1;
    wire [15:0] grow1 = orient ? {cell0[11:0], 4'd0} : {cell0[14:0], 1'd0};
    wire [15:0] grow2 = orient ? {cell0[7:0], 8'd0} : {cell0[13:0], 2'd0};
    wire [15:0] place_mask = cell0 | (grow1 & {16{in1}}) | (grow2 & {16{has3 & in2}});
    wire place_ok = fits && ((place_mask & ships_sel) == 16'd0);
    wire [15:0] my_shots = turn ? shots_b : shots_a;
    wire already = my_shots[cur_idx];
    wire is_hit = ships_sel[cur_idx];
    wire last_hit = is_hit && ((turn ? hits_b : hits_a) == (TOTAL_HITS - 3'd1));
    wire restart = press_start | ((phase == PH_OVER) & press_a);

    always @(posedge clk) begin
        if (~rst_n) begin
            ships_a <= 0; ships_b <= 0; shots_a <= 0; shots_b <= 0;
            hits_a <= 0; hits_b <= 0; phase <= PH_PLACE; turn <= 0;
            ship_n <= 0; cur_x <= 0; cur_y <= 0; orient <= 0;
            btn_prev <= 0; frame_cnt <= 0;
        end else if (frame_tick) begin
            btn_prev <= btn;
            frame_cnt <= frame_cnt + 1'b1;
            if (restart) begin
                ships_a <= 0; ships_b <= 0; shots_a <= 0; shots_b <= 0;
                hits_a <= 0; hits_b <= 0; phase <= PH_PLACE; turn <= 0;
                ship_n <= 0; cur_x <= 0; cur_y <= 0; orient <= 0;
            end else begin
                if (phase != PH_OVER) begin
                    if (press_left && cur_x != 0) cur_x <= cur_x - 1'b1;
                    if (press_right && cur_x != 3) cur_x <= cur_x + 1'b1;
                    if (press_up && cur_y != 0) cur_y <= cur_y - 1'b1;
                    if (press_down && cur_y != 3) cur_y <= cur_y + 1'b1;
                end
                if (phase == PH_PLACE) begin
                    if (press_rot) orient <= ~orient;
                    if (press_a && place_ok) begin
                        if (~turn) ships_a <= ships_a | place_mask;
                        else ships_b <= ships_b | place_mask;
                        if (ship_n) begin
                            ship_n <= 0; cur_x <= 0; cur_y <= 0; orient <= 0;
                            if (~turn) turn <= 1;
                            else begin turn <= 0; phase <= PH_BATTLE; end
                        end else ship_n <= 1;
                    end
                end else if (phase == PH_BATTLE && press_a && !already) begin
                    if (~turn) shots_a <= shots_a | cell0;
                    else shots_b <= shots_b | cell0;
                    if (is_hit) begin
                        if (~turn) hits_a <= hits_a + 1'b1;
                        else hits_b <= hits_b + 1'b1;
                    end
                    if (last_hit) phase <= PH_OVER;
                    else turn <= ~turn;
                end
            end
        end
    end

    localparam [5:0] C_BLACK=6'b00_00_00, C_SEA=6'b00_00_01, C_WATER=6'b00_01_10;
    localparam [5:0] C_P1=6'b00_11_11, C_P2=6'b11_10_00, C_P1_DIM=6'b00_01_01;
    localparam [5:0] C_P2_DIM=6'b01_01_00, C_DIM=6'b01_01_01, C_SHIP=6'b10_10_10;
    localparam [5:0] C_HIT=6'b11_00_00, C_MISS=6'b11_11_11, C_OK=6'b00_11_00;
    localparam [5:0] C_BAD=6'b11_00_01, C_CURSOR=6'b11_11_00;
    localparam [9:0] BOARD_Y=160, LEFT_X=112, RIGHT_X=400, BOARD_SZ=128, IND_Y=312;
    wire blink = frame_cnt[4];
    wire in_rows=(vpos>=BOARD_Y)&&(vpos<BOARD_Y+BOARD_SZ);
    wire in_col_l=(hpos>=LEFT_X)&&(hpos<LEFT_X+BOARD_SZ);
    wire in_col_r=(hpos>=RIGHT_X)&&(hpos<RIGHT_X+BOARD_SZ);
    wire in_board=in_rows&&(in_col_l||in_col_r), side=in_col_r;
    wire [7:0] rel_x=hpos[7:0]-(side?RIGHT_X[7:0]:LEFT_X[7:0]);
    wire [7:0] rel_y=vpos[7:0]-BOARD_Y[7:0];
    wire [1:0] cell_x=rel_x[6:5], cell_y=rel_y[6:5];
    wire [4:0] in_x=rel_x[4:0], in_y=rel_y[4:0];
    wire [2:0] qx=in_x[4:2], qy=in_y[4:2];
    wire grid_line=(in_x<2)||(in_y<2), cursor_edge=(qx==0)||(qx==7)||(qy==0)||(qy==7);
    wire dot=(qx[2:1]==2'b01)&&(qy[2:1]==2'b01), xmark=(qx==qy)||((qx+qy)==7);
    wire [3:0] pix_idx={cell_y,cell_x};
    wire [15:0] side_shots=side?shots_b:shots_a;
    wire view_pick=(phase==PH_PLACE)?side:~side;
    wire [15:0] ships_view=view_pick?ships_b:ships_a;
    wire shot_here=side_shots[pix_idx], ship_here=ships_view[pix_idx], prev_here=place_mask[pix_idx];
    wire in_outer_rows=(vpos>=BOARD_Y-4)&&(vpos<BOARD_Y+BOARD_SZ+4);
    wire in_outer_l=in_outer_rows&&(hpos>=LEFT_X-4)&&(hpos<LEFT_X+BOARD_SZ+4);
    wire in_outer_r=in_outer_rows&&(hpos>=RIGHT_X-4)&&(hpos<RIGHT_X+BOARD_SZ+4);
    wire flash_off=(phase==PH_OVER)&&!blink;
    wire in_ind_row=(vpos>=IND_Y)&&(vpos<IND_Y+16)&&(in_col_l||in_col_r);
    wire [2:0] pip_count=(phase==PH_PLACE)?{2'd0,ship_n}:(side?hits_b:hits_a);
    wire [7:0] pip_off=rel_x-24;
    wire pip_area=(rel_x>=24)&&(rel_x<104), pip_body=(pip_off[3:0]>=2)&&(pip_off[3:0]<14);
    wire [2:0] pip_i=pip_off[6:4], pip_lit=(pip_count>pip_i), pip_show=(phase!=PH_PLACE)||(side==turn);
    reg [5:0] rgb;
    always @* begin
        rgb=C_BLACK;
        if (video_active) begin
            rgb=C_SEA;
            if (in_outer_l && !in_board) rgb=(turn==0)?(flash_off?C_MISS:C_P1):C_P1_DIM;
            if (in_outer_r && !in_board) rgb=(turn==1)?(flash_off?C_MISS:C_P2):C_P2_DIM;
            if (in_ind_row && pip_area && pip_body && pip_show) rgb=pip_lit?((phase==PH_PLACE)?C_OK:C_HIT):C_DIM;
            if (in_board) begin
                if (phase==PH_PLACE && side!=turn) rgb=C_BLACK;
                else begin
                    rgb=C_WATER;
                    if (grid_line) rgb=C_SEA;
                    else if (phase==PH_PLACE) begin
                        if (ship_here) rgb=C_SHIP;
                        if (prev_here) rgb=place_ok?C_OK:C_BAD;
                    end else begin
                        if (shot_here) begin
                            if (ship_here) rgb=xmark?C_MISS:C_HIT;
                            else if (dot) rgb=C_MISS;
                        end else if (phase==PH_OVER && ship_here) rgb=C_SHIP;
                        if (phase==PH_BATTLE && side==turn && cell_x==cur_x && cell_y==cur_y && cursor_edge) rgb=C_CURSOR;
                    end
                end
            end
        end
    end

    reg [7:0] uo_reg;
    always @(posedge clk) begin
        if (~rst_n) uo_reg <= 8'b0;
        else uo_reg <= {hsync,rgb[0],rgb[2],rgb[4],vsync,rgb[1],rgb[3],rgb[5]};
    end
    assign uo_out=uo_reg;
    assign uio_out=8'b0;
    assign uio_oe=8'b0;
    wire _unused=&{ena,uio_in,ui_in[7],ui_in[3:0],inp_is_present,inp_select,inp_l,inp_r,1'b0};
endmodule
