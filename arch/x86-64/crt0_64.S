/*
 * Copyright (c) 2009 Corey Tabaka
 * Copyright (c) 2015 Intel Corporation
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files
 * (the "Software"), to deal in the Software without restriction,
 * including without limitation the rights to use, copy, modify, merge,
 * publish, distribute, subqicense, and/or sell copies of the Software,
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

#define NUM_INT 0x100
#define NUM_EXC 0x14

#define MSR_EFER 0xc0000080
#define EFER_LME 0x00000100
#define KERNEL_STACK_SIZE 4096

/* PAT MSR id & value to be set */
#define PAT_MSR 0x277
#define CACHE_MODE 0x70106

.section ".text.boot"
.align 8
.code64
.global _start

_start:
    /* eVmm sends parameter by using RDI */
    /* save the param into g_trusty_startup_info */
    leaq g_trusty_startup_info(%rip), %rax
    movq %rdi, (%rax)

    /* Setting the PAT MSRs */
    xorq %rax, %rax
    xorq %rcx, %rcx
    xorq %rdx, %rdx
    movq $PAT_MSR, %rcx
    movq $CACHE_MODE, %rax	/* cacheability modes supported - WB, WC, UC, UC- */
    wrmsr

    /* Setup isr stub descriptors in the IDT */
    leaq _isr(%rip), %rsi
    leaq _idt(%rip), %rdi
    movq $NUM_INT, %rcx

.Lloop:
    movq %rsi, %rbx
    movw %bx, (%rdi)		/* low word in IDT(n).low */
    shrq $16, %rbx
    movw %bx, 6(%rdi)		/* high word in IDT(n).high */
    shrq $16, %rbx
    movl %ebx, 8(%rdi)
    addq $isr_stub_len, %rsi	/* index the next ISR stub */
    addq $16, %rdi			/* index the next IDT entry */
    loop .Lloop

    /* Update IDTR/GDTR base  */
    leaq _idt(%rip), %rax
    movq %rax, _idtr+2(%rip)
    lidt _idtr(%rip)

    leaq _gdt(%rip), %rax
    movq %rax, _gdtr+2(%rip)
    lgdt _gdtr(%rip)

    xor %rax, %rax
    movq $datasel_64, %rax
    movl %eax, %ds
    movl %eax, %es
    movl %eax, %fs
    movl %eax, %gs
    movl %eax, %ss

    leaq _kstack(%rip), %rsp

    /* Use correct Code Segment */
    xor %rax, %rax
    movw $codesel_64, %ax
    shl $32, %rax
    lea farjump(%rip), %rcx
    add %rcx, %rax
    push %rax
    retf

farjump:
    xorq %rax, %rax
    lldt %ax
    movq $tsssel, %rax
    ltr %ax

    /* Build a 4GB pagetable with 2MB pagesize */
    pushq %rdi
    leaq pagetable(%rip), %rdi
    call build_pagetable

    movq %rdi, %cr3
    popq %rdi

    /* zero the bss section */
    leaq __bss_start(%rip), %rdi /* starting address of the bss */
    leaq __bss_end(%rip), %rcx   /* find the length of the bss in bytes */
    subq %rdi, %rcx
    shrq $2, %rcx		/* convert to 32 bit words, since the bss is aligned anyway */

2:
    movq $0, (%rdi)
    addq $4, %rdi
    loop 2b

    /* set the default params to 0, since these params are not used for now */
    movq $0, %rdi
    movq $0, %rsi
    movq $0, %rdx
    movq $0, %rcx

    /* call the main module */
    call lk_main
    jmp 0f

0:
    hlt		/* interrupts will unhalt the processor */
    pause
    jmp 0b		/* so jump back to halt to conserve power */

    /* interrupt service routine stubs */
_isr:
.set i, 0
.rept NUM_INT

.set isr_stub_start, .

.if i == 8 || (i >= 10 && i <= 14) || i == 17
    nop            /* error code pushed by exception */
    nop            /* 2 nops are the same length as push byte */
    pushq $i       /* interrupt number */
.if i < 0x80
    nop            /* i>=0x80, pushq $i occupies 5 bytes compare to 2 bytes if i<0x80 */
    nop            /* need to add 3 nops to fill the gap */
    nop            /* to make sure isr_stub_len correct for each intr */
.endif
    jmp interrupt_common
.else
    pushq $0       /* fill in error code in iframe */
    pushq $i       /* interrupt number */
