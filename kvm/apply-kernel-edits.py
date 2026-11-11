#!/usr/bin/env python3
"""Applies the vphone/Inferno KVM userspace-exit changes to a linux-aurora tree.

Each edit replaces an anchor that must occur exactly once."""
import sys, pathlib

root = pathlib.Path(sys.argv[1])

def edit(path, old, new):
    p = root / path
    s = p.read_text()
    n = s.count(old)
    if n != 1:
        sys.exit(f"{path}: anchor found {n} times:\n{old}")
    p.write_text(s.replace(old, new))

# ---- uapi: linux/kvm.h (matches Inferno's linux-headers/linux/kvm.h) ----
edit("include/uapi/linux/kvm.h",
"#define KVM_EXIT_SNP_REQ_CERTS    43\n",
"#define KVM_EXIT_SNP_REQ_CERTS    43\n"
"#define KVM_EXIT_ARM_SYSREG       44\n"
"#define KVM_EXIT_ARM_FAULT        45\n")

edit("include/uapi/linux/kvm.h",
"""		} arm_sea;
""",
"""		} arm_sea;
		/* KVM_EXIT_ARM_SYSREG */
		struct {
			__u64 esr_iss;
		} arm_sysreg;
		/* KVM_EXIT_ARM_FAULT */
		struct {
#define KVM_EXIT_ARM_FAULT_FLAG_GVA_VALID	(1ULL << 0)
			__u64 flags;
			__u64 esr;
			__u64 gva;
			__u64 gpa;
		} arm_fault;
""")

edit("include/uapi/linux/kvm.h",
"#define KVM_CAP_S390_HPAGE_2G 249\n",
"#define KVM_CAP_S390_HPAGE_2G 249\n"
"#define KVM_CAP_ARM_HVC_TO_USER 253\n"
"#define KVM_CAP_ARM_IMPDEF_SYSREG_TO_USER 254\n"
"#define KVM_CAP_ARM_FAULT_TO_USER 255\n"
"#define KVM_CAP_ARM_TIMER_TO_USER 256\n")

edit("include/uapi/linux/kvm.h",
"#define KVM_ARM_GET_REG_WRITABLE_MASKS _IOR(KVMIO,  0xb6, struct reg_mask_range)\n",
"#define KVM_ARM_GET_REG_WRITABLE_MASKS _IOR(KVMIO,  0xb6, struct reg_mask_range)\n"
"/* Available with KVM_CAP_ARM_FAULT_TO_USER */\n"
"#define KVM_ARM_SET_WRITE_PROTECT _IOW(KVMIO,  0xd6, struct kvm_arm_write_protect)\n")

# ---- uapi: asm/kvm.h ----
edit("arch/arm64/include/uapi/asm/kvm.h",
"""struct kvm_arm_counter_offset {
	__u64 counter_offset;
	__u64 reserved;
};
""",
"""struct kvm_arm_counter_offset {
	__u64 counter_offset;
	__u64 reserved;
};

/*
 * Guest physical range to write-protect, or to stop write-protecting.
 * To be used with KVM_ARM_SET_WRITE_PROTECT.
 */
#define KVM_ARM_WRITE_PROTECT_ENABLE	(1U << 0)

struct kvm_arm_write_protect {
	__u64 gpa;
	__u64 size;
	__u32 flags;
	__u32 reserved[3];
};
""")

# ---- kvm_host.h: VM flags, write-protect state, helpers ----
edit("arch/arm64/include/asm/kvm_host.h",
"""#define KVM_ARCH_FLAG_EXIT_SEA				11
""",
"""#define KVM_ARCH_FLAG_EXIT_SEA				11
	/* HVCs exit to userspace with their immediate (KVM_CAP_ARM_HVC_TO_USER) */
#define KVM_ARCH_FLAG_HVC_TO_USER			12
	/* IMPDEF register accesses exit to userspace */
#define KVM_ARCH_FLAG_IMPDEF_SYSREG_TO_USER		13
	/* Unbacked fetches and write-protected stores exit to userspace */
#define KVM_ARCH_FLAG_FAULT_TO_USER			14
	/* Timer outputs go to userspace even with an in-kernel irqchip */
#define KVM_ARCH_FLAG_TIMER_TO_USER			15
""")

