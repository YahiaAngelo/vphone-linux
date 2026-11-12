// A mini XNU-like guest (hvc-stress2-guest.S) under the vphone KVM caps, run the way vphone-linux's
// QEMU runs iOS, to reproduce a patched `hvc` that doesn't trap to KVM.
//
//   cc -c -march=armv8.3-a hvc-stress2-guest.S -o g.o && objcopy -O binary g.o hvc-stress2-guest.bin
//   cc -O2 -Wall -pthread -I <patched uapi>/include -o hvc-stress2 hvc-stress2.c
//   ./hvc-stress2 [seconds] [vcpus] [af-every] [stub-every] [irq] [wp]
//
// Each EL0 `svc` or fault enters at the patched vector: the host installs the EL1 PAC keys and SCTLR
// (as apple-virt's pac_install), the guest runs a kernel-like entry with the GXF_STATUS check
// (`hvc 0x80ae`, answered with x14 = 0) and returns with `hvc 0x1341`, which the host emulates
// with the EL0 keys. Every `af-every`th return, the data page loses its access flag and the vCPU
// goes through the broadcast TLB flush stub (MMU off); every `stub-every`th through the local one.
// hvc 0x13fc / 0x13ff / 0x13fe report a patched hvc that didn't trap, 0x13fd an unexpected EL1
// exception.
#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define RAM_GPA   0x10000ULL
#define RAM_SIZE  0x40000ULL
#define STUB_GPA  RAM_GPA
#define VBAR_GPA  (RAM_GPA + 0x800)
#define EL0_GPA   (RAM_GPA + 0x4000)
#define L1_GPA    (RAM_GPA + 0x8000)
#define L2_GPA    (RAM_GPA + 0xC000)
#define L3_GPA    (RAM_GPA + 0x10000)
#define DATA_GPA  (RAM_GPA + 0x14000)
#define WP_GPA    (RAM_GPA + 0x18000)
#define KDATA_GPA (RAM_GPA + 0x1C000)    // kernel stacks (1 KiB each) then per-CPU data
#define GL_GPA    (RAM_GPA + 0x20000)    // the mini-SPTM's code
#define GLDATA_GPA (RAM_GPA + 0x24000)   // its stacks and per-CPU data
#define L1G_GPA   (RAM_GPA + 0x28000)    // its page tables (the guarded world's tree)
#define L2G_GPA   (RAM_GPA + 0x2C000)
#define L3G_GPA   (RAM_GPA + 0x30000)

#define CORE_REG(x) (KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | (offsetof(struct kvm_regs, x) / sizeof(uint32_t)))
#define SYS_REG(op0, op1, crn, crm, op2)                                                                              \
    (KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM64_SYSREG | ((uint64_t)(op0) << 14) | ((op1) << 11) |             \
     ((crn) << 7) | ((crm) << 3) | (op2))
#define SCTLR SYS_REG(3, 0, 1, 0, 0)
#define ESR   SYS_REG(3, 0, 5, 2, 0)

// PTE bits
#define AF   (1ULL << 10)
#define NG   (1ULL << 11)
#define PXN  (1ULL << 53)
#define UXN  (1ULL << 54)
#define AP_EL1RW (0ULL << 6)
#define AP_RW    (1ULL << 6)
#define AP_RO    (3ULL << 6)

static int vm, kvm_fd, run_size, seconds = 30, af_every = 3, stub_every = 4, use_irq = 1, use_wp = 1, nvcpus;
static volatile int stop;
static uint64_t *data_pte;
static unsigned long irq_ops, wp_ops, kicks;
static int use_kick = 1;
static long long actlr = -1;   // 8th argument: the guest's ACTLR_EL1 (live in the M1's own register under KVM)
static pthread_t vth[64];

// The key registers in apple-virt's order: APIA, APIB, APDA, APDB, APGA, each lo then hi.
static const uint64_t key_regs[10] = {
    SYS_REG(3, 0, 2, 1, 0), SYS_REG(3, 0, 2, 1, 1), SYS_REG(3, 0, 2, 1, 2), SYS_REG(3, 0, 2, 1, 3),
    SYS_REG(3, 0, 2, 2, 0), SYS_REG(3, 0, 2, 2, 1), SYS_REG(3, 0, 2, 2, 2), SYS_REG(3, 0, 2, 2, 3),
    SYS_REG(3, 0, 2, 3, 0), SYS_REG(3, 0, 2, 3, 1),
};

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

