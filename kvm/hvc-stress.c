// Looks for an `hvc` that doesn't trap to KVM, the pattern behind vphone-linux's KVM hangs, on a
// bare guest: EL0 loops on `svc`, whose EL1 vector starts with `hvc #0x1340; hvc #0x13fc`. The
// host answers 0x1340 by returning to EL0 as QEMU's apple-virt does (PC = ELR, PSTATE = SPSR), so
// 0x13fc is only reached by an entry whose first `hvc` didn't trap. The guest also counts its own
// trips in x1, which the host checks against the exits it saw.
//
//   cc -O2 -Wall -pthread -o hvc-stress hvc-stress.c && ./hvc-stress [seconds] [vcpus] [sctlr]
//
// `sctlr` 1 also rewrites SCTLR_EL1 on every exit, as apple-virt's PAC key switch does.
// `stub` N (5th argument) turns the MMU on and sends every Nth entry through a TLB flush stub run
// with the MMU off (tlbi; dsb; ic iallu; dsb; isb; hvc #0x1300), as apple-virt's world switch does.
// `irq` 1 (6th argument) runs a host thread that raises and lowers every vCPU's IRQ and FIQ lines
// (KVM_IRQ_LINE), taken from EL0 through vector slots patched like slot 8.
// `sprr` 1 (7th argument) also has EL0 write SPRR_UPERM_EL0 (S3_6_C15_C1_5) before each `svc`, as
// a JIT does; the M1 UNDEFs it to EL1 and the host steps over it as apple-virt does.
// `af` N (8th argument, needs `stub`) has EL0 store to a data page, and every Nth `svc` the host
// clears that page's access flag and sends the vCPU through the broadcast stub (tlbi vmalle1is),
// so the next store takes an access-flag fault, which the host repairs as the kernel would.
// `noexs` 1 (9th argument) clears SCTLR_EL1.EIS and EOS, as XNU does on Armv8.5 Apple parts: exception
// entry and eret are then not context-synchronizing.
// `wp` 1 runs a host thread that write-protects and unprotects a page next to the guest's code
// (KVM_ARM_SET_WRITE_PROTECT, which unmaps it at stage 2), as apple-virt does for page tables.
#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define RAM_GPA  0x10000ULL
#define RAM_SIZE 0x20000ULL
#define STUB_GPA RAM_GPA            // the TLB flush stub, run with the MMU off
#define L1_GPA   (RAM_GPA + 0x8000) // identity page tables (16 KiB granule, 39-bit VA)
#define L2_GPA   (RAM_GPA + 0xC000)
#define L3_GPA   (RAM_GPA + 0x10000)
#define DATA_GPA (RAM_GPA + 0x14000) // EL0's store target, whose access flag the host clears
#define VBAR_GPA (RAM_GPA + 0x800)
#define EL0_GPA  (RAM_GPA + 0x4000)

#define CORE_REG(x) (KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | (offsetof(struct kvm_regs, x) / sizeof(uint32_t)))
#define SYS_REG(op0, op1, crn, crm, op2)                                                                              \
    (KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM64_SYSREG | ((uint64_t)(op0) << 14) | ((op1) << 11) |             \
     ((crn) << 7) | ((crm) << 3) | (op2))
#define HVC(imm) (0xD4000002u | ((imm) << 5))

static int vm, kvm_fd, run_size, seconds = 10, use_sctlr, use_wp, stub_every, use_irq, nvcpus, use_sprr, af_every,
           no_exs;
static uint64_t *data_pte;
static unsigned long irq_ops;
static unsigned long wp_ops;
static volatile int stop;

static void die(const char *what)
{
    perror(what);
    exit(2);
}

static uint64_t get_reg(int vcpu, uint64_t id)
{
    uint64_t v;
    struct kvm_one_reg r = {.id = id, .addr = (uintptr_t)&v};
    if (ioctl(vcpu, KVM_GET_ONE_REG, &r)) die("KVM_GET_ONE_REG");
    return v;
}

static void set_reg(int vcpu, uint64_t id, uint64_t v)
{
    struct kvm_one_reg r = {.id = id, .addr = (uintptr_t)&v};
    if (ioctl(vcpu, KVM_SET_ONE_REG, &r)) die("KVM_SET_ONE_REG");
}

struct result {
    unsigned long exits, skips, mismatches, other;
};

