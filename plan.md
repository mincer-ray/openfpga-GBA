# RTC Sidecar Integration Plan

## Goal

Move the core's existing 16-byte RTC persistence record out of the cartridge
save and into a separate per-game `.rtc` sidecar.

After this change:

- `<game>.sav` contains only the core's existing normalized 64 KiB or 128 KiB
  cartridge-save image.
- `<game>.rtc` contains the existing 16-byte timestamp/calendar record.
- Saves produced by the current release with an appended RTC footer migrate
  automatically.
- Returning temporarily to the current release and then back to the sidecar
  release does not lose the newer legacy RTC value.

This project changes RTC persistence and save-file interoperability only. It
does not change RTC timekeeping behavior.

## Explicitly Out of Scope

- Correcting the live one-second divider.
- Adding leap-year-aware calendar rollover.
- Holding RTC games in reset during powered-off catch-up.
- Changing catch-up arithmetic, host-clock rollback policy, or RTC command
  behavior.
- Replacing `gba_gpioRTCSolarGyro.vhd` or changing its interface.
- Changing save-memory detection or the current 64 KiB/128 KiB normalization.
- Introducing exact EEPROM, SRAM, or smaller Flash export sizes.
- Introducing a new RTC record format, version, checksum, or container.
- Seed sweeps.

The divider and leap-year observations are valid candidates for separate,
independently justified fixes. They are not dependencies of the sidecar.

## Current Implementation Constraints

The current save loader and unloader both accept the entire `0x2xxxxxxx`
bridge region. Their 28-bit local addresses therefore contain a subregion in
`address[27:24]`:

- Slot 10 at `0x20000000` appears as subregion `0`.
- Slot 11 at `0x21000000` appears as subregion `1`.

The current PSRAM mux sends every save-loader write to cartridge-save PSRAM,
and `save_data_received` is set by every save-loader write. Adding slot 11
without fixing both behaviors would:

- Alias sidecar writes onto the beginning of cartridge-save PSRAM.
- Make a sidecar-only load look like a cartridge save was loaded, suppressing
  the required no-save PSRAM clear.

The sidecar integration must therefore isolate routing and cartridge-save
lifecycle signals before adding RTC record handling.

The loader's asynchronous FIFO also means that `dataslot_allcomplete` does not
by itself prove that save data has reached `clk_sys`. Today the no-save PSRAM
clear can start before a delayed first save word, and GBA reset can be released
after the first save word while later words are still pending. The sidecar work
must close both lifecycle races using the same ordered loader-drain protocol
used for RTC source selection.

ROM, save, and BIOS traffic currently cross through three independent loader
FIFOs. Pocket presents data slots in order, but independent CDC paths do not
preserve that order in `clk_sys`. This matters because slot-10 body/footer
routing depends on `save_size_sys`, which in turn depends on `FLASH1M_V`
detection from the ROM stream. The implementation must make the ROM-to-save
ordering causal rather than relying on the current relative loader timing.

The existing `gpio_quirk` is not an RTC-only classification. It also covers
gyro, rumble, generic GPIO, and solar cartridges. RTC sidecar activation must
therefore use a distinct RTC-game classification rather than treating every
GPIO game as an RTC game.

## Data Slots and File Layout

### Cartridge Save Slot

Keep slot 10:

- ID: `10`
- Address: `0x20000000`
- Extensions: `.sav`, `.srm`
- Nonvolatile and optional.
- Parameters: `0x104`.
- Accepted maximum: `0x20010`, so existing normalized saves with an appended
  16-byte RTC footer still load for migration.

Report only the normalized cartridge-save size through datatable size entry
`5`:

- `0x10000` for the current default save allocation.
- `0x20000` for detected 128 KiB Flash.

Never append new RTC data to slot 10.

### RTC Sidecar Slot

Add slot 11:

- ID: `11`
- Address: `0x21000000`
- Extension: `.rtc`
- Nonvolatile and optional.
- Parameters: `0x104`, matching the save slot's platform-common,
  slot-0-derived filename behavior.
- Exact size: 16 bytes.

Analogue defines bit 8, present in `0x104`, as a full core reload including the
bitstream. Bit 7, present in the current `0x84`, restarts the core without
reloading the FPGA. Most persistence/session state in this core resets from PLL
lock, so a soft restart can retain loader-drain, candidate-seen, PSRAM-clear,
and export-snapshot state. Use `0x104` for both nonvolatile slots so any
framework-supported reload involving either slot performs an FPGA reload rather
than a soft restart. This does not make the slots user-reloadable, because bit 0
remains clear. It also does not change filename sharing: bit 2 remains set
(derive from slot 0) and bit 1 remains clear (platform-common).