edit("arch/arm64/include/asm/kvm_host.h",
"""struct kvm_arch {
	struct kvm_s2_mmu mmu;
""",
"""struct kvm_arch {
	struct kvm_s2_mmu mmu;

	/*
	 * Guest pages userspace write-protected with KVM_ARM_SET_WRITE_PROTECT,
	 * by gfn. Once any has been, stage 2 maps the VM page by page.
	 */
	struct xarray wp_gfns;
	bool has_wp;
""")

edit("arch/arm64/include/asm/kvm_host.h",
"""#define kvm_has_mte(kvm)""",
"""/* Timer outputs reach userspace through kvm_run's device_irq_level. */
#define kvm_arm_timer_to_user(kvm)					\\
	(!irqchip_in_kernel(kvm) ||					\\
	 test_bit(KVM_ARCH_FLAG_TIMER_TO_USER, &(kvm)->arch.flags))

#define kvm_has_mte(kvm)""")

# ---- arm.c: caps, ioctl, VM lifetime, run loop ----
edit("arch/arm64/kvm/arm.c",
"""	case KVM_CAP_ARM_SEA_TO_USER:
		r = 0;
		set_bit(KVM_ARCH_FLAG_EXIT_SEA, &kvm->arch.flags);
		break;
""",
"""	case KVM_CAP_ARM_SEA_TO_USER:
		r = 0;
		set_bit(KVM_ARCH_FLAG_EXIT_SEA, &kvm->arch.flags);
		break;
	case KVM_CAP_ARM_HVC_TO_USER:
		r = 0;
		set_bit(KVM_ARCH_FLAG_HVC_TO_USER, &kvm->arch.flags);
		break;
	case KVM_CAP_ARM_IMPDEF_SYSREG_TO_USER:
		r = 0;
		set_bit(KVM_ARCH_FLAG_IMPDEF_SYSREG_TO_USER, &kvm->arch.flags);
		break;
	case KVM_CAP_ARM_FAULT_TO_USER:
		r = 0;
		set_bit(KVM_ARCH_FLAG_FAULT_TO_USER, &kvm->arch.flags);
		break;
	case KVM_CAP_ARM_TIMER_TO_USER:
		/* The timers are wired to the vGIC when the first vCPU runs. */
		mutex_lock(&kvm->lock);
		if (!kvm->created_vcpus) {
			r = 0;
			set_bit(KVM_ARCH_FLAG_TIMER_TO_USER, &kvm->arch.flags);
		}
		mutex_unlock(&kvm->lock);
		break;
""")

edit("arch/arm64/kvm/arm.c",
"""	case KVM_CAP_ARM_SEA_TO_USER:
		r = 1;""" if False else """	case KVM_CAP_VCPU_EVENTS:
	case KVM_CAP_ARM_IRQ_LINE_LAYOUT_2:
	case KVM_CAP_ARM_NISV_TO_USER:
""",
"""	case KVM_CAP_VCPU_EVENTS:
	case KVM_CAP_ARM_IRQ_LINE_LAYOUT_2:
	case KVM_CAP_ARM_NISV_TO_USER:
	case KVM_CAP_ARM_HVC_TO_USER:
	case KVM_CAP_ARM_IMPDEF_SYSREG_TO_USER:
	case KVM_CAP_ARM_FAULT_TO_USER:
	case KVM_CAP_ARM_TIMER_TO_USER:
""")

edit("arch/arm64/kvm/arm.c",
"""	mutex_init(&kvm->arch.config_lock);
""",
"""	mutex_init(&kvm->arch.config_lock);
	xa_init(&kvm->arch.wp_gfns);
""")

