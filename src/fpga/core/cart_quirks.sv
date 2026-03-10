//
// cart_quirks.sv — Cart quirk database for GBA
//
// Matches the 4-byte cart ID from ROM[0xAC:0xAF] against a database of
// known games that require special handling. Direct port of MiSTer
// GBA.sv lines 644-741 (95 entries, 6 quirk flags).
//
// Cart ID format: big-endian (cart_id[31:24] = first char at 0xAC)
// Matching: cart_id[31:8] for 3-char matches, cart_id[31:0] for 4-char
//
// SPDX-License-Identifier: GPL-2.0-or-later
//

`default_nettype none

module cart_quirks (
    input  wire        clk,
    input  wire [31:0] cart_id,         // 4 bytes from ROM[0xAC:0xAF], big-endian
    input  wire        valid,           // Cart ID is ready (pulse or level)

    output reg         sram_quirk,      // Force no SRAM (emulation detection games)
    output reg         gpio_quirk,      // Enable GPIO (RTC, solar, gyro) → specialmodule
    output reg         tilt_quirk,      // Enable tilt sensor
    output reg         solar_quirk,     // Game has solar sensor
    output reg         memory_remap,    // Memory mirroring quirk
    output reg         sprite_quirk     // Max sprite pixels per line
);

    always @(posedge clk) begin
        if (valid) begin
            // Default: no quirks
            sram_quirk    <= 1'b0;
            gpio_quirk    <= 1'b0;
            tilt_quirk    <= 1'b0;
            solar_quirk   <= 1'b0;
            memory_remap  <= 1'b0;
            sprite_quirk  <= 1'b0;

            // === SRAM quirk only ===
            if (cart_id[31:8] == "AR8") sram_quirk <= 1; // no SRAM
            if (cart_id[31:8] == "ARO") sram_quirk <= 1; // no SRAM
            if (cart_id[31:8] == "ALG") sram_quirk <= 1; // no SRAM
            if (cart_id[31:8] == "ALF") sram_quirk <= 1; // no SRAM
            if (cart_id[31:8] == "BLF") sram_quirk <= 1; // no SRAM
            if (cart_id[31:8] == "BDB") sram_quirk <= 1; // no SRAM
            if (cart_id[31:8] == "BG3") sram_quirk <= 1; // no SRAM
            if (cart_id[31:8] == "BDV") sram_quirk <= 1; // no SRAM
            if (cart_id[31:8] == "A2Y") sram_quirk <= 1; // no SRAM
            if (cart_id[31:8] == "AI2") sram_quirk <= 1; // no SRAM
            if (cart_id[31:8] == "BT4") sram_quirk <= 1; // no SRAM

            // === GPIO quirk only (RTC, special peripherals) ===
            if (cart_id[31:8] == "BPE") gpio_quirk <= 1; // RTC
            if (cart_id[31:8] == "AXV") gpio_quirk <= 1; // RTC
            if (cart_id[31:8] == "AXP") gpio_quirk <= 1; // RTC
            if (cart_id[31:8] == "RZW") gpio_quirk <= 1; // gyro
            if (cart_id[31:8] == "BKA") gpio_quirk <= 1; // RTC
            if (cart_id[31:8] == "BR4") gpio_quirk <= 1; // RTC
            if (cart_id[31:8] == "V49") gpio_quirk <= 1; // rumble
            if (cart_id[31:8] == "2GB") gpio_quirk <= 1; // GPIO

            // === Sprite quirk only ===
            if (cart_id[31:8] == "BHG") sprite_quirk <= 1; // sprite limit
            if (cart_id[31:8] == "BGX") sprite_quirk <= 1; // sprite limit

            // === Tilt quirk only ===
            if (cart_id[31:8] == "KHP") tilt_quirk <= 1; // tilt sensor
            if (cart_id[31:8] == "KYG") tilt_quirk <= 1; // tilt sensor

            // === GPIO + Solar quirk ===
            if (cart_id[31:8] == "U3I") begin gpio_quirk <= 1; solar_quirk <= 1; end // solar sensor
            if (cart_id[31:8] == "U32") begin gpio_quirk <= 1; solar_quirk <= 1; end // solar sensor
            if (cart_id[31:8] == "U33") begin gpio_quirk <= 1; solar_quirk <= 1; end // solar sensor

            // === Classic NES Series (SRAM + memory remap) — full 4-char match ===
            if (cart_id == "FBME") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FADE") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FDKE") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FDME") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FEBE") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FICE") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FMRE") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FP7E") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FSME") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FZLE") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FXVE") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FLBE") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FSRJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FGZJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap

            // === Famicom Mini — SRAM + memory remap + sprite ===
            if (cart_id == "FSDJ") begin sram_quirk <= 1; memory_remap <= 1; sprite_quirk <= 1; end // no SRAM + remap + sprite limit
            if (cart_id == "FADJ") begin sram_quirk <= 1; memory_remap <= 1; sprite_quirk <= 1; end // no SRAM + remap + sprite limit

            // === Famicom Mini — SRAM + sprite ===
            if (cart_id == "FTUJ") begin sram_quirk <= 1; sprite_quirk <= 1; end // no SRAM + sprite limit
            if (cart_id == "FTKJ") begin sram_quirk <= 1; sprite_quirk <= 1; end // no SRAM + sprite limit
            if (cart_id == "FFMJ") begin sram_quirk <= 1; sprite_quirk <= 1; end // no SRAM + sprite limit
            if (cart_id == "FLBJ") begin sram_quirk <= 1; sprite_quirk <= 1; end // no SRAM + sprite limit
            if (cart_id == "FPTJ") begin sram_quirk <= 1; sprite_quirk <= 1; end // no SRAM + sprite limit
            if (cart_id == "FMRJ") begin sram_quirk <= 1; sprite_quirk <= 1; end // no SRAM + sprite limit
            if (cart_id == "FNMJ") begin sram_quirk <= 1; sprite_quirk <= 1; end // no SRAM + sprite limit

            // === Famicom Mini — SRAM + memory remap + sprite ===
            if (cart_id == "FM2J") begin sram_quirk <= 1; memory_remap <= 1; sprite_quirk <= 1; end // no SRAM + remap + sprite limit

            // === Famicom Mini — SRAM + memory remap ===
            if (cart_id == "FGGJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FTWJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FMKJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FTBJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FDDJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FDMJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FWCJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FVFJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FCLJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FMBJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FSOJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FBMJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FMPJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FXVJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FPMJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FZLJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FEBJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FICJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FDKJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
            if (cart_id == "FSMJ") begin sram_quirk <= 1; memory_remap <= 1; end // no SRAM + remap
        end
    end

endmodule
