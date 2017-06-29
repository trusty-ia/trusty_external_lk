/*
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

#define KERNEL_STACK_SIZE 4096

.macro page_mode_jump sel, offset
    .byte 0x66
    .byte 0xEA
    .short \offset
    .short \offset >> 16
    .short \sel
.endm

.align PAGE_SIZE
.section ".text.boot"
FUNCTION(ap_entry_16)
.code16
    /*
     * Update DS, needs hot patch
     * CAUTION!! We are in real mode now:
     * real IP address: DS << 4 + IP
     * DS should be sipi page left shift 4 bits
     */
    mov $0, %ax
    mov %ax, %ds

    /* LGDT with temp GDT in this file, needs hot patch */
    lea 0, %si
    lgdt (%si)

    /* Enable PE, then we can far jmp to 32 bit */
    mov %cr0, %eax
    or  $1, %ax
    mov %eax, %cr0

    /*
     * PG enbaled, but still compiled with .code16
     * Need to add 0x66H prefix to specify operand size to be 32 bit.
     * Failed to compile due to exceed size of jump witout 0x66.
     * Since we have no idea where we are located, we need hot patch
     * to update physical address of ap_entry_32
     */
    page_mode_jump 0x08, 0xFFFF

FUNCTION(ap_entry_32)
.code32
    /* Hot patch it */
    movl $0x97000, %ebp

    /* reload our segments */
    movw $DATA_SELECTOR, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %ss
    movw %ax, %gs
    movw %ax, %ss

    /* Calculate APs index */
    mov $1, %ecx
    lea PHYS(aps_to_init)(%ebp), %eax
    lock xadd %ecx, (%eax)
    inc %ecx

    /* store APs index in ebx */
    mov %ecx, %ebx

    mov %ecx, %eax
    inc %eax
    mov $KERNEL_STACK_SIZE, %edx
    mul %edx
    /* set the kernel stack */
    lea PHYS(_kstack)(%ebp, %eax), %esp

    /* PAE bit must be enabled  for 64 bit paging*/
    mov %cr4, %eax
    bts $(5), %eax
    mov %eax, %cr4

    /* load the physical pointer to the top level page table */
    lea PHYS(pml4)(%ebp), %eax
    mov %eax, %cr3

    /* Long Mode Enabled at this point*/
    mov $MSR_EFER ,%ecx
    rdmsr
    or  $EFER_LME,%eax
    wrmsr

    /* setting the PAT MSRs */
    mov $PAT_MSR, %ecx
    mov $CACHE_MODE, %eax
    mov $CACHE_MODE, %edx
    wrmsr

    /*
     * Enabling Paging and from this point we are in
     * 32 bit compatibility mode
     */
    mov %cr0,  %eax
    btsl $(31), %eax
    mov %eax,  %cr0

    /* Using long-jump jump to 64 bit mode */
    pushl $CODE_64_SELECTOR
    lea PHYS(ap_farjump64)(%ebp), %eax
    pushl %eax
    retf

.align 8
.code64
ap_farjump64:
    /* Here is still below 4G */
    xorq %rax, %rax
    lldt %ax

    /* Now we jump to high address above 0xFFFFFFFF80000000 */
    mov  $ap_highaddr, %rax
    jmp  *%rax

ap_highaddr:
    xorq %rax, %rax
    movl %ebx, %eax
    inc  %rax

    movq $KERNEL_STACK_SIZE, %rsp
    mulq %rsp
    leaq _kstack(%rax), %rsp

    lgdt _gdtr

    lidt _idtr

    call ap_entry

0:
    hlt
    pause
    jmp 0b

.global ap_entry_end
ap_entry_end:

.global aps_to_init
aps_to_init:
.fill 8, 1, 0x0

.align 8
.global ap_gdtr
ap_gdtr:
    .short 0
    .int 0

/*
 * GDTR table please keep align with arch/x86/gdt.S
 * So when we reload GDTR, no need to update segments
 */
.align 8
.global ap_gdt_table
ap_gdt_table:
    /* NULL */
    .quad  0x0
    /* 0x08: code32 */
    .quad  0x00CF9A000000FFFF
    /* 0x10: data32 */
    .quad  0x00CF92000000FFFF
    /* 0x18: NULL */
    .quad  0x0
    /* 0x20: NULL */
    .quad  0x0
    /* 0x28: NULL */
    .quad  0x0
    /* 0x30: code64 */
    .quad  0x00AF9A000000FFFF
    /* 0x38: data64 */
    .quad  0x00CF92000000FFFF
.global ap_gdt_table_end
ap_gdt_table_end:
