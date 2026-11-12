// The mini-kernel guest of hvc-stress2.c, linked at its guest physical address 0x10000 (MMU on,
// identity-mapped). Assemble: cc -c hvc-stress2-guest.S && objcopy -O binary hvc-stress2-guest.o hvc-stress2-guest.bin
//
// Each EL0 `svc` (or fault) enters the EL1 vector as vphone-linux patches it (`hvc 0x1340` first),
// runs a little of what XNU does on an entry (PAC-signed frame, per-CPU data through TPIDR_EL1,
// the GXF_STATUS check `hvc 0x80ae; cmp x14, #0`) and returns with the patched eret (`hvc 0x1341`).
// hvc 0x13fc / 0x13ff / 0x13fe mark the instruction after a patched hvc that didn't trap.

    .text
    .globl _start
_start:

// 0x10000: the TLB flush stub, run with the MMU off (local, then broadcast at +0x18).
stub:
    tlbi    vmalle1
    dsb     nsh
    ic      iallu
    dsb     nsh
    isb
    hvc     #0x1300
stub_is:
    tlbi    vmalle1is
    dsb     ish
    ic      ialluis
    dsb     ish
    isb
    hvc     #0x1300

// 0x10800: EL1 vectors.
    .org    0x800
vectors:
    .org    0x800 + 0x000
    hvc     #0x13fd             // sync from EL1 (SP0): unexpected
    b       .
    .org    0x800 + 0x200
    hvc     #0x13fd             // sync from EL1 (SPx): unexpected
    b       .
    .org    0x800 + 0x400       // sync from EL0
    hvc     #0x1340
    hvc     #0x13fc
    b       entry
    .org    0x800 + 0x480       // IRQ from EL0
    hvc     #0x1340
    hvc     #0x13fc
    b       entry
    .org    0x800 + 0x500       // FIQ from EL0
    hvc     #0x1340
    hvc     #0x13fc
    b       entry
    .org    0x800 + 0x580
    hvc     #0x13fd
    b       .
    .org    0x1000

// The kernel's entry, on SP_EL1 (each vCPU's own stack, TPIDR_EL1 its per-CPU data).
entry:
    sub     sp, sp, #64
    stp     x29, x30, [sp, #48]
    add     x29, sp, #48
    stp     x9, x10, [sp]
    stp     x14, x15, [sp, #16]
    mrs     x9, tpidr_el1
    ldr     x10, [x9]
    add     x10, x10, #1
    str     x10, [x9]
    bl      check
    hvc     #0x1420             // genter: into the mini-SPTM, back after its gexit
    ldp     x14, x15, [sp, #16]
    ldp     x9, x10, [sp]
    ldp     x29, x30, [sp, #48]
    add     sp, sp, #64
    hvc     #0x1341             // eret, emulated by the host
    hvc     #0x13fe
    b       .

// As XNU's GXF_STATUS check before each SPTM call: x14 is nonzero unless the hvc wrote it.
check:
    pacibsp
    mov     x14, #1
    hvc     #0x80ae
    cmp     x14, #0
    b.eq    1f
    hvc     #0x13ff
1:  autibsp
    ret

// 0x14000: EL0 (its own page, mapped for EL0).
    .org    0x4000
el0:
    add     x1, x1, #1
    str     x1, [x3]            // the data page, whose access flag the host may clear
    svc     #0
    b       el0

// 0x30000: the mini-SPTM, run in the guarded world (its own bank and page tables), as SPTM's
// handlers do: read its per-CPU data (M1-style TPIDR_GL through a patched hvc), touch it, gexit.
    .org    0x20000
gl_entry:
    hvc     #0x8aa8             // mrs x8, TPIDR_GL (an M1 GL register, patched)
    mrs     x9, tpidr_el1       // native: the guarded bank is live
    ldr     x10, [x9]
    add     x10, x10, #1
    str     x10, [x9]
    str     x10, [sp, #-16]!
    ldr     x10, [sp], #16
    hvc     #0x1400             // gexit
    b       .
