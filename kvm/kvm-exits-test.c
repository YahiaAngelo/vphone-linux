// Checks the linux-aurora-kvm userspace exits on a bare vCPU, before QEMU is involved.
//
//   cc -O2 -Wall -I uapi/include -o kvm-exits-test kvm-exits-test.c && ./kvm-exits-test
//
// The guest runs at EL1 with its MMU off, so its virtual addresses are its physical ones.
// Exit code 0: every check passed. On a stock kernel it stops at the capability check.
#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define RAM_GPA  0x10000ULL
#define RAM_SIZE 0x10000ULL         // four 16 KiB pages
#define WP_GPA   (RAM_GPA + 0x8000) // the third page
#define HOLE_GPA 0x40000ULL         // no memslot here

#define CORE_REG(x) (KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | (offsetof(struct kvm_regs, x) / sizeof(uint32_t)))

static int failures;

#define CHECK(cond, ...)                                                                                              \
    do {                                                                                                              \
        if (cond) {                                                                                                   \
            printf("  ok   ");                                                                                        \
        } else {                                                                                                      \
            printf("  FAIL ");                                                                                        \
            failures++;                                                                                               \
        }                                                                                                             \
        printf(__VA_ARGS__);                                                                                          \
        printf("\n");                                                                                                 \
    } while (0)

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

static void run(int vcpu)
{
    if (ioctl(vcpu, KVM_RUN, 0) && errno != EINTR) die("KVM_RUN");
}

static int write_protect(int vm, uint64_t gpa, uint64_t size, int enable)
{
    struct kvm_arm_write_protect wp = {.gpa = gpa, .size = size, .flags = enable ? KVM_ARM_WRITE_PROTECT_ENABLE : 0};
    return ioctl(vm, KVM_ARM_SET_WRITE_PROTECT, &wp);
}

