/*
 * Copyright (c) 2009 Corey Tabaka
 * Copyright (c) 2017 Intel Corporation
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files
 * (the "Software"), to deal in the Software without restriction,
 * including without limitation the rights to use, copy, modify, merge,
 * publish, distribute, sublicense, and/or sell copies of the Software,
 * and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
#include <arch/x86/mmu.h>
#include <arch/x86/mp.h>
#include <arch/x86.h>
#include <arch/fpu.h>
#include <arch/mp.h>
#include <sys/types.h>
#include <string.h>
#include <lk/init.h>
#include <lk/main.h>

/* early stack */
uint8_t _kstack[PAGE_SIZE * SMP_MAX_CPUS] __ALIGNED(8);
volatile int cpu_waken_up = 0;

/* save a pointer to the multiboot information coming in from whoever called us */
/* make sure it lives in .data to avoid it being wiped out by bss clearing */
__SECTION(".data") void *_multiboot_info;

/* main tss */
static tss_t system_tss[SMP_MAX_CPUS];

x86_global_states_t global_states[SMP_MAX_CPUS];

static void init_global_states(x86_global_states_t *states, uint cpu)
{
    states->cur_thread    = NULL;
    states->syscall_stack = 0;

    write_msr(X86_MSR_GS_BASE, (uint64_t)states);
}

void arch_early_init(void)
{
    seg_sel_t sel = 0;
    uint cpu_id = 1;

    /*
     * meet some issue when using atomic(&cpu_waken_up, cpu_id);
     * use embedded inline assembly language directly.
     */
    __asm__ volatile("lock xaddq %%rax, (%%rdx)":"=a"(cpu_id):"a"(cpu_id), "d"(&cpu_waken_up));


    /*
     * At this point, BSP has set up current thread in global state,
     * initialize global states of AP(s) only.
     */
    if(0 != cpu_id)
        init_global_states(&global_states[cpu_id], cpu_id);

    x86_set_cr4(x86_get_cr4() | X86_CR4_FSGSBASE);

    sel = (seg_sel_t)(cpu_id << 4);
    sel += TSS_SELECTOR;

    /* enable caches here for now */
    clear_in_cr0(X86_CR0_NW | X86_CR0_CD);

    memset(&system_tss[cpu_id], 0, sizeof(tss_t));
    system_tss[cpu_id].rsp0 = 0;

#if ARCH_X86_32
    system_tss.esp0 = 0;
    system_tss.ss0 = DATA_SELECTOR;
    system_tss.ss1 = 0;
    system_tss.ss2 = 0;
    system_tss.eflags = 0x00003002;
    system_tss.bitmap = offsetof(tss_32_t, tss_bitmap);
    system_tss.trace = 1; // trap on hardware task switch
#endif

    set_global_desc(sel,
            &system_tss[cpu_id],
            sizeof(tss_t),
            1,
            0,
            0,
            SEG_TYPE_TSS,
            0,
            0);

    x86_ltr(sel);

    x86_mmu_early_init();
}

void arch_init(void)
{
    x86_mmu_init();

#ifdef X86_WITH_FPU
    fpu_init();
#endif

#if WITH_SMP
    arch_mp_init_percpu();

    /* Create thread for APs, need to be done before APs invoke */
    lk_init_secondary_cpus(SMP_MAX_CPUS - 1);
#endif
}

void *get_tss_base(void)
{
    volatile uint cpu = arch_curr_cpu_num();

    if (cpu < SMP_MAX_CPUS)
        return &system_tss[cpu];
    else
        return NULL;
}

void arch_chain_load(void *entry, ulong arg0, ulong arg1, ulong arg2, ulong arg3)
{
    PANIC_UNIMPLEMENTED;
}

void arch_enable_ints(void)
{
    CF;
    __asm__ volatile("sti");
}

void arch_disable_ints(void)
{
    __asm__ volatile("cli");
    CF;
}

bool arch_ints_disabled(void)
{
    x86_flags_t state;

    __asm__ volatile(
#if ARCH_X86_32
        "pushfl;"
        "popl %%eax"
#elif ARCH_X86_64
        "pushfq;"
        "popq %%rax"
#endif
        : "=a" (state)
        :: "memory");

    return !(state & (1<<9));
}

void arch_enter_uspace(vaddr_t entry_point, vaddr_t user_stack_top)
{
    PANIC_UNIMPLEMENTED;
#if 0
    DEBUG_ASSERT(IS_ALIGNED(user_stack_top, 16));

    thread_t *ct = get_current_thread();

    vaddr_t kernel_stack_top = (uintptr_t)ct->stack + ct->stack_size;
    kernel_stack_top = ROUNDDOWN(kernel_stack_top, 16);

    /* set up a default spsr to get into 64bit user space:
     * zeroed NZCV
     * no SS, no IL, no D
     * all interrupts enabled
     * mode 0: EL0t
     */
    uint32_t spsr = 0;

    arch_disable_ints();

    asm volatile(
        "mov    sp, %[kstack];"
        "msr    sp_el0, %[ustack];"
        "msr    elr_el1, %[entry];"
        "msr    spsr_el1, %[spsr];"
        "eret;"
        :
        : [ustack]"r"(user_stack_top),
        [kstack]"r"(kernel_stack_top),
        [entry]"r"(entry_point),
        [spsr]"r"(spsr)
        : "memory");
    __UNREACHABLE;
#endif
}

#if WITH_SMP
extern void setup_syscall_percpu(void);
extern void set_tss_segment_percpu(void);

void ap_entry(void)
{
    arch_early_init();

    x86_mmu_early_init();


    set_tss_segment_percpu();
    setup_syscall_percpu();

    fpu_init();

    arch_mp_init_percpu();

    write_msr(X86_MSR_KRNL_GS_BASE, 0);
    lk_init_level(LK_INIT_FLAG_SECONDARY_CPUS,
            LK_INIT_LEVEL_EARLIEST,
            LK_INIT_LEVEL_THREADING - 1);

    smp_mb();

    lk_secondary_cpu_entry();
}
#endif