edit("arch/arm64/kvm/arm.c",
"""	kvm_uninit_stage2_mmu(kvm);
	kvm_destroy_mpidr_data(kvm);
""",
"""	kvm_uninit_stage2_mmu(kvm);
	xa_destroy(&kvm->arch.wp_gfns);
	kvm_destroy_mpidr_data(kvm);
""")

edit("arch/arm64/kvm/arm.c",
"""	irq_lines |= (!irqchip_in_kernel(v->kvm) &&
		      (kvm_timer_should_notify_user(v) ||
		       kvm_pmu_should_notify_user(v)));""",
"""	irq_lines |= (kvm_arm_timer_to_user(v->kvm) &&
		      (kvm_timer_should_notify_user(v) ||
		       kvm_pmu_should_notify_user(v)));""")

edit("arch/arm64/kvm/arm.c",
"""	if (unlikely(!irqchip_in_kernel(vcpu->kvm))) {
		if (unlikely(kvm_irq_update_run(vcpu))) {""",
"""	if (unlikely(kvm_arm_timer_to_user(vcpu->kvm))) {
		if (unlikely(kvm_irq_update_run(vcpu))) {""")

edit("arch/arm64/kvm/arm.c",
"""			if (unlikely(!irqchip_in_kernel(vcpu->kvm)))
				kvm_timer_sync_user(vcpu);
			kvm_vgic_sync_hwstate(vcpu);""",
"""			if (unlikely(kvm_arm_timer_to_user(vcpu->kvm)))
				kvm_timer_sync_user(vcpu);
			kvm_vgic_sync_hwstate(vcpu);""")

edit("arch/arm64/kvm/arm.c",
"""		if (unlikely(!irqchip_in_kernel(vcpu->kvm)))
			kvm_timer_sync_user(vcpu);

		if (is_hyp_ctxt(vcpu))""",
"""		if (unlikely(kvm_arm_timer_to_user(vcpu->kvm)))
			kvm_timer_sync_user(vcpu);

		if (is_hyp_ctxt(vcpu))""")

edit("arch/arm64/kvm/arm.c",
"""	if (unlikely(!irqchip_in_kernel(vcpu->kvm)))
		kvm_irq_update_run(vcpu);

	kvm_sigset_deactivate(vcpu);""",
"""	if (unlikely(kvm_arm_timer_to_user(vcpu->kvm)))
		kvm_irq_update_run(vcpu);

	kvm_sigset_deactivate(vcpu);""")

edit("arch/arm64/kvm/arm.c",
"""	case KVM_ARM_SET_COUNTER_OFFSET: {""",
"""	case KVM_ARM_SET_WRITE_PROTECT: {
		struct kvm_arm_write_protect wp;

		if (copy_from_user(&wp, argp, sizeof(wp)))
			return -EFAULT;
		return kvm_arm_set_write_protect(kvm, &wp);
	}
	case KVM_ARM_SET_COUNTER_OFFSET: {""")

# ---- arch_timer.c: the timers bypass the vGIC when they go to userspace ----
edit("arch/arm64/kvm/arch_timer.c",
"""static inline bool userspace_irqchip(struct kvm *kvm)
{
	return unlikely(!irqchip_in_kernel(kvm));
}""",
"""static inline bool userspace_irqchip(struct kvm *kvm)
{
	return unlikely(kvm_arm_timer_to_user(kvm));
}""")

edit("arch/arm64/kvm/arch_timer.c",
"""	if (irqchip_in_kernel(vcpu->kvm))
		phys_active = kvm_vgic_map_is_active(vcpu, timer_irq(ctx));""",
"""	if (!userspace_irqchip(vcpu->kvm))
		phys_active = kvm_vgic_map_is_active(vcpu, timer_irq(ctx));""")

edit("arch/arm64/kvm/arch_timer.c",
"""	if (unlikely(!irqchip_in_kernel(vcpu->kvm)))
		unmask_vtimer_irq_user(vcpu);""",
"""	if (userspace_irqchip(vcpu->kvm))
		unmask_vtimer_irq_user(vcpu);""")

