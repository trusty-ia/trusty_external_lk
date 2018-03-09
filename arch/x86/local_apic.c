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
#include <stdint.h>
#include <assert.h>
#include <arch/x86.h>
#include <arch/x86/mmu.h>
#include <arch/arch_ops.h>
#include <arch/local_apic.h>
#include <kernel/vm.h>
#include <platform/vmcall.h>

typedef enum {
    LAPIC_ID_REG            = 0x2,
    LAPIC_EOI               = 0xB,
    LAPIC_SIVR              = 0xF,
    LAPIC_INTR_CMD_REG      = 0x30, /* 64-bits in x2APIC */
    LAPIC_INTR_CMD_HI_REG   = 0x31, /* not available in x2APIC */
    LAPIC_SELF_IPI_REG      = 0x3F /* not available in xAPIC */
} lapic_reg_id_t;

#define PAGE_4K_MASK 0xfffULL

#define MASK64_LOW(n) ((1ULL<<(n)) - 1)
#define MASK64_MID(h, l) ((1ULL << ((h)+1)) - (1ULL << (l)))
#define MAKE64(high, low) (((uint64_t)(high))<<32 | (((uint64_t)(low)) & MASK64_LOW(32)))

#define MSR_APIC_BASE 0x1B
#define LAPIC_ENABLED  (1ULL << 11)
#define LAPIC_X2_ENABLED  (1ULL << 10)
#define LAPIC_BASE_ADDR(base_msr) ((base_msr) & (~PAGE_4K_MASK))

//deliver status bit 12. 0 idle, 1 send pending.
#define APIC_DS_BIT (1<<12)
#define MSR_X2APIC_BASE 0x800

#define APIC_DM_FIXED 0x000
#define APIC_DM_NMI 0x400
#define APIC_DM_INIT 0X500
#define APIC_DM_STARTUP 0x600
#define APIC_LEVEL_ASSERT 0x4000
#define APIC_DEST_NOSHORT 0x00000
#define APIC_DEST_SELF    0x40000
#define APIC_DEST_EXCLUDE 0xC0000

static volatile uint64_t lapic_base_virtual_addr = 0;

static uint32_t g_lapic_id[SMP_MAX_CPUS];
static void lapic_software_enable_lapic(void);

static uint32_t lapic_x1_read_reg(lapic_reg_id_t reg_id)
{
    DEBUG_ASSERT(lapic_base_virtual_addr);
    uint64_t addr = lapic_base_virtual_addr + (uint64_t)(reg_id << 4);

    return *(volatile uint32_t*)(addr);
}

static void lapic_x1_write_reg(lapic_reg_id_t reg_id, uint32_t data)
{
    DEBUG_ASSERT(lapic_base_virtual_addr);
    uint64_t addr = lapic_base_virtual_addr + (uint64_t)(reg_id << 4);

    *(volatile uint32_t*)addr = data;

}

//caller must make sure xAPIC mode.
static void lapic_x1_wait_for_ipi(void)
{
    uint32_t icr_low;

    while (1) {
        icr_low = lapic_x1_read_reg(LAPIC_INTR_CMD_REG);
        if ((icr_low & APIC_DS_BIT) == 0)
            return;
    }
}

static uint64_t lapic_x2_read_reg(lapic_reg_id_t reg_id)
{
    return read_msr(MSR_X2APIC_BASE + reg_id);
}

static void lapic_x2_write_reg(lapic_reg_id_t reg_id, uint64_t data)
{
    write_msr(MSR_X2APIC_BASE + reg_id, data);
}


/* When adding new APIs, please check IA32 spec -> Local APIC chapter
 ** -> ICR section, to learn the valid combination of destination
 ** shorthand, deliver mode, and trigger mode for Pentium 4 Processor */
static bool lapic_send_ipi_excluding_self(uint32_t delivery_mode, uint32_t vector)
{
    uint32_t icr_low = APIC_DEST_EXCLUDE|APIC_LEVEL_ASSERT|delivery_mode|vector;
    uint64_t apic_base_msr = read_msr(MSR_APIC_BASE);

    if (!(apic_base_msr & LAPIC_ENABLED)) {
        return false;
    }

    if (apic_base_msr & LAPIC_X2_ENABLED) {
        //x2APIC
        lapic_x2_write_reg(LAPIC_INTR_CMD_REG, (uint64_t)icr_low);
    }else {
        //xAPIC
        //need wait in x1 APIC only.
        lapic_x1_wait_for_ipi();
        lapic_x1_write_reg(LAPIC_INTR_CMD_REG, icr_low);
    }

    return true;
}

