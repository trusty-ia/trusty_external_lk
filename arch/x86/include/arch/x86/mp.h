/*******************************************************************************
 * Copyright (c) 2017 Intel Corporation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *******************************************************************************/
#pragma once

#include <arch/x86.h>

typedef struct x86_global_state {
    void *cur_thread;
    uint64_t syscall_stack;
} x86_global_states_t;

#define CUR_THREAD_OFFSET       __offsetof(struct x86_global_state, cur_thread)
#define SYSACLL_STACK_OFFSET    __offsetof(struct x86_global_state, syscall_stack)

extern x86_global_states_t global_state[SMP_MAX_CPUS];

static inline void * x86_get_current_thread(void)
{
    return (void *)x86_read_gs_with_offset(CUR_THREAD_OFFSET);
}

static inline void x86_set_current_thread(void *cur_thread)
{
    x86_write_gs_with_offset(CUR_THREAD_OFFSET, (uint64_t)cur_thread);
}

static inline uint64_t x86_get_syscall_stack(void)
{
    return x86_read_gs_with_offset(SYSACLL_STACK_OFFSET);
}

static inline void x86_set_syscall_stack(uint64_t stack)
{
    x86_write_gs_with_offset(SYSACLL_STACK_OFFSET, stack);
}
