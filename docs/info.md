<!---
This file is used to generate your project documentation. Please fill in the sections below.
-->

## How it works

The **Battleship VGA** project is a 2-player hot-seat tactical game implemented entirely in Verilog, designed to run on an ASIC core with standard 640x480 @ 60Hz VGA display output and NES/SNES Gamepad Pmod controls.

### Architecture & Components:
1. **VGA Timing Generator (`hvsync_generator.v`):** Generates horizontal and vertical synchronization pulses (`HSync`, `VSync`) along with active display region coordinates for a 640x480 @ 25.175 MHz pixel clock.
2. **Gamepad Pmod Driver (`gamepad_pmod.v`):** Interfaces with standard serial gamepads via shift-register protocol on `ui_in`, capturing button presses for D-pad movement, rotation, firing, and restarting.
3. **Game State Engine (`project.v`):** Manages the finite state machine (FSM) across three distinct phases:
   - **Phase 0 (PLACE):** Secret fleet placement on a $4 \times 4$ grid per player (one 3-cell ship and one 2-cell ship). Features green/red collision and boundary previews.
   - **Phase 1 (BATTLE):** Alternating turn-based firing. Tracks hits and misses, automatically switching turns after every shot until **5 total hits** are achieved.
   - **Phase 2 (OVER):** Victory screen with a blinking winner frame and unhit ship reveals.

---

## How to test

You can test this design locally using Icarus Verilog and Cocotb, or via the automated GitHub Actions workflow (`gds` / `gl_test`).

### Local Simulation Steps:
1. Ensure you have Python, Cocotb, and Icarus Verilog installed.
2. Navigate to the `test/` directory:
   ```bash
   cd test
