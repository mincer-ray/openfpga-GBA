// Multiplayer link diagnostic (parent side).
//
// Run on the device under test in the PARENT (purple plug) position. Children
// can be real GBAs with no cartridge sitting on the BIOS multiboot screen: the
// ROM sends the multiboot "hello" word (0x6200) once per frame and shows, per
// exchange, exactly what the parent hardware reports.
//
// Reference (mGBA, measured on hardware) cycles from start to completion at
// 115200 baud: 1p 3140, 2p 5755, 3p 8376, 4p 10486.
//
// A: toggle baud 115200 / 9600     B: clear statistics
// START: pause/resume transfers    SELECT: toggle send word 6200 / slot-tag

#include <gba_console.h>
#include <gba_input.h>
#include <gba_interrupt.h>
#include <gba_sio.h>
#include <gba_systemcalls.h>
#include <gba_timers.h>
#include <gba_video.h>
#include <stdio.h>
#include <string.h>

#define R_SIOCNT    (*(volatile u16 *)0x04000128)
#define R_SIOMLT    (*(volatile u16 *)0x0400012A)
#define R_RCNT      (*(volatile u16 *)0x04000134)
#define SLOT_DATA(n)  (*(volatile u16 *)(0x04000120 + 2 * (n)))

static volatile u32 irq_count, irq_err, irq_end_time, irq_pending_start;
static volatile u16 irq_siocnt, irq_multi[4];
static volatile u32 slot_ok[4];
static volatile u16 slot_last[4];

static u32 starts, ignored_starts, missed_irqs, stuck_busy;
static u32 min_cycles = 0xFFFFFFFF, max_cycles, last_cycles;
static u32 start_time;
static u16 idle_siocnt, idle_rcnt, after_start_siocnt;

static inline u32 now(void) {
    u16 hi, lo, hi2;
    do {
        hi = REG_TM1CNT_L;
        lo = REG_TM0CNT_L;
        hi2 = REG_TM1CNT_L;
    } while (hi != hi2);
    return ((u32)hi << 16) | lo;
}

static void serial_isr(void) {
    irq_end_time = now();
    irq_siocnt = R_SIOCNT;
    for (int i = 0; i < 4; i++) {
        u16 v = SLOT_DATA(i);
        irq_multi[i] = v;
        if (v != 0xFFFF) {
            slot_ok[i]++;
            slot_last[i] = v;
        }
    }
    if (irq_siocnt & 0x40) irq_err++;
    irq_count++;
    irq_pending_start = 0;
}

static void clear_stats(void) {
    REG_IME = 0;
    irq_count = irq_err = 0;
    for (int i = 0; i < 4; i++) { slot_ok[i] = 0; slot_last[i] = 0xFFFF; irq_multi[i] = 0xFFFF; }
    REG_IME = 1;
    starts = ignored_starts = missed_irqs = stuck_busy = 0;
    min_cycles = 0xFFFFFFFF; max_cycles = last_cycles = 0;
}

int main(void) {
    irqInit();
    irqSet(IRQ_SERIAL, serial_isr);
    irqEnable(IRQ_VBLANK | IRQ_SERIAL);
    consoleDemoInit();

    REG_TM0CNT_L = 0; REG_TM1CNT_L = 0;
    REG_TM1CNT_H = TIMER_START | TIMER_COUNT;
    REG_TM0CNT_H = TIMER_START;

    int baud = 3, paused = 0, tagmode = 0;
    R_RCNT = 0;
    R_SIOCNT = 0x2000 | 0x4000 | baud;
    clear_stats();

    u32 frame = 0;
    while (1) {
        VBlankIntrWait();
        frame++;
        scanKeys();
        u16 k = keysDown();
        if (k & KEY_B) clear_stats();
        if (k & KEY_START) paused ^= 1;
        if (k & KEY_SELECT) tagmode ^= 1;
        if (k & KEY_A) {
            baud = (baud == 3) ? 0 : 3;
            R_SIOCNT = 0x2000 | 0x4000 | baud;
            clear_stats();
        }

        // Account for the previous exchange.
        if (irq_count && irq_pending_start == 0 && starts) {
            last_cycles = irq_end_time - start_time;
            if (last_cycles < min_cycles) min_cycles = last_cycles;
            if (last_cycles > max_cycles) max_cycles = last_cycles;
        }

        u16 cnt = R_SIOCNT;
        if (!paused) {
            if (cnt & 0x80) {
                stuck_busy++;
            } else {
                if (irq_pending_start) missed_irqs++;
                idle_siocnt = cnt;
                idle_rcnt = R_RCNT;
                R_SIOMLT = tagmode ? (u16)(0xA000 | (frame & 0xFFF)) : 0x6200;
                irq_pending_start = 1;
                start_time = now();
                R_SIOCNT = cnt | 0x80;
                after_start_siocnt = R_SIOCNT;
                if (!(after_start_siocnt & 0x80) && irq_pending_start) ignored_starts++;
                starts++;
            }
        }

        if ((frame & 7) == 0) {
            iprintf("\x1b[0;0HMP DIAG %s %s %s   \n",
                    baud == 3 ? "115200" : "9600  ",
                    tagmode ? "TAG " : "6200",
                    paused ? "PAUSED" : "      ");
            iprintf("IDLE SIOCNT %04X RCNT %04X\n", idle_siocnt, idle_rcnt);
            iprintf(" SI=%d SD=%d ID=%d ERR=%d\n",
                    (idle_siocnt >> 2) & 1, (idle_siocnt >> 3) & 1,
                    (idle_siocnt >> 4) & 3, (idle_siocnt >> 6) & 1);
            iprintf("AFTER START %04X\n", after_start_siocnt);
            iprintf("IRQ SIOCNT  %04X\n\n", irq_siocnt);
            iprintf("STARTS %7lu IRQS %7lu\n", starts, irq_count);
            iprintf("IGNORED %6lu NOIRQ %6lu\n", ignored_starts, missed_irqs);
            iprintf("BUSY>1F %6lu ERRS %7lu\n\n", stuck_busy, irq_err);
            iprintf("CYC LAST %6lu\n", last_cycles);
            iprintf("    MIN %6lu MAX %6lu\n", min_cycles == 0xFFFFFFFF ? 0 : min_cycles, max_cycles);
            iprintf("REF 2P 5755 3P 8376 4P 10486\n\n");
            iprintf("SLOT LAST  OKCOUNT LASTOK\n");
            for (int i = 0; i < 4; i++)
                iprintf(" %d   %04X %8lu  %04X\n", i, irq_multi[i], slot_ok[i], slot_last[i]);
        }
    }
}
