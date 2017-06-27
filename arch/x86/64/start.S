/*
 * Copyright (c) 2009 Corey Tabaka
 * Copyright (c) 2015 Intel Corporation
 * Copyright (c) 2016 Travis Geiselbrecht
 * Copyright (c) 2017 Intel Corparation
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
#include <asm.h>
#include <arch/x86/descriptor.h>
#include <arch/x86/mmu.h>

#define MSR_EFER   0xc0000080
#define EFER_LME   0x00000100
#define PAT_MSR    0x277
#define CACHE_MODE 0x70106

#define PHYS_ADDR_DELTA          (KERNEL_BASE - MEMBASE)
#define PHYS(x)                  ((x) - PHYS_ADDR_DELTA)
#define DEV_INFO_POINTER         16

#define PGDIR_SHIFT      39
#define PUD_SHIFT        30
#define PMD_SHIFT        21
#define PTD_SHIFT        12
#define PTRS_MASK     (512 - 1)

.macro pg_shift src, dst, imm
    movq %\src, %\dst
    shrq $\imm, %\dst
    andq $PTRS_MASK, %\dst
    shlq $3, %\dst
.endm

.section ".text.boot"
.code32
.global _start
_start:
.align 8

    /* get the offset between compiled entry address and
     * actually entry address in edi register temporary
     */
    call 1f
1:
    popl %ebp
    subl $PHYS(1b), %ebp

    /* load our new gdt by physical pointer */
    lea PHYS(_gdtr_phys)(%ebp), %eax
    lea PHYS(_gdt)(%ebp), %ebx
    movl %ebx, 2(%eax)
    lgdt (%eax)

    /* load our data selectors */
    movw $DATA_SELECTOR, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %ss
    movw %ax, %gs
    movw %ax, %ss

    /* set the kernel stack */
    lea PHYS(_kstack + 4096)(%ebp), %esp

    /* We need to jump to our sane 32 bit CS */
    pushl $CODE_SELECTOR
    lea PHYS(.Lfarjump)(%ebp), %eax
    pushl %eax
    retf

.Lfarjump:
    /* zero the bss section */
bss_setup:
    lea PHYS(__bss_start)(%ebp), %eax /* starting address of the bss */
    lea PHYS(__bss_end)(%ebp), %ecx   /* find the length of the bss in bytes */
    subl %eax, %ecx
    shrl $2, %ecx       /* convert to 32 bit words, since the bss is aligned anyway */
2:
    movl $0, (%eax)
    addl $4, %eax
    loop 2b

    movl %edi, %eax

    /* save g_trusty_startup_info in local */
    movl %edi, %esi
    lea PHYS(g_trusty_startup_info)(%ebp), %edi
    movl $24, %ecx
    shrl $2, %ecx
    rep movsl

    /* clear previous g_trusty_startup_info */
    movl $24, %ecx
    shrl $2, %ecx
2:
    movl $0, (%eax)
    addl $4, %eax
    loop 2b

    /* save g_dev_info in local */
    movl PHYS(g_trusty_startup_info + 16)(%ebp), %esi
    lea PHYS(g_dev_info_buf)(%ebp), %edi
    movl $4096, %ecx
    shrl $2, %ecx
    rep movsl

    /* clear previous g_dev_info */
    movl PHYS(g_trusty_startup_info + 16)(%ebp), %eax
    movl $4096, %ecx
    shrl $2, %ecx
2:
    movl $0, (%eax)
    addl $4, %eax
    loop 2b

paging_setup:
    /* Preparing 64 bit paging, we will use 2MB pages covering 4GB
    for initial bootstrap, this page table will be 1 to 1  */

    /* PAE bit must be enabled  for 64 bit paging*/
    mov %cr4, %eax
    btsl $(5), %eax
    mov %eax, %cr4

    /* load the physical pointer to the top level page table */
    lea PHYS(pml4)(%ebp), %eax
    mov %eax, %cr3

    /* Long Mode Enabled at this point*/
    movl $MSR_EFER ,%ecx
    rdmsr
    orl $EFER_LME,%eax
    wrmsr

    /* setting the PAT MSRs */
    movl $PAT_MSR, %ecx
    movl $CACHE_MODE, %eax
    movl $CACHE_MODE, %edx
    wrmsr

    /*
     ************************
     * map the early bootstrap, 2M leaf
     ************************
     */
    lea PHYS(pml4)(%ebp), %edi
    lea PHYS(pdp_bootstrap)(%ebp), %esi
    orl $X86_KERNEL_PD_FLAGS, %esi
    movl %esi, (%edi)

    /* map the first 4GB in this table */
    lea PHYS(pdp_bootstrap)(%ebp), %edi
    lea PHYS(pde_bootstrap)(%ebp), %esi
    orl  $X86_KERNEL_PD_FLAGS, %esi
    movl $4, %ecx