static void *vcpu_thread(void *arg)
{
    struct result *res = arg;
    int vcpu = (int)(intptr_t)res->other;
    struct kvm_run *r = mmap(NULL, run_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu, 0);
    uint64_t sctlr, count = 0;
    int flip = 0;

    if (r == MAP_FAILED) die("mmap kvm_run");
    res->other = 0;
    sctlr = get_reg(vcpu, SYS_REG(3, 0, 1, 0, 0));
    if (no_exs) {
        sctlr &= ~((1ULL << 22) | (1ULL << 11));  // EIS, EOS
        set_reg(vcpu, SYS_REG(3, 0, 1, 0, 0), sctlr);
        {
            static int told;

            if (!told++) {
                printf("  SCTLR_EL1 written 0x%llx, reads back 0x%llx\n", (unsigned long long)sctlr,
                       (unsigned long long)get_reg(vcpu, SYS_REG(3, 0, 1, 0, 0)));
            }
        }
    }
    uint64_t resume_pc = 0, resume_ps = 0;
    unsigned long n = 0;

    if (stub_every) {
        set_reg(vcpu, SYS_REG(3, 0, 10, 2, 0), 0xFF);               // MAIR_EL1: attr 0 normal WB
        set_reg(vcpu, SYS_REG(3, 0, 2, 0, 2),                        // TCR_EL1
                25 | (1ULL << 8) | (1ULL << 10) | (3ULL << 12) | (2ULL << 14) | (1ULL << 23) | (1ULL << 32));
        set_reg(vcpu, SYS_REG(3, 0, 2, 0, 0), L1_GPA);               // TTBR0_EL1
        sctlr |= 1 | (1 << 2) | (1 << 12);                           // M, C, I
        set_reg(vcpu, SYS_REG(3, 0, 1, 0, 0), sctlr);
    }
    set_reg(vcpu, SYS_REG(3, 0, 12, 0, 0), VBAR_GPA);
    set_reg(vcpu, CORE_REG(regs.pc), EL0_GPA);
    set_reg(vcpu, CORE_REG(regs.pstate), 0x0); // EL0t, interrupts unmasked
    set_reg(vcpu, CORE_REG(regs.regs[1]), 0);
    set_reg(vcpu, CORE_REG(regs.regs[3]), DATA_GPA);

    while (!stop) {
        if (ioctl(vcpu, KVM_RUN, 0) && errno != EINTR) die("KVM_RUN");
        if (r->exit_reason != KVM_EXIT_HYPERCALL) {
            res->other++;
            continue;
        }
        if (r->hypercall.nr == 0x1300) {
            // Back from the stub: MMU on, then where the entry was going.
            set_reg(vcpu, SYS_REG(3, 0, 1, 0, 0), sctlr);
            set_reg(vcpu, CORE_REG(regs.pstate), resume_ps);
            set_reg(vcpu, CORE_REG(regs.pc), resume_pc);
            continue;
        }
        if (r->hypercall.nr == 0x13fc) {
            uint64_t elr = get_reg(vcpu, CORE_REG(elr_el1)), spsr = get_reg(vcpu, CORE_REG(spsr[KVM_SPSR_EL1]));

            res->skips++;
            if (res->skips <= 5) {
                printf("  vcpu fd %d: SKIP after %lu exits: ELR 0x%llx SPSR 0x%llx x1 %llu\n", vcpu, res->exits,
                       (unsigned long long)elr, (unsigned long long)spsr,
                       (unsigned long long)get_reg(vcpu, CORE_REG(regs.regs[1])));
            }
            count++;
            set_reg(vcpu, CORE_REG(regs.pstate), spsr);
            set_reg(vcpu, CORE_REG(regs.pc), elr);
            continue;
        }
        if (r->hypercall.nr == 0x1342 || r->hypercall.nr == 0x1343) {
            // An IRQ or FIQ from EL0: straight back, as apple-virt's no-op entry does.
            res->exits++;
            set_reg(vcpu, CORE_REG(regs.pstate), get_reg(vcpu, CORE_REG(spsr[KVM_SPSR_EL1])));
            set_reg(vcpu, CORE_REG(regs.pc), get_reg(vcpu, CORE_REG(elr_el1)));
            continue;
        }
        if (r->hypercall.nr != 0x1340) {
            res->other++;
            continue;
        }
        res->exits++;
        if (af_every && (get_reg(vcpu, SYS_REG(3, 0, 5, 2, 0)) >> 26) == 0x24) {
            // EL0's store hit the cleared access flag: set it, retry the store through the stub.
            __atomic_or_fetch(data_pte, 1ULL << 10, __ATOMIC_SEQ_CST);
            resume_ps = get_reg(vcpu, CORE_REG(spsr[KVM_SPSR_EL1]));
            resume_pc = get_reg(vcpu, CORE_REG(elr_el1));
            set_reg(vcpu, SYS_REG(3, 0, 1, 0, 0), sctlr & ~1ULL);
            set_reg(vcpu, CORE_REG(regs.pstate), 0x3C5);
            set_reg(vcpu, CORE_REG(regs.pc), STUB_GPA + 0x18);
            res->other++;
            continue;
        }
        if (use_sprr && (get_reg(vcpu, SYS_REG(3, 0, 5, 2, 0)) >> 26) != 0x15) {
            // Not the `svc`: the SPRR write (or whatever else EL0 trapped on). Step over it.
            static unsigned long told;
            uint64_t esr = get_reg(vcpu, SYS_REG(3, 0, 5, 2, 0));

            if (told++ < 2) printf("  EL0 non-svc entry, ESR 0x%llx\n", (unsigned long long)esr);
            set_reg(vcpu, CORE_REG(regs.pstate), get_reg(vcpu, CORE_REG(spsr[KVM_SPSR_EL1])));
            set_reg(vcpu, CORE_REG(regs.pc), get_reg(vcpu, CORE_REG(elr_el1)) + 4);
            continue;
        }
        count++;
        if (get_reg(vcpu, CORE_REG(regs.regs[1])) != count) {
            res->mismatches++;
            count = get_reg(vcpu, CORE_REG(regs.regs[1]));
        }
        if (use_sctlr) {
            flip ^= 1;
            set_reg(vcpu, SYS_REG(3, 0, 1, 0, 0), flip ? sctlr | (1ULL << 31) : sctlr); // EnIA
        }
        // Back to EL0 as apple-virt's fast eret: PSTATE from SPSR_EL1, then PC from ELR_EL1.
        if (af_every && n % af_every == 0) {
            // As madvise: the page loses its access flag, and the TLB is flushed everywhere.
            __atomic_and_fetch(data_pte, ~(1ULL << 10), __ATOMIC_SEQ_CST);
            resume_ps = get_reg(vcpu, CORE_REG(spsr[KVM_SPSR_EL1]));
            resume_pc = get_reg(vcpu, CORE_REG(elr_el1));
            set_reg(vcpu, SYS_REG(3, 0, 1, 0, 0), sctlr & ~1ULL);
            set_reg(vcpu, CORE_REG(regs.pstate), 0x3C5);
            set_reg(vcpu, CORE_REG(regs.pc), STUB_GPA + 0x18);
            n++;
            continue;
        }
        if (stub_every && ++n % stub_every == 0) {
            // ... through the TLB flush stub first, MMU off, as a world switch does.
            resume_ps = get_reg(vcpu, CORE_REG(spsr[KVM_SPSR_EL1]));
            resume_pc = get_reg(vcpu, CORE_REG(elr_el1));
            set_reg(vcpu, SYS_REG(3, 0, 1, 0, 0), sctlr & ~1ULL);
            set_reg(vcpu, CORE_REG(regs.pstate), 0x3C5);
            set_reg(vcpu, CORE_REG(regs.pc), STUB_GPA);
            continue;
        }
        set_reg(vcpu, CORE_REG(regs.pstate), get_reg(vcpu, CORE_REG(spsr[KVM_SPSR_EL1])));
        set_reg(vcpu, CORE_REG(regs.pc), get_reg(vcpu, CORE_REG(elr_el1)));
    }
    return NULL;
}