The ROM slot remains `0x109`; changing games therefore continues to perform a
full FPGA reload, and a normal initial boot necessarily starts from a newly
loaded bitstream. The persistence-slot bitmaps defensively give any additional
supported reload path the same clean-state behavior.

Report the RTC size through datatable size entry `7`:

- `16` for an explicitly classified RTC game or while `Force RTC` is active.
- `0` otherwise, so non-RTC games do not create or export sidecars.

Add an RTC-only output or equivalent lookup alongside `gpio_quirk`. Continue
using `gpio_quirk` for the GBA GPIO/special-module enable, but use the RTC-only
classification plus `Force RTC` for datatable entry `7`. In particular, gyro,
rumble, generic-GPIO, and solar-only games must report zero unless forced.

Alternate the existing continuous datatable writes between entries `5` and
`7`, preserving the current protection against Pocket bookkeeping overwriting
a one-shot size value.

Wrong-sized `.rtc` files are handled by Pocket's exact-size slot contract.
RTL validation covers complete 16-byte transfers and malformed record contents;
it does not attempt to repair a file that Pocket refuses to load.

## Address Routing and Isolation

Classify save-loader and save-unloader traffic before it reaches PSRAM or RTC
persistence logic:

| Local address | Purpose | Destination |
| --- | --- | --- |
| Subregion `0`, offset below normalized save size | Cartridge save body | PSRAM |
| Subregion `0`, offsets `save_size..save_size+15` | Legacy RTC footer | RTC migration capture only |
| Subregion `1`, offsets `0..15` | RTC sidecar | RTC sidecar capture/export only |
| Any other offset or subregion | Unsupported | Ignore or return zero |

Required invariants:

- Only cartridge-save body writes may drive the PSRAM loader path.
- Only cartridge-save body writes may set `save_data_received`.
- A sidecar with no cartridge save must still allow the existing PSRAM clear to
  run to completion.
- Legacy-footer and sidecar writes must never alter cartridge-save PSRAM.
- Slot-10 unloads read only PSRAM and never expose the old footer.
- Slot-11 unloads read only the RTC export snapshot.

## Ordered Write Ingress and Completion Fence

Replace the three independent ROM/save/BIOS `data_loader` instances with one
shared APF write ingress, or an equivalent architecture that proves the same
ordering. Use these concrete rules:

- Cross each normalized 32-bit APF write as one FIFO entry. Do not split it
  into 16-bit entries in `clk_74a`.
- Tag each entry with its destination from `bridge_addr[31:28]`: ROM (`1`),
  save/RTC (`2`), or BIOS (`3`). Split the entry into its address `A` and
  `A+2` halfwords only in `clk_sys`.
- Use ready/valid dispatch in `clk_sys`. ROM and BIOS retain their existing
  destination-specific pacing. Save/RTC traffic remains asserted with stable
  address and data until the routing/PSRAM layer accepts it.
- Use an asynchronous FIFO of at least eight whole APF words and expose its
  write-full indication. APF writes cannot be backpressured, so a data write
  observed while full is a prohibited condition. Size the FIFO against
  maximum-rate APF traffic and worst-case legal save-path stalls.
- Add an entry-kind bit for a completion fence. On the rising edge of
  `dataslot_allcomplete`, latch a fence-pending request in `clk_74a`. Give any
  simultaneous APF data write priority, and enqueue the fence only when no data
  write is being captured and the FIFO has space. Because whole APF words are
  enqueued atomically, the fence cannot pass a delayed second halfword.
- Pocket's protocol sends no further startup slot writes after all-complete.
  Keep fence-pending asserted until the fence is successfully enqueued; do not
  silently place a later startup data write after the fence.
- When the `clk_sys` dispatcher reaches the fence, do not acknowledge it until
  every earlier halfword has been accepted and any final cartridge-save PSRAM
  write has physically completed. Then assert a sticky `loader_drained` state.
  Deassertion of `dataslot_allcomplete` during a later nonvolatile read/flush
  must not revoke this completed boot state.

The shared FIFO also orders ROM detection ahead of save routing. Every ROM
halfword, including a final `FLASH1M_V` match, is accepted by
`save_type_detector` before the first slot-10 halfword can be classified. Do
not derive this guarantee from Pocket slot order plus independent FIFO timing.