0:
    movl %esi, (%edi)
    add  $8, %edi
    addl $4096, %esi
    loop 0b

    lea PHYS(pde_bootstrap)(%ebp), %edi
    movl $2048, %ecx
    xor  %eax, %eax

    /* loop across these page tables, incrementing the address by 2MB */
0:
    mov  %eax, %ebx
    shll $21, %ebx
    orl  $X86_KERNEL_PD_LP_FLAGS, %ebx    # lower word of the entry
    movl %ebx, (%edi)
    mov  %eax, %ebx
    shrl $11, %ebx      # upper word of the entry
    movl %ebx, 4(%edi)
    addl $8,%edi
    inc  %eax
    loop 0b


    /* Enabling Paging and from this point we are in
    32 bit compatibility mode*/
    mov %cr0,  %eax
    btsl $(31), %eax
    mov %eax,  %cr0


    /* Using another long jump to be on 64 bit mode
    after this we will be on real 64 bit mode */
    pushl $CODE_64_SELECTOR     /*Need to put it in a the right CS*/
    lea PHYS(farjump64)(%ebp), %eax
    pushl %eax
    retf

.align 8
.code64
farjump64:
    /*
     **************************
     * start to map the kernel region, 4K leaf
     **************************
     */
    /* get the offset from run addr to mem base */
    movq g_trusty_startup_info + 16(%rip), %rbp
    leaq _start(%rip), %rax
    subq %rbp, %rax
    movq $_start, %rbp
    subq %rax, %rbp

    pg_shift rbp, rax, PGDIR_SHIFT
    leaq pml4(%rip), %rdi
    addq %rax, %rdi
    leaq pdp_high(%rip), %rsi
    orq $X86_KERNEL_PD_FLAGS, %rsi
    movq %rsi, (%rdi)

    /* point the pdp_high table at pde_kernel */
    pg_shift rbp, rax, PUD_SHIFT
    leaq pdp_high(%rip), %rdi
    addq %rax, %rdi
    leaq pde_kernel(%rip), %rsi
    orq $X86_KERNEL_PD_FLAGS, %rsi
    movq %rsi, (%rdi)

    /* map lk image according to LK_IMAGE_SIZE_4K_PAGES */
    pg_shift rbp, rax, PMD_SHIFT
    leaq pde_kernel(%rip), %rdi
    addq %rax, %rdi
    leaq pte_kernel(%rip), %rsi
    orq  $X86_KERNEL_PD_FLAGS, %rsi
    movq $8, %rcx

0:
    movq %rsi, (%rdi)
    addq  $8, %rdi
    addq $4096, %rsi
    loop 0b


    pg_shift rbp, rax, PTD_SHIFT
    leaq pte_kernel(%rip), %rdi
    addq %rax, %rdi
    movq g_trusty_startup_info + 16(%rip), %rsi
    addq $8, %rcx
    shlq $9, %rcx

0:
    orq  $0x103, %rsi
    movq %rsi, (%rdi)
    addq $8,%rdi
    addq $4096, %rsi
    loop 0b

    /* save the run addr */
    leaq _start(%rip), %rax
    movq %rax, real_run_addr(%rip)


    /* branch to our high address */
    mov  $highaddr, %rax
    jmp  *%rax

highaddr:
    /* load the high kernel stack */
    mov  $(_kstack + 4096), %rsp

    /* reload the gdtr */
    lgdt _gdtr

#ifdef STACK_PROTECTOR
    /* setup the random value of stack check guard before C call.
     * the rdrand call fails sometimes, so there given 10 loops.
     * if rdrand call fails 10 times, it will jump to dead loop.
     */
    mov $10, %edx
1:
    rdrand %rax
    jc 2f            #jump short if carry (CF=1)
    decl %edx
    jnz 1b
    jz 0f
2:  mov %rax, __stack_chk_guard(%rip)
#endif

    /* set up the idt */
    call setup_idt

    xorq %rdi, %rdi
    xorq %rsi, %rsi
    xorq %rdx, %rdx
    xorq %rcx, %rcx

    /* call the main module */
    call lk_main

0:                          /* just sit around waiting for interrupts */
    hlt                     /* interrupts will unhalt the processor */
    pause
    jmp 0b                  /* so jump back to halt to conserve power */

.global _start_pa
.set _start_pa, _start - KERNEL_BASE