// A page the guest never touches, in the same memslot as its code.
#define WP_GPA (RAM_GPA + 0x18000)

static void *irq_thread(void *arg)
{
    (void)arg;
    while (!stop) {
        for (int v = 0; v < nvcpus; v++) {
            for (int line = 0; line <= 1; line++) {          // KVM_ARM_IRQ_CPU_IRQ, _FIQ
                for (int level = 1; level >= 0; level--) {
                    struct kvm_irq_level il = {
                        .irq = (KVM_ARM_IRQ_TYPE_CPU << KVM_ARM_IRQ_TYPE_SHIFT) | (v << KVM_ARM_IRQ_VCPU_SHIFT) | line,
                        .level = level};

                    if (ioctl(vm, KVM_IRQ_LINE, &il)) die("KVM_IRQ_LINE");
                    irq_ops++;
                }
            }
        }
        usleep(20);
    }
    return NULL;
}

static void *wp_thread(void *arg)
{
    long page = sysconf(_SC_PAGESIZE);

    (void)arg;
    while (!stop) {
        for (int on = 1; on >= 0; on--) {
            struct kvm_arm_write_protect wp = {
                .gpa = WP_GPA, .size = page, .flags = on ? KVM_ARM_WRITE_PROTECT_ENABLE : 0};

            if (ioctl(vm, KVM_ARM_SET_WRITE_PROTECT, &wp)) die("KVM_ARM_SET_WRITE_PROTECT");
            wp_ops++;
        }
    }
    return NULL;
}