edit("arch/arm64/kvm/arch_timer.c",
"""		if (irqchip_in_kernel(vcpu->kvm)) {
			kvm_vgic_reset_mapped_irq(vcpu, timer_irq(map.direct_vtimer));""",
"""		if (!userspace_irqchip(vcpu->kvm)) {
			kvm_vgic_reset_mapped_irq(vcpu, timer_irq(map.direct_vtimer));""")

edit("arch/arm64/kvm/arch_timer.c",
"""	/* Without a VGIC we do not map virtual IRQs to physical IRQs */
	if (!irqchip_in_kernel(vcpu->kvm))
		goto no_vgic;""",
"""	/* Without a VGIC we do not map virtual IRQs to physical IRQs */
	if (userspace_irqchip(vcpu->kvm))
		goto no_vgic;""")

# ---- handle_exit.c: HVCs to userspace ----
edit("arch/arm64/kvm/handle_exit.c",
"""	vcpu->stat.hvc_exit_stat++;

	/* Forward hvc instructions to the virtual EL2 if the guest has EL2. */""",
"""	vcpu->stat.hvc_exit_stat++;

	/*
	 * Userspace emulates every HVC, by its immediate. The PC is already
	 * past the HVC, as for any exception it raises.
	 */
	if (test_bit(KVM_ARCH_FLAG_HVC_TO_USER, &vcpu->kvm->arch.flags)) {
		vcpu->run->exit_reason = KVM_EXIT_HYPERCALL;
		vcpu->run->hypercall = (typeof(vcpu->run->hypercall)) {
			.nr = kvm_vcpu_hvc_get_imm(vcpu),
		};
		return 0;
	}

	/* Forward hvc instructions to the virtual EL2 if the guest has EL2. */""")

# ---- sys_regs.c: IMPDEF registers to userspace ----
edit("arch/arm64/kvm/sys_regs.c",
"""	trace_kvm_handle_sys_reg(esr);

	if (triage_sysreg_trap(vcpu, &sr_idx))
		return 1;
""",
"""	trace_kvm_handle_sys_reg(esr);

	/*
	 * The reserved IMPLEMENTATION DEFINED encodings (Op0 3, CRn 11 or 15,
	 * DDI0487 D18.3.2) go to userspace, which emulates the access and
	 * moves the PC past it.
	 */
	if (test_bit(KVM_ARCH_FLAG_IMPDEF_SYSREG_TO_USER, &vcpu->kvm->arch.flags)) {
		params = esr_sys64_to_params(esr);
		if (params.Op0 == 3 && (params.CRn & 0b1011) == 0b1011) {
			vcpu->run->exit_reason = KVM_EXIT_ARM_SYSREG;
			vcpu->run->arm_sysreg.esr_iss = esr & ESR_ELx_ISS_MASK;
			return 0;
		}
	}

	if (triage_sysreg_trap(vcpu, &sr_idx))
		return 1;
""")

# ---- mmu.c: fault exits and write protection ----
edit("arch/arm64/include/asm/kvm_mmu.h",
"""void kvm_stage2_unmap_range(""",
"""int kvm_arm_set_write_protect(struct kvm *kvm, struct kvm_arm_write_protect *wp);
void kvm_stage2_unmap_range(""")

edit("arch/arm64/kvm/mmu.c",
"""static short kvm_s2_resolve_vma_size(const struct kvm_s2_fault_desc *s2fd,
				     struct kvm_s2_fault_vma_info *s2vi,
				     struct vm_area_struct *vma)
{
	short vma_shift;

	if (memslot_is_logging(s2fd->memslot)) {""",
"""static bool kvm_arm_gfn_is_wp(struct kvm *kvm, gfn_t gfn)
{
	return READ_ONCE(kvm->arch.has_wp) && xa_load(&kvm->arch.wp_gfns, gfn);
}

static short kvm_s2_resolve_vma_size(const struct kvm_s2_fault_desc *s2fd,
				     struct kvm_s2_fault_vma_info *s2vi,
				     struct vm_area_struct *vma)
{
	short vma_shift;

	/* Write protection is per page, so no block may span a protected one. */
	if (memslot_is_logging(s2fd->memslot) ||
	    READ_ONCE(s2fd->vcpu->kvm->arch.has_wp)) {""")

