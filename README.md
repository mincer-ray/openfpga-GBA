# Game Boy Advance for Analogue Pocket

Ported from [MiSTer GBA core](https://github.com/MiSTer-devel/GBA_MiSTer)

## Features

- **Save States**
- **Fast Forward**
- **RTC**
- **Cart Saves**

##  Currently Not Included

- **Link Cable**
- **Gyroscope**
- **Solar Sensor**
- **Cheats**
- **Rewind**

The original MiSTer core was built for an FPGA chip roughly twice the size of the one inside the Analogue Pocket. Some extras had to go to make it all fit. I tried to prioritize things that could be fixed with romhacks, for example there is a solar patch that fixes this issues without the core needing to do anything. Link cable support was a rough one, my thinking there is you can switch cores temporarily if you want to use link cable features. I may try to add that one back in we'll see.

## Installation

1. Download the latest release
2. Copy the `Cores/mincer_ray.GBA/` folder to your SD card under `/Cores/`
3. Copy the `Platforms/` folder to your SD card (if not already present)
4. Place your GBA ROMs (`.gba`) anywhere on the SD card
5. Place `gba_bios.bin` (16KB) in `/Assets/gba/common/`

## Controls

| Button | Function |
|--------|----------|
| D-Pad | Directional input |
| A | A |
| B | B |
| Start | Start |
| Select | Select |
| L | L shoulder |
| R | R shoulder |
| Y | Fast Forward |

## Building from Source

### Prerequisites

- Docker (with Rosetta on Apple Silicon)
- Quartus Prime 21.1 (via `raetro/quartus:21.1` Docker image)

### Build

```bash
./scripts/build.sh
```

The build takes ~10 minutes locally. Output bitstream is placed in the package directory.

## Technical Details

**Target FPGA:** Intel Cyclone V 5CEBA4F23C8

| Resource | Usage |
|----------|-------|
| ALMs | 89% (16,384 / 18,480) |
| RAM Blocks | 91% (279 / 308) |
| DSP Blocks | 48% (32 / 66) |
| PLLs | 50% (2 / 4) |

**Clocks:**
- `clk_sys` — 100.66 MHz (GBA system clock)
- `clk_mem` — 133.12 MHz (SDRAM)

**Memory map:**
- SDRAM ch1 — Game ROM (up to 32MB)
- SDRAM ch2 — EWRAM (256KB)
- BRAM — IWRAM, VRAM, Palette, OAM, BIOS
- PSRAM — Cart saves (die 1)

## Known Issues

- Timing closure fails at slow corner (85C) by -0.396 ns. The design passes at room temperature and is functionally stable, but is not formally timing clean at worst case conditions. This is a consequence of fitting the GBA core into an FPGA with 44% of the ALMs it was designed for.

## Credits

- **[MiSTer GBA core](https://github.com/MiSTer-devel/GBA_MiSTer)** — original FPGA GBA implementation
- **[Analogue openFPGA](https://www.analogue.co/developer)** — platform framework and core template
- **[budude2/openfpga-GBC](https://github.com/budude2/openfpga-GBC)** — reference for MiSTer-to-Pocket porting patterns
- **[agg23](https://github.com/agg23)** — analogue-pocket-utils and reference SNES/NES Pocket cores

## License

GPL-2.0 — see [GBA_MiSTer LICENSE](https://github.com/MiSTer-devel/GBA_MiSTer/blob/master/LICENSE) for details.