.if i < 0x80
    nop            /* i>=0x80, pushq $i occupies 5 bytes compare to 2 bytes if i<0x80*/
    nop            /* need to add 3 nops to fill the gap */
    nop            /* to make sure isr_stub_len correct for each intr */
.endif
    jmp interrupt_common
.endif

/* figure out the length of a single isr stub (usually 6 or 9 bytes) */
.set isr_stub_len, . - isr_stub_start

.set i, i + 1
.endr

/* annoying, but force AS to use the same (longer) encoding of jmp for all of the stubs */
.fill 256

interrupt_common:
    /* save general purpose registers */
    pushq %r15
    pushq %r14
    pushq %r13
    pushq %r12
    pushq %r11
    pushq %r10
    pushq %r9
    pushq %r8
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rbx
    pushq %rbp
    pushq %rsi
    pushq %rdi

    /* store stack switch pivot. push rsp has errata on some cpus, so use mov/push */
    movq %rsp, %rax
    pushq %rax
    movq %rsp, %rdi		/* pass the  iframe using rdi */

    call platform_irq

    cmpq $0,%rax
    je 0f
    call thread_preempt

0:
    /* restore task_rsp, stack switch can occur here if task_rsp is modified */
    popq %rax
    movq %rax, %rsp

    /* restore general purpose registers */
    popq %rdi
    popq %rsi
    popq %rbp
    popq %rbx
    popq %rdx
    popq %rcx
    popq %rax
    popq %r8
    popq %r9
    popq %r10
    popq %r11
    popq %r12
    popq %r13
    popq %r14
    popq %r15

    /* drop vector number and error code */
    addq $16, %rsp
    iretq

.data
.align 8
.global g_trusty_startup_info
g_trusty_startup_info:
    .quad 0

.align 8
.global _gdtr
_gdtr:
    .short _gdt_end - _gdt - 1
    .quad _gdt
.align 8
.global _gdt
_gdt:
    .int 0			   	/* NULL Descriptor_L */
    .int 0				/* NULL Descriptor_H */

/* ring 0 descriptors */
.set codesel_32, . - _gdt
_code_32_gde:
    .short 0xffff			/* limit 15:00 */
    .short 0x0000			/* base 15:00 */
    .byte  0x00				/* base 23:16 */
    .byte  0b10011010		/* P(1) DPL(00) S(1) 1 C(0) R(1) A(0) */
    .byte  0b11001111		/* G(1) D(1) 0 0 limit 19:16 */
    .byte  0x0				/* base 31:24 */

.set datasel, . - _gdt
_data_gde:
    .short 0xffff			/* limit 15:00 */
    .short 0x0000			/* base 15:00 */
    .byte  0x00				/* base 23:16 */
    .byte  0b10010010		/* P(1) DPL(00) S(1) 0 E(0) W(1) A(0) */
    .byte  0b11001111		/* G(1) B(1) 0 0 limit 19:16 */
    .byte  0x0				/* base 31:24 */

.set user_codesel_32, . - _gdt
_user_code_32_gde:
    .short 0xffff			/* limit 15:00 */
    .short 0x0000			/* base 15:00 */
    .byte  0x00				/* base 23:16 */
    .byte  0b11111010		/* P(1) DPL(11) S(1) 1 C(0) R(1) A(0) */
    .byte  0b11001111		/* G(1) D(1) 0 0 limit 19:16 */
    .byte  0x0				/* base 31:24 */

.set user_datasel, . - _gdt
_user_data_32_gde:
    .short 0xffff			/* limit 15:00 */
    .short 0x0000			/* base 15:00 */
    .byte  0x00				/* base 23:16 */
    .byte  0b11110010		/* P(1) DPL(11) S(1) 0 E(0) W(1) A(0) */
    .byte  0b11001111		/* G(1) B(1) 0 0 limit 19:16 */
    .byte  0x0				/* base 31:24 */

.set null_2, . - _gdt
_null_2_gde:
    .int 0
    .int 0


.set codesel_64, . - _gdt
_code_64_gde:
    .short 0xffff			/* limit 15:00 */
    .short 0x0000			/* base 15:00 */
    .byte  0x00				/* base 23:16 */
    .byte  0b10011010		/* P(1) DPL(00) S(1) 1 C(0) R(1) A(0) */
    .byte  0b10101111		/* G(1) D(0) L(1) AVL(0) limit 19:16 */
    .byte  0x0				/* base 31:24 */

