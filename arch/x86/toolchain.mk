# x86-32 toolchain
ifeq ($(SUBARCH),x86-32)
ifndef ARCH_x86_TOOLCHAIN_INCLUDED
ARCH_x86_TOOLCHAIN_INCLUDED := 1

ifndef ARCH_x86_TOOLCHAIN_PREFIX
ARCH_x86_TOOLCHAIN_PREFIX := i386-elf-
FOUNDTOOL=$(shell which $(ARCH_x86_TOOLCHAIN_PREFIX)gcc)
endif

ifeq ($(FOUNDTOOL),)
$(error cannot find toolchain, please set ARCH_x86_TOOLCHAIN_PREFIX or add it to your path)
endif

endif
endif

# x86-64 toolchain
ifeq ($(SUBARCH),x86-64)
ifndef ARCH_x86_64_TOOLCHAIN_INCLUDED
ARCH_x86_64_TOOLCHAIN_INCLUDED := 1

ifeq ($(call TOBOOL,$(CLANGBUILD)),true)
ifndef ARCH_x86_64_TOOLCHAIN_PREFIX
ARCH_x86_64_TOOLCHAIN_PREFIX := x86_64-elf-
endif
else
ARCH_x86_64_TOOLCHAIN_PREFIX := x86_64-elf-
endif

FOUNDTOOL=$(shell which $(ARCH_x86_64_TOOLCHAIN_PREFIX)gcc)

ifeq ($(FOUNDTOOL),)
$(error cannot find toolchain, please set ARCH_x86_64_TOOLCHAIN_PREFIX or add it to your path)
endif

ifeq ($(call TOBOOL,$(CLANGBUILD)),true)

CLANG_X86_64_TARGET_SYS ?= linux
CLANG_X86_64_TARGET_ABI ?= gnu

CLANG_X86_64_AS_DIR := $(shell dirname $(shell dirname $(ARCH_x86_64_TOOLCHAIN_PREFIX)))

AS_PATH := $(wildcard $(CLANG_X86_64_AS_DIR)/*/bin/as)
ifeq ($(AS_PATH),)
$(error Could not find $(CLANG_X86_64_AS_DIR)/*/bin/as, did the directory structure change?)
endif

ARCH_x86_COMPILEFLAGS += -target x86_64-$(CLANG_X86_64_TARGET_SYS)-$(CLANG_X86_64_TARGET_ABI) \
                         --gcc-toolchain=$(CLANG_X86_64_AS_DIR)/

endif

endif
endif