edit("arch/arm64/kvm/mmu.c",
"""	perm_fault_granule = (kvm_s2_fault_is_perm(s2fd) ?
			      kvm_vcpu_trap_get_perm_fault_granule(s2fd->vcpu) : 0);
	mapping_size = s2vi->vma_pagesize;
	pfn = s2vi->pfn;
	gfn = s2vi->gfn;
""",
"""	perm_fault_granule = (kvm_s2_fault_is_perm(s2fd) ?
			      kvm_vcpu_trap_get_perm_fault_granule(s2fd->vcpu) : 0);
	mapping_size = s2vi->vma_pagesize;
	pfn = s2vi->pfn;
	gfn = s2vi->gfn;

	/* Checked under mmu_lock, which KVM_ARM_SET_WRITE_PROTECT takes. */
	if (kvm_arm_gfn_is_wp(kvm, gfn)) {
		prot &= ~KVM_PGTABLE_PROT_W;
		writable = false;
	}
""")

edit("arch/arm64/kvm/mmu.c",
"""	gfn = ipa >> PAGE_SHIFT;
	memslot = gfn_to_memslot(vcpu->kvm, gfn);
	hva = gfn_to_hva_memslot_prot(memslot, gfn, &writable);
	write_fault = kvm_is_write_fault(vcpu);
	if (kvm_is_error_hva(hva) || (write_fault && !writable)) {""",
"""	gfn = ipa >> PAGE_SHIFT;
	memslot = gfn_to_memslot(vcpu->kvm, gfn);
	hva = gfn_to_hva_memslot_prot(memslot, gfn, &writable);
	write_fault = kvm_is_write_fault(vcpu);

	/*
	 * Userspace handles a fetch from outside any memslot (it may map
	 * something there and retry) and a store to a page it write-protected.
	 */
	if (test_bit(KVM_ARCH_FLAG_FAULT_TO_USER, &vcpu->kvm->arch.flags) &&
	    ((is_iabt && kvm_is_error_hva(hva)) ||
	     (!is_iabt && write_fault && !kvm_vcpu_abt_iss1tw(vcpu) &&
	      !kvm_is_error_hva(hva) && kvm_arm_gfn_is_wp(vcpu->kvm, gfn)))) {
		u64 far = kvm_vcpu_get_hfar(vcpu);
		struct kvm_run *run = vcpu->run;

		run->exit_reason = KVM_EXIT_ARM_FAULT;
		run->arm_fault.flags = (esr & ESR_ELx_FnV) ?
			0 : KVM_EXIT_ARM_FAULT_FLAG_GVA_VALID;
		run->arm_fault.esr = esr;
		run->arm_fault.gva = far;
		run->arm_fault.gpa = ipa | FAR_TO_FIPA_OFFSET(far);
		ret = 0;
		goto out_unlock;
	}

	if (kvm_is_error_hva(hva) || (write_fault && !writable)) {""")