int main(void)
{
    static const struct {
        int cap;
        const char *name;
    } caps[] = {
        {KVM_CAP_ARM_HVC_TO_USER, "HVC_TO_USER"},
        {KVM_CAP_ARM_IMPDEF_SYSREG_TO_USER, "IMPDEF_SYSREG_TO_USER"},
        {KVM_CAP_ARM_FAULT_TO_USER, "FAULT_TO_USER"},
        {KVM_CAP_ARM_TIMER_TO_USER, "TIMER_TO_USER"},
        {KVM_CAP_ARM_GIC_SYSREG_TO_USER, "GIC_SYSREG_TO_USER"},
    };
    int kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvm < 0) die("/dev/kvm");
    int vm = ioctl(kvm, KVM_CREATE_VM, 0);
    if (vm < 0) die("KVM_CREATE_VM");

    printf("capabilities\n");
    for (size_t i = 0; i < sizeof(caps) / sizeof(caps[0]); i++) {
        int have = ioctl(vm, KVM_CHECK_EXTENSION, caps[i].cap) > 0;
        CHECK(have, "KVM_CAP_ARM_%s", caps[i].name);
        if (!have) {
            printf("this kernel lacks the vphone KVM patch; boot linux-aurora-kvm\n");
            return 1;
        }
        struct kvm_enable_cap ec = {.cap = caps[i].cap};
        CHECK(ioctl(vm, KVM_ENABLE_CAP, &ec) == 0, "enable %s", caps[i].name);
    }

    long page = sysconf(_SC_PAGESIZE);
    printf("host page size %ld\n", page);
    uint32_t *ram = mmap(NULL, RAM_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (ram == MAP_FAILED) die("mmap");
    struct kvm_userspace_memory_region slot = {
        .slot = 0, .guest_phys_addr = RAM_GPA, .memory_size = RAM_SIZE, .userspace_addr = (uintptr_t)ram};
    if (ioctl(vm, KVM_SET_USER_MEMORY_REGION, &slot)) die("KVM_SET_USER_MEMORY_REGION");

    // The guest program.
    uint32_t code[] = {
        0xD4000002 | (0x1234 << 5), // hvc #0x1234
        0xD53EF141,                 // mrs x1, s3_6_c15_c1_2 (IMPLEMENTATION DEFINED)
        0xF9000062,                 // str x2, [x3]          (x3 = WP_GPA)
        0xF9000062,                 // str x2, [x3]          (again, after unprotecting)
        0xD538CC05,                 // mrs x5, icc_iar1_el1  (the GIC's CPU interface)
        0xD61F0080,                 // br x4                 (x4 = HOLE_GPA)
    };
    memcpy(ram, code, sizeof(code));

    int vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
    if (vcpu < 0) die("KVM_CREATE_VCPU");
    struct kvm_enable_cap late = {.cap = KVM_CAP_ARM_TIMER_TO_USER};
    CHECK(ioctl(vm, KVM_ENABLE_CAP, &late) != 0, "TIMER_TO_USER refused once a vCPU exists");

    struct kvm_vcpu_init init;
    if (ioctl(vm, KVM_ARM_PREFERRED_TARGET, &init)) die("KVM_ARM_PREFERRED_TARGET");
    if (ioctl(vcpu, KVM_ARM_VCPU_INIT, &init)) die("KVM_ARM_VCPU_INIT");
    int run_size = ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0);
    struct kvm_run *r = mmap(NULL, run_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpu, 0);
    if (r == MAP_FAILED) die("mmap kvm_run");

    set_reg(vcpu, CORE_REG(regs.pc), RAM_GPA);
    set_reg(vcpu, CORE_REG(regs.pstate), 0x3C5); // EL1h, DAIF masked
    set_reg(vcpu, CORE_REG(regs.regs[2]), 0x1122334455667788ULL);
    set_reg(vcpu, CORE_REG(regs.regs[3]), WP_GPA);
    set_reg(vcpu, CORE_REG(regs.regs[4]), HOLE_GPA);

    printf("HVC\n");
    run(vcpu);
    CHECK(r->exit_reason == KVM_EXIT_HYPERCALL, "exit reason %u (want %u)", r->exit_reason, KVM_EXIT_HYPERCALL);
    CHECK(r->hypercall.nr == 0x1234, "immediate 0x%llx", (unsigned long long)r->hypercall.nr);
    CHECK(get_reg(vcpu, CORE_REG(regs.pc)) == RAM_GPA + 4, "PC already past the hvc");

    printf("IMPLEMENTATION DEFINED register\n");
    run(vcpu);
    CHECK(r->exit_reason == KVM_EXIT_ARM_SYSREG, "exit reason %u (want %u)", r->exit_reason, KVM_EXIT_ARM_SYSREG);
    uint64_t iss = r->arm_sysreg.esr_iss;
    CHECK((iss & 1) == 1, "a read");
    CHECK(((iss >> 5) & 31) == 1, "Rt = x1");
    CHECK(((iss >> 20) & 3) == 3 && ((iss >> 14) & 7) == 6 && ((iss >> 10) & 15) == 15 && ((iss >> 1) & 15) == 1 &&
              ((iss >> 17) & 7) == 2,
          "S3_6_C15_C1_2 (iss 0x%llx)", (unsigned long long)iss);
    CHECK(get_reg(vcpu, CORE_REG(regs.pc)) == RAM_GPA + 4, "PC left at the mrs");
    // Emulate it the way QEMU does: write Rt, step over.
    set_reg(vcpu, CORE_REG(regs.regs[1]), 0xABCD);
    set_reg(vcpu, CORE_REG(regs.pc), RAM_GPA + 8);

    printf("write-protected store\n");
    CHECK(write_protect(vm, WP_GPA, 0x1000, 1) != 0, "unaligned range refused");
    CHECK(write_protect(vm, WP_GPA, page, 1) == 0, "protect 0x%llx", (unsigned long long)WP_GPA);
    run(vcpu);
    CHECK(r->exit_reason == KVM_EXIT_ARM_FAULT, "exit reason %u (want %u)", r->exit_reason, KVM_EXIT_ARM_FAULT);
    CHECK(r->arm_fault.flags & KVM_EXIT_ARM_FAULT_FLAG_GVA_VALID, "GVA valid");
    CHECK(r->arm_fault.gva == WP_GPA, "gva 0x%llx", (unsigned long long)r->arm_fault.gva);
    CHECK(r->arm_fault.gpa == WP_GPA, "gpa 0x%llx", (unsigned long long)r->arm_fault.gpa);
    CHECK((r->arm_fault.esr >> 26) == 0x24, "data abort (EC 0x%llx)", (unsigned long long)(r->arm_fault.esr >> 26));
    CHECK(ram[0x8000 / 4] == 0, "memory unchanged");
    // Emulate the store, step over it.
    memcpy((char *)ram + 0x8000, &(uint64_t){0x1122334455667788ULL}, 8);
    set_reg(vcpu, CORE_REG(regs.pc), RAM_GPA + 12);

    printf("unprotected store\n");
    memset((char *)ram + 0x8000, 0, 8);
    CHECK(write_protect(vm, WP_GPA, page, 0) == 0, "unprotect");
    run(vcpu); // runs the store, then traps on the GIC register
    CHECK(*(uint64_t *)((char *)ram + 0x8000) == 0x1122334455667788ULL, "the guest's store landed");

    printf("GIC CPU interface register\n");
    CHECK(r->exit_reason == KVM_EXIT_ARM_SYSREG, "exit reason %u (want %u)", r->exit_reason, KVM_EXIT_ARM_SYSREG);
    iss = r->arm_sysreg.esr_iss;
    CHECK((iss & 1) == 1 && ((iss >> 5) & 31) == 5, "a read into x5");
    CHECK(((iss >> 10) & 15) == 12 && ((iss >> 1) & 15) == 12 && ((iss >> 17) & 7) == 0,
          "ICC_IAR1_EL1 (iss 0x%llx)", (unsigned long long)iss);
    CHECK(get_reg(vcpu, CORE_REG(regs.pc)) == RAM_GPA + 16, "PC left at the mrs");
    set_reg(vcpu, CORE_REG(regs.regs[5]), 1023);
    set_reg(vcpu, CORE_REG(regs.pc), RAM_GPA + 20);
    run(vcpu);

    printf("fetch from outside any memslot\n");
    CHECK(r->exit_reason == KVM_EXIT_ARM_FAULT, "exit reason %u (want %u)", r->exit_reason, KVM_EXIT_ARM_FAULT);
    CHECK((r->arm_fault.esr >> 26) == 0x20, "instruction abort (EC 0x%llx)",
          (unsigned long long)(r->arm_fault.esr >> 26));
    CHECK(r->arm_fault.gpa == HOLE_GPA, "gpa 0x%llx", (unsigned long long)r->arm_fault.gpa);

    printf(failures ? "%d check(s) failed\n" : "all checks passed\n", failures);
    return failures != 0;
}
