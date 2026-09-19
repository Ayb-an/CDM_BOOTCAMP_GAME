`ifndef HVSYNC_GENERATOR_H
`define HVSYNC_GENERATOR_H

/*
 * Video sync generator, used to drive a VGA monitor VGA monitor.
 * Timing from: https://en.wikipedia.org/wiki/Video_Graphics_Array
 * To use:
 * - Wire the hsync and vsync signals to top level outputs
 * - Add a 3-bit (or more) rgb output to the top level
 */

module hvsync_generator(clk, reset, hsync, vsync, display_on, hpos, vpos);

  input clk;
  input reset;
  output reg hsync, vsync;
  output display_on;
  output reg [9:0] hpos;
  output reg [9:0] vpos;

  // declarations for TV-simulator sync parameters
  // horizontal constants
  parameter H_DISPLAY       = 640; // horizontal display width
  parameter H_BACK          =  48; // horizontal left border (back porch)
  parameter H_FRONT         =  16; // horizontal right border (front porch)
  parameter H_SYNC          =  96; // horizontal sync width
  // vertical constants
  parameter V_DISPLAY       = 480; // vertical display height
  parameter V_TOP           =  33; // vertical top border
  parameter V_BOTTOM        =  10; // vertical bottom border
  parameter V_SYNC          =   2; // vertical sync width
  // derived constants
  parameter H_SYNC_START    = H_DISPLAY + H_FRONT;
  parameter H_SYNC_END      = H_DISPLAY + H_FRONT + H_SYNC - 1;
  parameter H_MAX           = H_DISPLAY + H_BACK + H_FRONT + H_SYNC - 1;
  parameter V_SYNC_START    = V_DISPLAY + V_BOTTOM;
  parameter V_SYNC_END      = V_DISPLAY + V_BOTTOM + V_SYNC - 1;
  parameter V_MAX           = V_DISPLAY + V_TOP + V_BOTTOM + V_SYNC - 1;

  // Reset must initialize the counters explicitly.  Relying on comparisons
  // with an uninitialized counter leaves hpos/vpos as X in gate simulation.
  wire hmaxxed = (hpos == H_MAX);
  wire vmaxxed = (vpos == V_MAX);

  // horizontal position counter and sync output
  always @(posedge clk) begin
    if (reset) begin
      hpos  <= 0;
      hsync <= 1'b1;
    end else begin
      hsync <= ~(hpos >= H_SYNC_START && hpos <= H_SYNC_END);
      if (hmaxxed)
        hpos <= 0;
      else
        hpos <= hpos + 1;
    end
  end

  // vertical position counter and sync output
  always @(posedge clk) begin
    if (reset) begin
      vpos  <= 0;
      vsync <= 1'b1;
    end else begin
      vsync <= ~(vpos >= V_SYNC_START && vpos <= V_SYNC_END);
      if (hmaxxed) begin
        if (vmaxxed)
          vpos <= 0;
        else
          vpos <= vpos + 1;
      end
    end
  end

  // display_on is set when beam is in safe visible frame
  assign display_on = (hpos < H_DISPLAY) && (vpos < V_DISPLAY);

endmodule

`endif