For cartridge-save body writes, add an explicit accepted/outstanding protocol
at the PSRAM boundary:

- Launch a body write only while the PSRAM client is idle and `psram_busy` is
  low.
- Register the request and hold other PSRAM clients out while it is
  outstanding.
- After launch, use a one-cycle propagation guard, then wait for `psram_busy`
  to return low before declaring the write physically complete. This mirrors
  the existing clear FSM's guard against delayed busy assertion.
- Do not consume the completion fence, start the no-save clear, declare a
  loaded save ready, release GBA reset, or return PSRAM ownership to gameplay
  while a save write is granted, guarded, busy, or outstanding.

RTC candidate writes and unsupported addresses do not require PSRAM and may be
accepted immediately by the router. Only accepted slot-10 body writes set a
`save_body_seen`/`save_data_received` indication. That indication records
presence only; it must not itself make the save memory ready before the fence.

## RTC Record Format

Keep the existing byte layout:

- Bytes `0..3`: saved Pocket epoch timestamp.
- Bytes `4..9`: packed 42-bit BCD calendar.
- Bytes `10..15`: zero padding.

The meaningful fields remain:

- Year: bits `41..34`
- Month: bits `33..29`
- Day: bits `28..23`
- Weekday: bits `22..20`
- Hour: bits `19..14`
- Minute: bits `13..7`
- Second: bits `6..0`

This is byte-compatible with the current appended footer and K3V's sidecar
record.

## Load, Validation, and Migration

Capture the legacy footer and sidecar into separate logical 16-byte candidate
records. Prefer a banked 16x16 inferred M10K for the record words, with separate
eight-bit seen masks in registers, rather than spending ALMs on 256 data
flip-flops. Uninitialized or stale RAM contents must never count without the
corresponding seen bit.

Index writes by record offset, so words may arrive in either order. A repeated
write replaces the prior value at that word index; final validation examines
the final stored record rather than preserving a sticky error from an
overwritten value. Track all eight received 16-bit words for each candidate.
Do not mark RTC input ready when only the first word arrives, as the current
footer loader does.

Finalize source selection only after:

- Pocket reports all data-slot loading complete.
- The ordered completion fence has traversed the shared ingress after the final
  complete 32-bit APF input write, the dispatcher has emitted every preceding
  halfword, and the final slot-10 PSRAM write has physically completed.
- Pocket's epoch timestamp and BCD date/time have arrived.

Do not substitute `FIFO empty && output FSM idle`, a synchronized
`dataslot_allcomplete`, or a fixed idle-count window for the specified fence.
Those observations are not causally ordered after the FIFO write pointer and
can be true before a late entry becomes visible in the read domain.

Use the same drain barrier to control cartridge-save lifecycle:

- Do not start the no-save PSRAM clear until the fence has completed and no
  slot-10 body word was received.
- Do not declare a loaded cartridge save ready, release GBA reset, or allow the
  gameplay PSRAM path to contend with loading until the fence has completed,
  including physical completion of all slot-10 body writes.
- A sidecar-only load reaches the barrier without setting
  `save_data_received`, then starts and completes the normal PSRAM clear.

Validate each complete candidate before use:

- All eight 16-bit words were received.
- Timestamp is neither zero nor `0xFFFFFFFF`.
- The unused upper six bits of the final calendar word are zero.
- Padding words are zero.
- All BCD digits are valid.
- Second, minute, hour, weekday, month, and day are in range.
- Day validity is month-aware: reject February 30/31 and day 31 in April, June,
  September, and November.
- February 29 is accepted only for a divisible-by-four year in the record's
  `2000..2099` range. This validation does not change live RTC rollover.

Use this precedence:

1. Valid legacy footer from slot 10.
2. Valid sidecar from slot 11.
3. Existing Pocket-clock fallback.

Legacy-first precedence is the downgrade recovery path. An older release can
ignore `.rtc`, create or update an appended footer, and thereby provide the
newest value when the user returns to the sidecar release.

This precedence is intentional even though the record has no source-generation
marker: if a valid but stale footer and a newer valid sidecar coexist, the
footer still wins and the next clean flush replaces the sidecar. Document that
consequence rather than claiming the footer is provably newer in every
mixed-source situation. Do not choose solely by numeric timestamp; host clock
rollback and deliberately adjusted in-game calendar state make that a separate
policy change.