.set datasel_64, . - _gdt
_data_64_gde:
    .short 0xffff			/* limit 15:00 */
    .short 0x0000			/* base 15:00 */
    .byte  0x00				/* base 23:16 */
    .byte  0b10010010		/* P(1) DPL(00) S(1) 0 E(0) W(1) A(0) */
    .byte  0b11001111		/* G(1) B(1) L(0) AVL(0) limit 19:16 */
    .byte  0x0				/* base 31:24 */

.set user_codesel_compat, . - _gdt
_user_code_compat_gde:
    .short 0xffff			/* limit 15:00 */
    .short 0x0000			/* base 15:00 */
    .byte  0x00				/* base 23:16 */
    .byte  0b11111010		/* P(1) DPL(00) S(1) 1 C(0) R(1) A(0) */
    .byte  0b11001111		/* G(1) D(1) L(0) AVL(0) limit 19:16 */
    .byte  0x0				/* base 31:24 */

.set user_datasel_compat, . - _gdt
_user_data_compat_gde:
    .short 0xffff			/* limit 15:00 */
    .short 0x0000			/* base 15:00 */
    .byte  0x00				/* base 23:16 */
    .byte  0b11110010		/* P(1) DPL(11) S(1) 0 E(0) W(1) A(0) */
    .byte  0b11001111		/* G(1) B(1) 0 0 limit 19:16 */
    .byte  0x0				/* base 31:24 */

.set user_codesel_64, . - _gdt
_user_code_64_gde:
    .short 0xffff			/* limit 15:00 */
    .short 0x0000			/* base 15:00 */
    .byte  0x00				/* base 23:16 */
    .byte  0b11111010		/* P(1) DPL(11) S(1) 1 C(0) R(1) A(0) */
    .byte  0b10101111		/* G(1) D(0) L(1) AVL(0) limit 19:16 */
    .byte  0x0				/* base 31:24 */

.set user_datasel_64, . - _gdt
_user_data_64_gde:
    .short 0xffff			/* limit 15:00 */
    .short 0x0000			/* base 15:00 */
    .byte  0x00				/* base 23:16 */
    .byte  0b11110010		/* P(1) DPL(11) S(1) 0 E(0) W(1) A(0) */
    .byte  0b11001111		/* G(1) B(1) 0 0 limit 19:16 */
    .byte  0x0				/* base 31:24 */

/* TSS descriptor */
.set tsssel, . - _gdt
_tss_gde:
    .short 0				/* limit 15:00 */
    .short 0				/* base 15:00 */
    .byte  0				/* base 23:16 */
    .byte  0x89				/* P(1) DPL(0) S(0) TYPE(9) */
    .byte  0x80				/* G(1) D/B(0) L(0) AVL(0) limit 19:16 */
    .byte  0				/* base 31:24 */
    .quad 0x0000000000000000
.global _gdt_end
_gdt_end:

.align 8
.global _idtr
_idtr:
    .short _idt_end - _idt - 1	/* IDT limit */
    .quad _idt
.fill 8
.align 8
/* interrupt descriptor table (IDT) */
.global _idt
_idt:

.set i, 0
.rept NUM_INT-1
    .short 0		/* low 16 bits of ISR offset (_isr#i & 0FFFFh) */
    .short codesel_64	/* selector */
    .byte  0
    .byte  0x8e		/* present, ring 0, 64-bit interrupt gate */
    .short  0		/* high 16 bits of ISR offset (_isr#i / 65536) */
    .short  0		/* ISR offset */
    .short  0		/* ISR offset */
    .short  0		/* 32bits Reserved */
    .short  0		/* 32bits Reserved */

.set i, i + 1
.endr

/* syscall int (ring 3) */
_idt30:
    .short 0				/* low 16 bits of ISR offset (_isr#i & 0FFFFh) */
    .short codesel_64		/* selector */
    .byte  0
    .byte  0xee				/* present, ring 3, 32-bit interrupt gate */
    .short 0				/* high 16 bits of ISR offset (_isr#i / 65536) */

.global _idt_end
_idt_end:

/* used to build a 4GB pagetable with 2M pagesize */
.align 4096
pagetable:
    .fill 4096*6,1,0x0

.bss
.align 4096

.global _kstack

.fill KERNEL_STACK_SIZE * SMP_MAX_CPUS
_kstack:
