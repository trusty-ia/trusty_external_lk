/*******************************************************************************
 * Copyright (c) 2015 Intel Corporation
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

#include <compiler.h>
#include <sys/types.h>
#include <stdlib.h>
#include <stdbool.h>

//broadcast is excluding self, send is specified.
bool broadcast_nmi(void);
bool broadcast_init(void);
bool broadcast_startup(uint32_t vector);
bool send_nmi(uint32_t lapic_id);
bool send_startup(uint32_t lapic_id, uint32_t vector);

bool send_reschedule_ipi(uint32_t cpuid);

// need to be called for all cpus
void lapic_id_init(void);
void local_apic_init(void);
void lapic_eoi(void);
void lapic_software_disable(void);
bool send_self_ipi(uint32_t vector);
