LOCAL_DIR := $(GET_LOCAL_DIR)

MODULE := $(LOCAL_DIR)

GLOBAL_INCLUDES += \
	$(LOCAL_DIR)/include

WITH_KERNEL_VM=1

ifeq ($(SUBARCH),x86-32)
MEMBASE ?= 0x00000000
KERNEL_BASE ?= 0x80000000
KERNEL_LOAD_OFFSET ?= 0x00200000
KERNEL_ASPACE_BASE ?= 0x80000000
KERNEL_ASPACE_SIZE ?= 0x7ff00000
USER_ASPACE_BASE   ?= 0
USER_ASPACE_SIZE   ?= 0x80000000
SUBARCH_DIR := $(LOCAL_DIR)/32
endif

ifeq ($(SUBARCH),x86-64)
GLOBAL_DEFINES += IS_64BIT=1
MEMBASE ?= 0
KERNEL_BASE ?= 0xffffffff80000000
KERNEL_LOAD_OFFSET ?= 0x00004000
KERNEL_ASPACE_BASE ?= 0xffffff8000000000UL # -512GB
KERNEL_ASPACE_SIZE ?= 0x0000008000000000UL
USER_ASPACE_BASE   ?= 0x0000000000000000UL
USER_ASPACE_SIZE   ?= 0x0000800000000000UL
SUBARCH_DIR := $(LOCAL_DIR)/64
endif

SUBARCH_BUILDDIR := $(call TOBUILDDIR,$(SUBARCH_DIR))

GLOBAL_DEFINES += \
	ARCH_$(SUBARCH)=1 \
	MEMBASE=$(MEMBASE) \
	KERNEL_BASE=$(KERNEL_BASE) \
	KERNEL_LOAD_OFFSET=$(KERNEL_LOAD_OFFSET) \
	KERNEL_ASPACE_BASE=$(KERNEL_ASPACE_BASE) \
	KERNEL_ASPACE_SIZE=$(KERNEL_ASPACE_SIZE) \
	SMP_MAX_CPUS=1 \
	X86_WITH_FPU=1

MODULE_SRCS += \
	$(SUBARCH_DIR)/start.S \
	$(SUBARCH_DIR)/asm.S \
	$(SUBARCH_DIR)/exceptions.S \
	$(SUBARCH_DIR)/mmu.c \
	$(SUBARCH_DIR)/ops.S \
	$(LOCAL_DIR)/arch.c \
	$(LOCAL_DIR)/cache.c \
	$(LOCAL_DIR)/faults.c \
	$(LOCAL_DIR)/gdt.S \
	$(LOCAL_DIR)/thread.c \
	$(LOCAL_DIR)/descriptor.c \
	$(LOCAL_DIR)/fpu.c \
	$(LOCAL_DIR)/local_apic.c

ifeq (true,$(call TOBOOL,$(STACK_PROTECTOR)))
MODULE_SRCS += \
	$(LOCAL_DIR)/stack_chk.c
endif

include $(LOCAL_DIR)/toolchain.mk

# set the default toolchain to x86 elf and set a #define
ifeq ($(SUBARCH),x86-32)
ifndef TOOLCHAIN_PREFIX
TOOLCHAIN_PREFIX := $(ARCH_x86_TOOLCHAIN_PREFIX)
endif
endif # SUBARCH x86-32

ifeq ($(SUBARCH),x86-64)
ifndef TOOLCHAIN_PREFIX
TOOLCHAIN_PREFIX := $(ARCH_x86_64_TOOLCHAIN_PREFIX)
endif
endif # SUBARCH x86-64

$(warning ARCH_x86_TOOLCHAIN_PREFIX = $(ARCH_x86_TOOLCHAIN_PREFIX))
$(warning ARCH_x86_64_TOOLCHAIN_PREFIX = $(ARCH_x86_64_TOOLCHAIN_PREFIX))
$(warning TOOLCHAIN_PREFIX = $(TOOLCHAIN_PREFIX))

LIBGCC := $(shell $(TOOLCHAIN_PREFIX)gcc $(CFLAGS) -print-libgcc-file-name)

cc-option = $(shell if test -z "`$(1) $(2) -S -o /dev/null -xc /dev/null 2>&1`"; \
	then echo "$(2)"; else echo "$(3)"; fi ;)

ifeq (true,$(call TOBOOL,$(STACK_PROTECTOR)))
GLOBAL_DEFINES += \
	STACK_PROTECTOR=1
GLOBAL_COMPILEFLAGS += -fstack-protector-strong
else
GLOBAL_COMPILEFLAGS += -fno-stack-protector
endif

ifeq (true,$(call TOBOOL,$(ASLR_OF_TA)))
GLOBAL_DEFINES += \
	ASLR_OF_TA=1
endif

GLOBAL_COMPILEFLAGS += -fasynchronous-unwind-tables
GLOBAL_COMPILEFLAGS += -gdwarf-2
GLOBAL_LDFLAGS += -z max-page-size=0x1000

ifeq ($(SUBARCH),x86-64)
KERNEL_COMPILEFLAGS += -falign-jumps=1
KERNEL_COMPILEFLAGS += -falign-loops=1
KERNEL_COMPILEFLAGS += -falign-functions=4
KERNEL_COMPILEFLAGS += -ffreestanding
KERNEL_COMPILEFLAGS += -mno-80387
KERNEL_COMPILEFLAGS += -mno-fp-ret-in-387
KERNEL_COMPILEFLAGS += -funit-at-a-time
KERNEL_COMPILEFLAGS += -mcmodel=kernel
KERNEL_COMPILEFLAGS += -mno-red-zone
KERNEL_COMPILEFLAGS += -mno-mmx -mno-3dnow -mno-avx -mno-avx2 -msoft-float
KERNEL_COMPILEFLAGS += -march=core2 -maccumulate-outgoing-args -mfentry
endif # SUBARCH x86-64

ARCH_OPTFLAGS := -O2

LINKER_SCRIPT += $(SUBARCH_BUILDDIR)/kernel.ld

# potentially generated files that should be cleaned out with clean make rule
GENERATED += $(SUBARCH_BUILDDIR)/kernel.ld

# rules for generating the linker scripts
$(SUBARCH_BUILDDIR)/kernel.ld: $(SUBARCH_DIR)/kernel.ld $(wildcard arch/*.ld)
	@echo generating $@
	@$(MKDIR)
	$(NOECHO)sed "s/%MEMBASE%/$(MEMBASE)/;s/%MEMSIZE%/$(MEMSIZE)/;s/%KERNEL_BASE%/$(KERNEL_BASE)/;s/%KERNEL_LOAD_OFFSET%/$(KERNEL_LOAD_OFFSET)/" < $< > $@.tmp
	@$(call TESTANDREPLACEFILE,$@.tmp,$@)

include make/module.mk