static bool lapic_send_ipi_to_cpu(uint32_t lapic_id, uint32_t delivery_mode, uint32_t vector)
{
    uint32_t icr_hi;
    uint32_t icr_low = APIC_DEST_NOSHORT|APIC_LEVEL_ASSERT|delivery_mode|vector;
    uint64_t apic_base_msr = read_msr(MSR_APIC_BASE);

    if (!(apic_base_msr & LAPIC_ENABLED)) {
        return false;
    }

    if (apic_base_msr & LAPIC_X2_ENABLED) {
        //x2APIC
        lapic_x2_write_reg(LAPIC_INTR_CMD_REG, MAKE64(lapic_id, icr_low));
    }else {
        //xAPIC
        icr_hi = lapic_x1_read_reg(LAPIC_INTR_CMD_HI_REG); //save guest ICR_HI
        lapic_x1_write_reg(LAPIC_INTR_CMD_HI_REG, lapic_id);
        //need wait in x1 APIC only.
        lapic_x1_wait_for_ipi();
        lapic_x1_write_reg(LAPIC_INTR_CMD_REG, icr_low);
        lapic_x1_write_reg(LAPIC_INTR_CMD_HI_REG, icr_hi); //restore guest ICR_HI
    }

    return true;
}

void local_apic_init(void)
{
    arch_flags_t access = ARCH_MMU_FLAG_PERM_NO_EXECUTE | ARCH_MMU_FLAG_UNCACHED;
    struct map_range range;
    map_addr_t pml4_table = (map_addr_t)paddr_to_kvaddr(get_kernel_cr3());
    uint64_t lapic_base_phy_addr = read_msr(MSR_APIC_BASE);

    lapic_base_phy_addr = LAPIC_BASE_ADDR(lapic_base_phy_addr);

    // :TODO: remove hard code
    range.start_vaddr = (map_addr_t)(0xFFFFFFFF00000000ULL + (uint64_t)lapic_base_phy_addr);
    range.start_paddr = (map_addr_t)lapic_base_phy_addr;
    range.size        = PAGE_SIZE;
    x86_mmu_map_range(pml4_table, &range, access);

#ifdef EPT_DEBUG
    make_ept_update_vmcall(ADD, lapic_base_phy_addr, PAGE_SIZE);
#endif

    lapic_base_virtual_addr = range.start_vaddr;
}

static bool lapic_get_id(uint32_t *p_lapic_id)
{
    uint64_t apic_base_msr = read_msr(MSR_APIC_BASE);

    if (!(apic_base_msr & LAPIC_ENABLED)) {
        return false;
    }

    if (apic_base_msr & LAPIC_X2_ENABLED) {
        //x2APIC
        *p_lapic_id = (uint32_t)lapic_x2_read_reg(LAPIC_ID_REG);
    }else {
        //xAPIC
        *p_lapic_id = lapic_x1_read_reg(LAPIC_ID_REG);

    }

    // enable local APIC
    lapic_software_enable_lapic();

    return true;
}

static uint32_t get_lapic_id(uint16_t cpuid)
{
    DEBUG_ASSERT(cpuid < SMP_MAX_CPUS);

    return g_lapic_id[cpuid];
}

void lapic_id_init(void)
{
    uint cpu = arch_curr_cpu_num();

    lapic_get_id(&g_lapic_id[cpu]);
}

bool broadcast_nmi(void)
{
    return lapic_send_ipi_excluding_self(APIC_DM_NMI, 0);
}

bool broadcast_init(void)
{
    return lapic_send_ipi_excluding_self(APIC_DM_INIT, 0);
}

bool broadcast_startup(uint32_t vector)
{
    return lapic_send_ipi_excluding_self(APIC_DM_STARTUP, vector);
}

bool send_nmi(uint32_t lapic_id)
{
    return lapic_send_ipi_to_cpu(lapic_id, APIC_DM_NMI, 0);
}

bool send_startup(uint32_t lapic_id, uint32_t vector)
{
    return lapic_send_ipi_to_cpu(lapic_id, APIC_DM_STARTUP, vector);
}

void lapic_eoi(void)
{
    lapic_x1_write_reg(LAPIC_EOI, 1);
}

static void lapic_software_enable_lapic(void)
{
    lapic_x1_write_reg(LAPIC_SIVR, 0x1FF);
}

void lapic_software_disable(void)
{
    lapic_x1_write_reg(LAPIC_SIVR, 0xFF);
}

bool send_self_ipi(uint32_t vector)
{
    uint32_t icr_low = APIC_DEST_SELF|APIC_LEVEL_ASSERT|APIC_DM_FIXED|vector;
    uint64_t apic_base_msr = read_msr(MSR_APIC_BASE);

    if (!(apic_base_msr & LAPIC_ENABLED)) {
        return false;
    }

    if (apic_base_msr & LAPIC_X2_ENABLED) {
        lapic_x2_write_reg(LAPIC_SELF_IPI_REG, (uint64_t)vector);
    } else {
        //need wait in x1 APIC only.
        lapic_x1_wait_for_ipi();
        lapic_x1_write_reg(LAPIC_INTR_CMD_REG, icr_low);
    }

    return true;
}