Replay and validate the banked candidates after the fence. This avoids a
same-edge dependency between a final RAM write and validation. Commit the
selected timestamp and calendar to
`rtc_loaded_timestamp`/`rtc_loaded_savedtime` together, then assert the
existing `rtc_data_captured`/load-ready path. Preserve the current relationship
between `RTC_saveLoaded`, Pocket clock receipt, and powered-off catch-up. The
ordered loader barrier may delay the existing GBA reset release until input is
safe, but do not add a catch-up-completion signal or hold reset for catch-up.

An absent or content-invalid sidecar must not invalidate a usable cartridge
save. Use a valid legacy footer if present, otherwise use the existing Pocket
clock fallback. A normal RTC-game flush then replaces the invalid contents with
a valid 16-byte sidecar.

## Exporting the Sidecar

### Stable Export Candidate

The current RTC block exposes the epoch timestamp immediately but updates its
buffered BCD output after ripple carry/normalization. Sampling those outputs on
an unlucky cycle can therefore capture a new timestamp with the previous
calendar.

Maintain a qualified export candidate in `clk_sys`:

- Observe the timestamp/calendar pair continuously after `RTC_saveLoaded`.
- Reset the qualification interval whenever either field changes.
- Update the qualified candidate only after the pair has remained unchanged
  for 16 consecutive `clk_sys` cycles.
- Until a new pair qualifies, retain the previous coherent candidate.

Implement this with a saturating counter that resets to zero on either-field
change. Commit only on the sixteenth subsequent equality sample; the change
sample itself does not count toward the stable interval.

The 16-cycle guard is derived from the current VHDL, not from the intended
one-second rate. Its worst `2099-12-31 23:59:59` transition can take 11 clock
edges from the timestamp increment through second, minute, hour, day, month,
two-digit year normalization and publication into the buffered calendar
output. Sixteen stable samples provide a simple power-of-two counter and five
cycles of margin beyond that exact carry chain, preventing the intermediate
timestamp/old-calendar pair from qualifying.

At source-selection commit, initialize the qualified export candidate from the
same selected timestamp/calendar pair (legacy footer, sidecar, or Pocket
fallback). This gives the candidate a valid coherent value before the RTC
block's outputs complete their first qualification interval. An immediate exit
after boot or during powered-off catch-up must preserve valid input state rather
than exporting reset values.

During steady-state gameplay this may export a value up to one second old when
a flush begins during a tick, but it must not export fields from different RTC
instants.

### Per-Transfer Snapshot

When the unloader accepts slot 11 offset `0`, copy the qualified candidate
into a transfer snapshot. Serve all eight words from that snapshot:

- Words `0..1`: timestamp.
- Words `2..4`: packed calendar, with unused bits zero.
- Words `5..7`: zero.

The offset-0 response itself must belong to the newly captured snapshot. Avoid
a same-edge nonblocking-assignment dependency that returns word 0 from the old
snapshot while later words use the new one. Either serve word 0 directly from
the qualified candidate while capturing it or stage transaction start early
enough that the unloader samples the updated snapshot.

A later unload beginning again at offset `0` captures a fresh qualified
candidate. Slot-10 unloading remains PSRAM-backed and uses the normalized save
size only.

## Cross-Core and Downgrade Behavior

Both nonvolatile slots derive their filename from ROM slot 0 and remain
platform-common. The conventional `.sav` can therefore be shared with other
Pocket GBA cores without trimming.

K3V uses the same 16-byte `.rtc` record, so its sidecar is compatible. Do not
claim compatibility with unrelated EverDrive or emulator RTC formats merely
because they also use a `.rtc` extension.

Pin this claim with at least one known K3V-produced 16-byte fixture. Verify that
the fixture loads field-for-field and that this core's exported record can be
loaded by K3V. Metadata compatibility also depends on both slots remaining
platform-common and slot-0-derived. This core deliberately matches K3V's
current `0x104` value as well, but binary record compatibility comes from the
16-byte payload rather than from equal restart bitmaps.

Use K3V v0.1.5's published persistence vector as the first canonical
fixture: timestamp `0x66000020`, calendar `2025-02-28`, weekday `5`,
`16:45:12`. Its expected 16 bytes are:

```text
20 00 00 66 92 A2 55 54 94 00 00 00 00 00 00 00
```

Also retain a fixture captured from an actual K3V sidecar export for the
hardware exchange check; the constructed reference vector alone does not prove
Pocket-level metadata/path behavior.