// The registers genter/gexit bank, as apple-virt's gxf_bank_regs.
static const uint64_t bank_regs[7] = {
    CORE_REG(sp_el1), SYS_REG(3, 0, 13, 0, 4), SYS_REG(3, 0, 12, 0, 0), CORE_REG(spsr[KVM_SPSR_EL1]),
    CORE_REG(elr_el1), SYS_REG(3, 0, 5, 2, 0), SYS_REG(3, 0, 6, 0, 0),
};

struct vcpu_state {
    int fd, idx;
    unsigned long genters;
    unsigned long entries, skips_vec, skips_check, skips_eret, bad_el1, af_faults, other;
};

// As apple-virt's pac_install: the keys of EL `el`, and SCTLR with that EL's enables.
static void pac_install(int fd, int el, uint64_t sctlr)
{
    for (int k = 0; k < 10; k++) set_reg(fd, key_regs[k], 0x0123456789ABCDEFULL * (k + 1) ^ (el ? 0 : 0x5A5A5A5A5A5A5A5AULL));
    set_reg(fd, SCTLR, sctlr);
}

static void through_stub(int fd, uint64_t sctlr, uint64_t pc, uint64_t ps, int broadcast, uint64_t *rpc, uint64_t *rps)
{
    *rpc = pc;
    *rps = ps;
    set_reg(fd, SCTLR, sctlr & ~1ULL);
    set_reg(fd, CORE_REG(regs.pstate), 0x3C5);
    set_reg(fd, CORE_REG(regs.pc), STUB_GPA + (broadcast ? 0x18 : 0));
}