edit("arch/arm64/kvm/mmu.c",
"""bool kvm_unmap_gfn_range(struct kvm *kvm, struct kvm_gfn_range *range)
{""",
"""/*
 * KVM_ARM_SET_WRITE_PROTECT: guest stores to [gpa, gpa + size) fault to
 * userspace (KVM_EXIT_ARM_FAULT) while the range is protected. Protecting
 * unmaps the range, so it faults back in read-only and page by page.
 */
int kvm_arm_set_write_protect(struct kvm *kvm, struct kvm_arm_write_protect *wp)
{
	bool enable = wp->flags & KVM_ARM_WRITE_PROTECT_ENABLE;
	gfn_t gfn, start, end;
	int ret = 0;

	if (!test_bit(KVM_ARCH_FLAG_FAULT_TO_USER, &kvm->arch.flags))
		return -EINVAL;
	if ((wp->flags & ~KVM_ARM_WRITE_PROTECT_ENABLE) ||
	    wp->reserved[0] || wp->reserved[1] || wp->reserved[2])
		return -EINVAL;
	if (!wp->size || !PAGE_ALIGNED(wp->gpa) || !PAGE_ALIGNED(wp->size) ||
	    wp->gpa + wp->size < wp->gpa ||
	    wp->gpa + wp->size > kvm_phys_size(&kvm->arch.mmu))
		return -EINVAL;

	start = gpa_to_gfn(wp->gpa);
	end = gpa_to_gfn(wp->gpa + wp->size);

	if (!enable) {
		/* A store relaxes the read-only mapping on its own. */
		for (gfn = start; gfn < end; gfn++)
			xa_erase(&kvm->arch.wp_gfns, gfn);
		return 0;
	}

	/*
	 * Mark the pages before unmapping them under mmu_lock: a fault that
	 * maps after the unmap sees the mark, and one already past its checks
	 * retries on the invalidation.
	 */
	WRITE_ONCE(kvm->arch.has_wp, true);
	for (gfn = start; gfn < end; gfn++) {
		ret = xa_err(xa_store(&kvm->arch.wp_gfns, gfn, xa_mk_value(1),
				      GFP_KERNEL_ACCOUNT));
		if (ret)
			break;
		cond_resched();
	}

	write_lock(&kvm->mmu_lock);
	kvm_mmu_invalidate_start(kvm);
	kvm_mmu_invalidate_range_add(kvm, start, end);
	kvm_stage2_unmap_range(&kvm->arch.mmu, wp->gpa, wp->size, true);
	kvm_mmu_invalidate_end(kvm);
	write_unlock(&kvm->mmu_lock);

	return ret;
}

bool kvm_unmap_gfn_range(struct kvm *kvm, struct kvm_gfn_range *range)
{""")


# ---- vphone extension: GICv3 CPU interface to userspace (no in-kernel irqchip) ----
# vresearch101 has two GICv3s (the AP's and the SEP's private one) at the same
# address, which one in-kernel vGIC can't model, so QEMU emulates both and needs
# the guest's ICC_* accesses. Without an in-kernel irqchip KVM already traps them
# all (ICH_HCR_EL2.TALL0/TALL1/TC) and reports ICC_SRE_EL1.SRE as 1.
edit("include/uapi/linux/kvm.h",
"#define KVM_CAP_ARM_TIMER_TO_USER 256\n",
"#define KVM_CAP_ARM_TIMER_TO_USER 256\n"
"#define KVM_CAP_ARM_GIC_SYSREG_TO_USER 257\n")

edit("arch/arm64/include/asm/kvm_host.h",
"""#define KVM_ARCH_FLAG_TIMER_TO_USER			15
""",
"""#define KVM_ARCH_FLAG_TIMER_TO_USER			15
	/* GICv3 CPU interface accesses exit to userspace (no in-kernel irqchip) */
#define KVM_ARCH_FLAG_GIC_SYSREG_TO_USER		16
""")

edit("arch/arm64/kvm/arm.c",
"""	case KVM_CAP_ARM_TIMER_TO_USER:
		/* The timers are wired to the vGIC when the first vCPU runs. */""",
"""	case KVM_CAP_ARM_GIC_SYSREG_TO_USER:
		/* Userspace emulates the GIC, so there must be no vGIC. */
		mutex_lock(&kvm->lock);
		if (!kvm->created_vcpus && !irqchip_in_kernel(kvm)) {
			r = 0;
			set_bit(KVM_ARCH_FLAG_GIC_SYSREG_TO_USER, &kvm->arch.flags);
		}
		mutex_unlock(&kvm->lock);
		break;
	case KVM_CAP_ARM_TIMER_TO_USER:
		/* The timers are wired to the vGIC when the first vCPU runs. */""")