Document downgrade behavior:

- The current release ignores the sidecar.
- It initializes RTC through its existing path and may append a footer to
  `.sav`.
- Returning to the sidecar release selects the valid legacy footer first,
  writes a conventional-size `.sav`, and refreshes `.rtc`.

## Verification

### Build Verification

- Run SystemVerilog analysis/elaboration for the new persistence and routing
  logic.
- Run a full Quartus build.
- Confirm no new critical warnings, unconstrained paths, or negative timing
  slack.
- Confirm the added persistence and snapshot logic fits within the current
  resource margin.

### Hardware Verification

- Boot an RTC game with a conventional `.sav` and no sidecar; confirm fallback
  initialization and creation of a 16-byte `.rtc`.
- Boot with a valid sidecar and confirm powered-off elapsed time is retained
  through the existing RTC path.
- Upgrade a real footer-bearing save and confirm the next clean exit produces a
  conventional-size `.sav` plus a 16-byte `.rtc`.
- Move the resulting `.sav` through another Pocket GBA core or save tool
  without trimming.
- Boot with a sidecar but no `.sav`; confirm cartridge-save PSRAM is cleared
  rather than treated as loaded.
- Downgrade once to the current release, allow it to write a footer, return to
  the sidecar release, and confirm the legacy value wins and refreshes
  `.rtc`.
- Boot a non-RTC game and confirm no `.rtc` file is created.
- Boot representative non-RTC GPIO games and confirm gyro, rumble, generic
  GPIO, and solar classification alone does not create `.rtc` files.
- Exit immediately after booting from a valid sidecar and confirm the sidecar
  is not replaced with reset or zero state.
- Exchange a fixture in both directions with K3V and confirm the timestamp and
  calendar fields are preserved.
- Change games and confirm the slot-0 `0x109` full reload clears the prior
  session's loader, PSRAM-clear, RTC-candidate, and export-snapshot state. If
  the installed Pocket firmware exposes another supported reload path involving
  slot 10 or 11, exercise it and confirm their `0x104` bitmaps also reload the
  bitstream rather than retaining that state.

## Patch Structure

Keep the work sidecar-specific and reviewable:

1. Persistence record validation and source selection.
2. Shared whole-word ingress and ordered completion fence, followed by
   slot-10/slot-11 address isolation and physical PSRAM completion guards for
   reset/readiness, clear, and `save_data_received`.
3. Sidecar and legacy-footer capture, validation, precedence, and Pocket
   fallback.
4. RTC-only classification, normalized slot-10/slot-11 sizing, and qualified,
   snapshotted slot-11 export.
5. `data.json`, migration documentation, build evidence, and hardware
   verification.

Do not combine divider, leap-year, catch-up gating, save-size detection,
resource optimization, or RTC command changes with this series.

## Research Basis

- Analogue's `data.json` documentation defines bit 2 as slot-0-derived naming,
  bit 7 as restart without FPGA reload, bit 8 as full bitstream reload, exact
  size checking, and datatable-controlled nonvolatile export size:
  <https://www.analogue.co/developer/docs/core-definition-files/data-json>
- Analogue's boot documentation specifies ordered slot presentation followed
  by all-complete and then the Pocket RTC command. The shared ingress preserves
  that presentation order after CDC rather than assuming independent loaders
  drain in the same order:
  <https://www.analogue.co/developer/docs/core-boot-process>
- K3V v0.1.5 uses slot 10/11 at `0x20000000`/`0x21000000`, a 16-byte exact RTC
  slot, and `0x104` for both nonvolatile slots:
  <https://github.com/K3v-68/k3v-gba/blob/7131cc7a58daf812cb6e3140eedab1a47c7203af/pkg/Cores/K3V.GBA/data.json>
- K3V's shared-ingress implementation provides a reviewed reference for
  crossing whole APF words atomically, destination tagging, write-full
  detection, and ready/valid dispatch. This plan adds the causally ordered
  fence rather than adopting an idle-count completion heuristic:
  <https://github.com/K3v-68/k3v-gba/blob/7131cc7a58daf812cb6e3140eedab1a47c7203af/src/fpga/pocket/apf_write_ingress.sv>
- K3V's persistence RTL establishes the record layout, validation fields,
  legacy-first precedence, and canonical vector used above:
  <https://github.com/K3v-68/k3v-gba/blob/7131cc7a58daf812cb6e3140eedab1a47c7203af/src/fpga/core/rtc_persistence.sv>
