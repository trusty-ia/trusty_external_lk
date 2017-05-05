/*
 * Copyright (c) 2009 Corey Tabaka
 * Copyright (c) 2014 Travis Geiselbrecht
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
#pragma once

#include <compiler.h>
#include <stdbool.h>

#ifndef ASSEMBLY

#include <arch/x86.h>

/* override of some routines */
void arch_enable_ints(void);

void arch_disable_ints(void);

bool arch_ints_disabled(void);

static inline void arch_enable_fiqs(void)
{
      CF;
}

static inline void arch_disable_fiqs(void)
{
      CF;
}


int _atomic_and(volatile int *ptr, int val);
int _atomic_or(volatile int *ptr, int val);
int _atomic_cmpxchg(volatile int *ptr, int oldval, int newval);

static inline int atomic_add(volatile int *ptr, int val)
{
    __asm__ volatile(
        "lock xaddl %[val], %[ptr];"
        : [val]"=a" (val)
        : "a" (val), [ptr]"m" (*ptr)
        : "memory"
    );

    return val;
}

static inline int atomic_swap(volatile int *ptr, int val)
{
    __asm__ volatile(
        "xchgl %[val], %[ptr];"
        : [val]"=a" (val)
        : "a" (val), [ptr]"m" (*ptr)
        : "memory"
    );

    return val;
}

#if ARCH_X86_32
static inline int atomic_and(volatile int *ptr, int val) { return _atomic_and(ptr, val); }
static inline int atomic_or(volatile int *ptr, int val) { return _atomic_or(ptr, val); }
static inline int atomic_cmpxchg(volatile int *ptr, int oldval, int newval) { return _atomic_cmpxchg(ptr, oldval, newval); }
#elif ARCH_X86_64
static inline int atomic_and(volatile int *ptr, long val) { return _atomic_and(ptr, val); }
static inline int atomic_or(volatile int *ptr, long val) { return _atomic_or(ptr, val); }
static inline int atomic_cmpxchg(volatile int *ptr, int oldval, uint64_t newval)
{
#if USE_GCC_ATOMICS
    __atomic_compare_exchange_n(ptr, &oldval, newval, false,
            __ATOMIC_RELAXED, __ATOMIC_RELAXED);

#else
    __asm__ volatile(
        "lock cmpxchgq  %[newval], %[ptr];"
        : "=a" (oldval),  "=m" (*ptr)
        : "a" (oldval), [newval]"r" (newval), [ptr]"m" (*ptr)
        : "memory"
    );
#endif
    return oldval;
}
#endif

static inline uint32_t arch_cycle_count(void)
{
    uint32_t timestamp;
    rdtscl(timestamp);

    return timestamp;
}

struct thread *get_current_thread(void);

void set_current_thread(struct thread *t);

static inline uint arch_curr_cpu_num(void)
{
    return 0;
}

#define mb()        CF
#define wmb()       CF
#define rmb()       CF

#ifdef WITH_SMP
#define smp_mb()    CF
#define smp_wmb()   CF
#define smp_rmb()   CF
#else
#define smp_mb()    CF
#define smp_wmb()   CF
#define smp_rmb()   CF
#endif

#endif // !ASSEMBLY