edit("arch/arm64/kvm/arm.c",
"""	case KVM_CAP_ARM_TIMER_TO_USER:
	case KVM_CAP_VCPU_EVENTS:""" if False else """	case KVM_CAP_ARM_FAULT_TO_USER:
	case KVM_CAP_ARM_TIMER_TO_USER:
""",
"""	case KVM_CAP_ARM_FAULT_TO_USER:
	case KVM_CAP_ARM_TIMER_TO_USER:
	case KVM_CAP_ARM_GIC_SYSREG_TO_USER:
""")


edit("arch/arm64/kvm/sys_regs.c",
"""		if (params.Op0 == 3 && (params.CRn & 0b1011) == 0b1011) {
			vcpu->run->exit_reason = KVM_EXIT_ARM_SYSREG;
			vcpu->run->arm_sysreg.esr_iss = esr & ESR_ELx_ISS_MASK;
			return 0;
		}
	}
""",
"""		if (params.Op0 == 3 && (params.CRn & 0b1011) == 0b1011) {
			vcpu->run->exit_reason = KVM_EXIT_ARM_SYSREG;
			vcpu->run->arm_sysreg.esr_iss = esr & ESR_ELx_ISS_MASK;
			return 0;
		}
	}

	/*
	 * The GICv3 CPU interface (ICC_PMR_EL1 and the ICC_* block at CRn 12,
	 * CRm 8-12) goes to userspace's GIC, in the same exit.
	 */
	if (test_bit(KVM_ARCH_FLAG_GIC_SYSREG_TO_USER, &vcpu->kvm->arch.flags) &&
	    !irqchip_in_kernel(vcpu->kvm)) {
		params = esr_sys64_to_params(esr);
		if (params.Op0 == 3 && params.Op1 <= 2 &&
		    ((params.CRn == 12 && params.CRm >= 8 && params.CRm <= 12) ||
		     (params.Op1 == 0 && params.CRn == 4 && params.CRm == 6 &&
		      params.Op2 == 0))) {
			vcpu->run->exit_reason = KVM_EXIT_ARM_SYSREG;
			vcpu->run->arm_sysreg.esr_iss = esr & ESR_ELx_ISS_MASK;
			return 0;
		}
	}
""")

# Keep the GIC visible in ID_AA64PFR0_EL1: userspace provides one.
edit("arch/arm64/kvm/sys_regs.c",
"""	if (!irqchip_in_kernel(kvm)) {
		u64 val;

		val = kvm_read_vm_id_reg(kvm, SYS_ID_AA64PFR0_EL1) & ~ID_AA64PFR0_EL1_GIC;""",
"""	if (!irqchip_in_kernel(kvm) &&
	    !test_bit(KVM_ARCH_FLAG_GIC_SYSREG_TO_USER, &kvm->arch.flags)) {
		u64 val;

		val = kvm_read_vm_id_reg(kvm, SYS_ID_AA64PFR0_EL1) & ~ID_AA64PFR0_EL1_GIC;""")

# With GIC_SYSREG_TO_USER, leave the GIC ID fields as userspace set them: the in-kernel-GIC
# fixup would clear them (no vGIC model), and QEMU's later register writes would then fail.
edit("arch/arm64/kvm/sys_regs.c",
"""		kvm_set_vm_id_reg(kvm, SYS_ID_PFR1_EL1, val);
	} else {
		/*
		 * Certain userspace software - QEMU - samples""",
"""		kvm_set_vm_id_reg(kvm, SYS_ID_PFR1_EL1, val);
	} else if (irqchip_in_kernel(kvm)) {
		/*
		 * Certain userspace software - QEMU - samples""")

print("all edits applied")