int main(int argc, char **argv)
{
    int nvcpu = (int)sysconf(_SC_NPROCESSORS_ONLN);

    if (argc > 1) seconds = atoi(argv[1]);
    if (argc > 2) nvcpu = atoi(argv[2]);
    if (argc > 3) use_sctlr = atoi(argv[3]);
    if (argc > 4) use_wp = atoi(argv[4]);
    if (argc > 5) stub_every = atoi(argv[5]);
    if (argc > 6) use_irq = atoi(argv[6]);
    nvcpus = nvcpu;

    kvm_fd = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm_fd < 0) die("/dev/kvm");
    vm = ioctl(kvm_fd, KVM_CREATE_VM, 0);
    if (vm < 0) die("KVM_CREATE_VM");
    struct kvm_enable_cap ec = {.cap = KVM_CAP_ARM_HVC_TO_USER};
    if (ioctl(vm, KVM_ENABLE_CAP, &ec)) die("enable HVC_TO_USER (boot linux-aurora-kvm)");
    struct kvm_enable_cap fc = {.cap = KVM_CAP_ARM_FAULT_TO_USER};
    if (ioctl(vm, KVM_ENABLE_CAP, &fc)) die("enable FAULT_TO_USER");

    uint32_t *ram = mmap(NULL, RAM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ram == MAP_FAILED) die("mmap");
    // EL1 vectors at VBAR_GPA: slot 8 (sync from a lower AArch64 EL) as vphone-linux patches it.
    for (int i = 0; i < 0x800 / 4; i++) ram[(VBAR_GPA - RAM_GPA) / 4 + i] = 0x14000000; // b .
    uint32_t *slot8 = &ram[(VBAR_GPA - RAM_GPA + 0x400) / 4];
    slot8[0] = HVC(0x1340);
    slot8[1] = HVC(0x13fc);
    slot8[2] = 0x14000000; // b .
    for (int s9 = 1; s9 <= 2; s9++) {       // slots 9 and 10: IRQ and FIQ from a lower EL
        slot8[s9 * 0x20 + 0] = HVC(0x1341 + s9);
        slot8[s9 * 0x20 + 1] = HVC(0x13fc);
        slot8[s9 * 0x20 + 2] = 0x14000000;
    }
    // EL0: loop: add x1, x1, #1; [msr s3_6_c15_c1_5, x2;] svc #0; b loop
    uint32_t *el0 = &ram[(EL0_GPA - RAM_GPA) / 4];
    if (argc > 7) use_sprr = atoi(argv[7]);
    if (argc > 8) af_every = atoi(argv[8]);
    if (argc > 9) no_exs = atoi(argv[9]);
    if (af_every) {
        el0[0] = 0x91000421; // add x1, x1, #1
        el0[1] = 0xF9000061; // str x1, [x3]
        el0[2] = 0xD4000001; // svc #0
        el0[3] = 0x17FFFFFD; // b loop
    } else if (use_sprr) {
        el0[0] = 0x91000421;
        el0[1] = 0xD51EF1A2; // msr s3_6_c15_c1_5, x2
        el0[2] = 0xD4000001;
        el0[3] = 0x17FFFFFD;
    } else {
        el0[0] = 0x91000421;
        el0[1] = 0xD4000001;
        el0[2] = 0x17FFFFFE;
    }
    // The stub: tlbi vmalle1; dsb nsh; ic iallu; dsb nsh; isb; hvc #0x1300
    static const uint32_t stub[] = {0xD508871F, 0xD503379F, 0xD508751F, 0xD503379F, 0xD5033FDF, HVC(0x1300),
                                    // +0x18, broadcast: tlbi vmalle1is; dsb ish; ic ialluis; dsb ish; isb; hvc
                                    0xD508831F, 0xD5033B9F, 0xD508711F, 0xD5033B9F, 0xD5033FDF, HVC(0x1300)};
    memcpy(&ram[(STUB_GPA - RAM_GPA) / 4], stub, sizeof(stub));
    // L1[0] -> L2; L2[0] = a 32 MiB block at 0: AF, inner shareable, read-only at EL0 and EL1, attr 0.
    uint64_t *l1 = (uint64_t *)&ram[(L1_GPA - RAM_GPA) / 4], *l2 = (uint64_t *)&ram[(L2_GPA - RAM_GPA) / 4];
    l1[0] = L2_GPA | 3;
    l2[0] = 0 | (1ULL << 10) | (3ULL << 8) | (3ULL << 6) | 1;
    if (argc > 8 && atoi(argv[8])) {
        // 16 KiB pages over the RAM instead of the block: code read-only, the data page EL0-writable.
        uint64_t *l3 = (uint64_t *)&ram[(L3_GPA - RAM_GPA) / 4];

        l2[0] = L3_GPA | 3;
        for (uint64_t pa = RAM_GPA; pa < RAM_GPA + RAM_SIZE; pa += 0x4000) {
            uint64_t ap = pa == DATA_GPA ? (1ULL << 6) : (3ULL << 6);

            l3[pa >> 14] = pa | (1ULL << 10) | (3ULL << 8) | ap | 3;
        }
        data_pte = &l3[DATA_GPA >> 14];
    }
    __builtin___clear_cache((char *)ram, (char *)ram + RAM_SIZE);
    struct kvm_userspace_memory_region slot = {
        .slot = 0, .guest_phys_addr = RAM_GPA, .memory_size = RAM_SIZE, .userspace_addr = (uintptr_t)ram};
    if (ioctl(vm, KVM_SET_USER_MEMORY_REGION, &slot)) die("KVM_SET_USER_MEMORY_REGION");
    run_size = ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);

    struct kvm_vcpu_init init;
    if (ioctl(vm, KVM_ARM_PREFERRED_TARGET, &init)) die("KVM_ARM_PREFERRED_TARGET");
    pthread_t th[64];
    struct result res[64];
    memset(res, 0, sizeof(res));
    for (int i = 0; i < nvcpu; i++) {
        int vcpu = ioctl(vm, KVM_CREATE_VCPU, i);
        if (vcpu < 0) die("KVM_CREATE_VCPU");
        if (ioctl(vcpu, KVM_ARM_VCPU_INIT, &init)) die("KVM_ARM_VCPU_INIT");
        res[i].other = (unsigned long)vcpu;
    }
    for (int i = 0; i < nvcpu; i++) pthread_create(&th[i], NULL, vcpu_thread, &res[i]);
    pthread_t wpt, irqt;
    if (use_wp) pthread_create(&wpt, NULL, wp_thread, NULL);
    if (use_irq) pthread_create(&irqt, NULL, irq_thread, NULL);
    printf("%d vCPUs for %d s, SCTLR rewrites %s, write-protect churn %s, MMU %s, stub every %d, EIS/EOS %s\n",
           nvcpu, seconds, use_sctlr ? "on" : "off", use_wp ? "on" : "off", stub_every ? "on" : "off", stub_every,
           no_exs ? "cleared" : "set");
    sleep(seconds);
    stop = 1;
    unsigned long exits = 0, skips = 0, mism = 0, other = 0;
    for (int i = 0; i < nvcpu; i++) {
        pthread_join(th[i], NULL);
        exits += res[i].exits, skips += res[i].skips, mism += res[i].mismatches, other += res[i].other;
    }
    if (use_wp) pthread_join(wpt, NULL);
    if (use_irq) pthread_join(irqt, NULL);
    printf("irq line ioctls %lu\n", irq_ops);
    printf("write-protect ioctls %lu\n", wp_ops);
    printf("exits %lu, skipped hvcs %lu, counter mismatches %lu, other exits %lu\n", exits, skips, mism, other);
    return skips || mism;
}
