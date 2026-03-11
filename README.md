# GBA for Analogue Pocket

LLM assisted port of [MiSTer GBA core](https://github.com/MiSTer-devel/GBA_MiSTer)

## Features

- **Cart Saves**
- **Filters**
- **Save States**
- **Fast Forward (Bound to Y button)**
- **RTC**
- **FORCE RTC** — Manually enables RTC for ROMs that aren't in the database. This is useful for ROM hacks that add RTC support to games that don't normally use it (like a certain "unbound" hack). Make sure to enable this on first load of the hack, ideally as soon as possible during the bios display to avoid any issues with initializing the save. **USE WITH CAUTION:** enabling this on a game that doesn't actually use RTC can cause crashes or glitches.
### **⚠️WARNING: Forced RTC setting persists across games! Remember to turn it off before loading a game that doesn't need it⚠️**

##  Currently Not Included

- **Link Cable**
- **Gyroscope**
- **Solar Sensor**
- **Cheats**
- **Rewind**
- **Color correction outside default pocket filters**

The original MiSTer core was built for an FPGA chip roughly twice the size of the one inside the Analogue Pocket. Some extras had to go to make it all fit. I tried to prioritize things that could be fixed with romhacks, for example there is a solar patch that fixes this issues without the core needing to do anything. Link cable support was a rough one, my thinking there is you can switch cores temporarily if you want to use link cable features. I may try to add that one back in we'll see. Also maybe possible to do simple color desaturation.

## Installation

1. Download the latest release
2. Copy the 3 folders `Cores/`, `Platforms/`, `Assets/`  to your SD card
3. Place your ROMs and `gba_bios.bin` in `/Assets/gba/common/`

## Building from Source

Should be very easy

### Prerequisites

- Docker
- `raetro/quartus:21.1` Docker image

### Build

```bash
./scripts/build.sh
```

## Known Issues

- **Fast forward speed varies by game** — Games that make heavy use of the GBA's slower external RAM will not fast-forward as quickly as games that primarily use internal RAM. This is most noticeable with the Classic NES Series titles.

## Credits

- **[MiSTer GBA core](https://github.com/MiSTer-devel/GBA_MiSTer)** — original FPGA GBA implementation
- **[Analogue openFPGA](https://www.analogue.co/developer)** — platform framework and core template
- **[budude2/openfpga-GBC](https://github.com/budude2/openfpga-GBC)** — reference for MiSTer-to-Pocket porting patterns
- **[agg23](https://github.com/agg23)** — analogue-pocket-utils and reference SNES/NES Pocket cores

## License

GPL-2.0 — see [GBA_MiSTer LICENSE](https://github.com/MiSTer-devel/GBA_MiSTer/blob/master/LICENSE) for details.