static void *vcpu_thread(void *arg)
{
    struct vcpu_state *v = arg;
    int fd = v->fd;
    struct kvm_run *r = mmap(NULL, run_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    uint64_t sctlr, rpc = 0, rps = 0;
    unsigned long rets = 0;

    if (r == MAP_FAILED) die("mmap kvm_run");
    // XNU's SCTLR on Armv8.5 Apple parts: MMU and caches on, PAC enables, EIS/EOS clear.
    // The iOS guest's live SCTLR_EL1 (read under vphone-linux's KVM): MMU, caches, PAC enables, EIS
    // clear, DSSBS, alignment checks, LSMAOE/nTLSMD, UCI, DZE.
    sctlr = 0x1000fc14799dULL;
    set_reg(fd, SYS_REG(3, 0, 10, 2, 0), 0xFF);                                       // MAIR_EL1
    set_reg(fd, SYS_REG(3, 0, 2, 0, 2),                                                // TCR_EL1
            25 | (1ULL << 8) | (1ULL << 10) | (3ULL << 12) | (2ULL << 14) | (1ULL << 23) | (1ULL << 32));
    set_reg(fd, SYS_REG(3, 0, 2, 0, 0), L1_GPA | ((uint64_t)(v->idx + 1) << 48));      // TTBR0_EL1 + ASID
    set_reg(fd, SYS_REG(3, 0, 12, 0, 0), VBAR_GPA);
    set_reg(fd, SYS_REG(3, 0, 13, 0, 4), KDATA_GPA + 0x3000 + v->idx * 64);             // TPIDR_EL1
    set_reg(fd, CORE_REG(sp_el1), KDATA_GPA + (v->idx + 1) * 0x400);
    set_reg(fd, CORE_REG(regs.regs[1]), 0);
    set_reg(fd, CORE_REG(regs.regs[3]), DATA_GPA);
    set_reg(fd, CORE_REG(regs.pc), EL0_GPA);
    set_reg(fd, CORE_REG(regs.pstate), 0x0);
    pac_install(fd, 0, sctlr);
    if (actlr >= 0) {
        uint64_t before = get_reg(fd, SYS_REG(3, 0, 1, 0, 1));

        set_reg(fd, SYS_REG(3, 0, 1, 0, 1), (uint64_t)actlr);
        if (v->idx == 0) {
            printf("  ACTLR_EL1 0x%llx -> wrote 0x%llx, reads 0x%llx\n", (unsigned long long)before,
                   (unsigned long long)actlr, (unsigned long long)get_reg(fd, SYS_REG(3, 0, 1, 0, 1)));
        }
    }
    uint64_t gl_bank[7] = {GLDATA_GPA + (v->idx + 1) * 0x400, GLDATA_GPA + 0x3000 + v->idx * 64, VBAR_GPA, 0, 0, 0, 0};
    uint64_t el_bank[7];
    uint64_t ttbr_el = L1_GPA | ((uint64_t)(v->idx + 1) << 48), ttbr_gl = L1G_GPA | ((uint64_t)(v->idx + 1) << 48);

    while (!stop) {
        if (ioctl(fd, KVM_RUN, 0) && errno != EINTR) die("KVM_RUN");
        if (r->exit_reason != KVM_EXIT_HYPERCALL) {
            v->other++;
            continue;
        }
        switch (r->hypercall.nr) {
        case 0x1340: {      // an entry from EL0: kernel keys, step over the 0x13fc behind it
            uint64_t ec = get_reg(fd, ESR) >> 26;

            v->entries++;
            if (ec == 0x24 && data_pte) {
                __atomic_or_fetch(data_pte, AF, __ATOMIC_SEQ_CST);     // the kernel would set it via SPTM
                v->af_faults++;
            }
            pac_install(fd, 1, sctlr);
            set_reg(fd, CORE_REG(regs.pc), get_reg(fd, CORE_REG(regs.pc)) + 4);
            break;
        }
        case 0x80ae:        // GXF_STATUS: unguarded
            set_reg(fd, CORE_REG(regs.regs[14]), 0);
            break;
        case 0x1341: {      // eret to EL0, maybe through a TLB flush first
            uint64_t ps = get_reg(fd, CORE_REG(spsr[KVM_SPSR_EL1])), pc = get_reg(fd, CORE_REG(elr_el1));

            pac_install(fd, 0, sctlr);
            rets++;
            if (af_every && rets % af_every == 0) {
                __atomic_and_fetch(data_pte, ~AF, __ATOMIC_SEQ_CST);  // as madvise, then a broadcast flush
                through_stub(fd, sctlr, pc, ps, 1, &rpc, &rps);
            } else if (stub_every && rets % stub_every == 0) {
                through_stub(fd, sctlr, pc, ps, 0, &rpc, &rps);
            } else {
                set_reg(fd, CORE_REG(regs.pstate), ps);
                set_reg(fd, CORE_REG(regs.pc), pc);
            }
            break;
        }
        case 0x1420: {      // genter, as gxf_genter_fast: kernel bank out, SPTM's in, its tree, flush
            uint64_t cpsr = get_reg(fd, CORE_REG(regs.pstate)), pc = get_reg(fd, CORE_REG(regs.pc));

            v->genters++;
            gl_bank[3] = cpsr;          // SPSR_GL: where gexit returns
            gl_bank[4] = pc;            // ELR_GL
            for (int i = 0; i < 7; i++) {
                el_bank[i] = get_reg(fd, bank_regs[i]);
                set_reg(fd, bank_regs[i], gl_bank[i]);
            }
            set_reg(fd, SYS_REG(3, 0, 2, 0, 0), ttbr_gl);
            through_stub(fd, sctlr, GL_GPA, 0x3C5, 0, &rpc, &rps);
            break;
        }
        case 0x1400: {      // gexit, as gxf_gexit_fast: SPTM's bank out, the kernel's in, back via the stub
            for (int i = 0; i < 7; i++) {
                gl_bank[i] = get_reg(fd, bank_regs[i]);
                set_reg(fd, bank_regs[i], el_bank[i]);
            }
            set_reg(fd, SYS_REG(3, 0, 2, 0, 0), ttbr_el);
            through_stub(fd, sctlr, gl_bank[4], gl_bank[3], 0, &rpc, &rps);
            break;
        }
        case 0x8aa8:        // TPIDR_GL into x8: SPTM's own, live while guarded
            set_reg(fd, CORE_REG(regs.regs[8]), get_reg(fd, SYS_REG(3, 0, 13, 0, 4)));
            break;
        case 0x1300:        // back from the stub: MMU on, where it was going
            set_reg(fd, SCTLR, sctlr);
            set_reg(fd, CORE_REG(regs.pstate), rps);
            set_reg(fd, CORE_REG(regs.pc), rpc);
            break;
        case 0x13fc:
            if (v->skips_vec++ < 3) printf("  vcpu %d: vector hvc 0x1340 skipped (ESR 0x%llx)\n", v->idx,
                                           (unsigned long long)get_reg(fd, ESR));
            pac_install(fd, 1, sctlr);
            break;
        case 0x13ff:
            if (v->skips_check++ < 3) printf("  vcpu %d: check hvc 0x80ae skipped\n", v->idx);
            break;
        case 0x13fe:
            if (v->skips_eret++ < 3) printf("  vcpu %d: eret hvc 0x1341 skipped\n", v->idx);
            pac_install(fd, 0, sctlr);
            set_reg(fd, CORE_REG(regs.pstate), get_reg(fd, CORE_REG(spsr[KVM_SPSR_EL1])));
            set_reg(fd, CORE_REG(regs.pc), get_reg(fd, CORE_REG(elr_el1)));
            break;
        case 0x13fd:
            if (v->bad_el1++ < 3) {
                printf("  vcpu %d: EL1 exception: ESR 0x%llx ELR 0x%llx FAR 0x%llx\n", v->idx,
                       (unsigned long long)get_reg(fd, ESR), (unsigned long long)get_reg(fd, CORE_REG(elr_el1)),
                       (unsigned long long)get_reg(fd, SYS_REG(3, 0, 6, 0, 0)));
            }
            return NULL;
        default:
            v->other++;
        }
    }
    return NULL;
}

static void *irq_thread(void *arg)
{
    (void)arg;
    while (!stop) {
        for (int v = 0; v < nvcpus; v++) {
            for (int line = 0; line <= 1; line++) {
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

// As QEMU's SIG_IPI: interrupts a vCPU thread's KVM_RUN (EINTR), the way cross-thread work and
// exit requests kick vCPUs.
static void on_kick(int sig)
{
    (void)sig;
}

static void *kick_thread(void *arg)
{
    (void)arg;
    while (!stop) {
        for (int v = 0; v < nvcpus; v++) {
            pthread_kill(vth[v], SIGUSR1);
            kicks++;
        }
        usleep(50);
    }
    return NULL;
}

static void *wp_thread(void *arg)
{
    long page = sysconf(_SC_PAGESIZE);

    (void)arg;
    while (!stop) {
        for (int on = 1; on >= 0; on--) {
            struct kvm_arm_write_protect wp = {.gpa = WP_GPA, .size = page, .flags = on ? KVM_ARM_WRITE_PROTECT_ENABLE : 0};
            if (ioctl(vm, KVM_ARM_SET_WRITE_PROTECT, &wp)) die("KVM_ARM_SET_WRITE_PROTECT");
            wp_ops++;
        }
    }
    return NULL;
}

int main(int argc, char **argv)
{
    nvcpus = (int)sysconf(_SC_NPROCESSORS_ONLN) - 1;
    if (argc > 1) seconds = atoi(argv[1]);
    if (argc > 2) nvcpus = atoi(argv[2]);
    if (argc > 3) af_every = atoi(argv[3]);
    if (argc > 4) stub_every = atoi(argv[4]);
    if (argc > 5) use_irq = atoi(argv[5]);
    if (argc > 6) use_wp = atoi(argv[6]);
    if (argc > 7) use_kick = atoi(argv[7]);
    if (argc > 8) actlr = strtoll(argv[8], NULL, 0);
    struct sigaction sa = {.sa_handler = on_kick};   // no SA_RESTART: KVM_RUN returns EINTR
    sigaction(SIGUSR1, &sa, NULL);

    kvm_fd = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm_fd < 0) die("/dev/kvm");
    vm = ioctl(kvm_fd, KVM_CREATE_VM, 0);
    if (vm < 0) die("KVM_CREATE_VM");
    int caps[] = {KVM_CAP_ARM_HVC_TO_USER, KVM_CAP_ARM_FAULT_TO_USER};
    for (int i = 0; i < 2; i++) {
        struct kvm_enable_cap ec = {.cap = caps[i]};
        if (ioctl(vm, KVM_ENABLE_CAP, &ec)) die("KVM_ENABLE_CAP (boot linux-aurora-kvm)");
    }

    uint8_t *ram = mmap(NULL, RAM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ram == MAP_FAILED) die("mmap");
    FILE *f = fopen("hvc-stress2-guest.bin", "rb");
    if (!f) die("hvc-stress2-guest.bin");
    size_t n = fread(ram, 1, RAM_SIZE, f);
    fclose(f);
    if (n < 0x20020) {
        fprintf(stderr, "guest image too short (%zu)\n", n);
        return 2;
    }

    // Identity page tables, 16 KiB granule: L1[0] -> L2, L2[0] -> L3 over the RAM's pages.
    uint64_t *l1 = (uint64_t *)(ram + (L1_GPA - RAM_GPA)), *l2 = (uint64_t *)(ram + (L2_GPA - RAM_GPA));
    uint64_t *l3 = (uint64_t *)(ram + (L3_GPA - RAM_GPA));
    uint64_t *l1g = (uint64_t *)(ram + (L1G_GPA - RAM_GPA)), *l2g = (uint64_t *)(ram + (L2G_GPA - RAM_GPA));
    uint64_t *l3g = (uint64_t *)(ram + (L3G_GPA - RAM_GPA));
    l1[0] = L2_GPA | 3;
    l2[0] = L3_GPA | 3;
    l1g[0] = L2G_GPA | 3;
    l2g[0] = L3G_GPA | 3;
    for (uint64_t pa = RAM_GPA; pa < RAM_GPA + RAM_SIZE; pa += 0x4000) {
        uint64_t d = pa | AF | (3ULL << 8) | 3, g;

        if (pa == STUB_GPA) d |= AP_EL1RW | UXN;                  // kernel text (and vectors)
        else if (pa == EL0_GPA) d |= AP_RO | PXN | NG;            // user text
        else if (pa == DATA_GPA) d |= AP_RW | PXN | UXN | NG;     // user data
        else if (pa == GL_GPA) d |= AP_RO | PXN | UXN;            // SPTM's text: not the kernel's to run
        else d |= AP_EL1RW | PXN | UXN;                           // kernel data, tables
        // The guarded world's tree: SPTM's text executable, the kernel's (but the vectors) not.
        g = d;
        if (pa == GL_GPA) g = pa | AF | (3ULL << 8) | 3 | AP_RO | UXN;
        l3[pa >> 14] = d;
        l3g[pa >> 14] = g;
    }
    data_pte = &l3[DATA_GPA >> 14];
    __builtin___clear_cache((char *)ram, (char *)ram + RAM_SIZE);

    struct kvm_userspace_memory_region slot = {
        .slot = 0, .guest_phys_addr = RAM_GPA, .memory_size = RAM_SIZE, .userspace_addr = (uintptr_t)ram};
    if (ioctl(vm, KVM_SET_USER_MEMORY_REGION, &slot)) die("KVM_SET_USER_MEMORY_REGION");
    run_size = ioctl(kvm_fd, KVM_GET_VCPU_MMAP_SIZE, 0);

    struct kvm_vcpu_init init;
    if (ioctl(vm, KVM_ARM_PREFERRED_TARGET, &init)) die("KVM_ARM_PREFERRED_TARGET");
    init.features[0] |= (1 << KVM_ARM_VCPU_PTRAUTH_ADDRESS) | (1 << KVM_ARM_VCPU_PTRAUTH_GENERIC);
    pthread_t th[64], it, wt;
    struct vcpu_state st[64];
    memset(st, 0, sizeof(st));
    for (int i = 0; i < nvcpus; i++) {
        st[i].idx = i;
        st[i].fd = ioctl(vm, KVM_CREATE_VCPU, i);
        if (st[i].fd < 0) die("KVM_CREATE_VCPU");
        if (ioctl(st[i].fd, KVM_ARM_VCPU_INIT, &init)) die("KVM_ARM_VCPU_INIT (pointer authentication)");
    }
    for (int i = 0; i < nvcpus; i++) pthread_create(&th[i], NULL, vcpu_thread, &st[i]);
    for (int i = 0; i < nvcpus; i++) vth[i] = th[i];
    pthread_t kt;
    if (use_kick) pthread_create(&kt, NULL, kick_thread, NULL);
    if (use_irq) pthread_create(&it, NULL, irq_thread, NULL);
    if (use_wp) pthread_create(&wt, NULL, wp_thread, NULL);
    printf("%d vCPUs, %d s: AF clear every %d returns, local stub every %d, irq churn %d, write-protect churn %d\n",
           nvcpus, seconds, af_every, stub_every, use_irq, use_wp);
    sleep(seconds);
    stop = 1;
    for (int i = 0; i < nvcpus; i++) pthread_join(th[i], NULL);
    if (use_irq) pthread_join(it, NULL);
    if (use_wp) pthread_join(wt, NULL);
    if (use_kick) pthread_join(kt, NULL);
    printf("vCPU kicks %lu\n", kicks);

    unsigned long e = 0, sv = 0, sc = 0, se = 0, b = 0, af = 0, o = 0;
    for (int i = 0; i < nvcpus; i++) {
        e += st[i].entries, sv += st[i].skips_vec, sc += st[i].skips_check, se += st[i].skips_eret;
        b += st[i].bad_el1, af += st[i].af_faults, o += st[i].other;
    }
    unsigned long g = 0;
    for (int i = 0; i < nvcpus; i++) g += st[i].genters;
    printf("genter/gexit round trips %lu\n", g);
    printf("entries %lu (AF faults %lu), irq ioctls %lu, wp ioctls %lu, other exits %lu\n", e, af, irq_ops, wp_ops, o);
    printf("SKIPPED: vector %lu, check %lu, eret %lu; unexpected EL1 exceptions %lu\n", sv, sc, se, b);
    return sv || sc || se || b;
}
