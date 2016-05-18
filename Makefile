SHELL := /usr/bin/env sh

# prints variables for debugging
print-%: ; @echo $($*)

# Disable builtin rules:
.SUFFIXES:

DEPS_DIR := $(HOME)/pyston_deps

SRC_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
BUILD_DIR := $(SRC_DIR)/build

LLVM_REVISION_FILE := llvm_revision.txt
LLVM_REVISION := $(shell cat $(LLVM_REVISION_FILE))

USE_CLANG  := 1
USE_CCACHE := 1
USE_DISTCC := 0

PYPY := pypy
CPYTHON := python

ENABLE_VALGRIND := 0

GDB := gdb
# If you followed the old install instructions:
# GCC_DIR := $(DEPS_DIR)/gcc-4.8.2-install
GCC_DIR := /usr
GTEST_DIR := $(DEPS_DIR)/gtest-1.7.0

USE_DEBUG_LIBUNWIND := 0

MAX_MEM_KB := 500000
MAX_DBG_MEM_KB := 500000

TEST_THREADS := 1

ERROR_LIMIT := 10
COLOR := 1

SELF_HOST := 0

VERBOSE := 0

ENABLE_INTEL_JIT_EVENTS := 0

CTAGS := ctags
ETAGS := ctags-exuberant -e

NINJA := ninja

CMAKE_DIR_DBG := $(BUILD_DIR)/Debug
CMAKE_DIR_DBG_TO_SRC := ../.. # Relative path from $(CAMKE_DIR_DBG) to $(SRC_DIR).  Not sure how to calculate this automatically.
CMAKE_DIR_RELEASE := $(BUILD_DIR)/Release
CMAKE_DIR_GCC := $(BUILD_DIR)/Debug-gcc
CMAKE_DIR_RELEASE_GCC := $(BUILD_DIR)/Release-gcc
CMAKE_DIR_RELEASE_GCC_PGO := $(BUILD_DIR)/Release-gcc-pgo
CMAKE_DIR_RELEASE_GCC_PGO_INSTRUMENTED := $(BUILD_DIR)/Release-gcc-pgo-instrumented
CMAKE_SETUP_DBG := $(CMAKE_DIR_DBG)/build.ninja
CMAKE_SETUP_RELEASE := $(CMAKE_DIR_RELEASE)/build.ninja

# Put any overrides in here:
-include Makefile.local


ifneq ($(SELF_HOST),1)
	PYTHON := $(CPYTHON)
	PYTHON_EXE_DEPS :=
else
	PYTHON := $(abspath ./pyston_dbg)
	PYTHON_EXE_DEPS := pyston_dbg
endif

TOOLS_DIR := ./tools
TEST_DIR := $(abspath ./test)
TESTS_DIR := $(abspath ./test/tests)

GPP := $(GCC_DIR)/bin/g++
GCC := $(GCC_DIR)/bin/gcc

ifeq ($(V),1)
	VERBOSE := 1
endif
ifeq ($(VERBOSE),1)
	VERB :=
	ECHO := @\#
else
	VERB := @
	ECHO := @ echo pyston:
endif

LLVM_TRUNK_SRC := $(DEPS_DIR)/llvm-trunk
LLVM_SRC := $(LLVM_TRUNK_SRC)
LLVM_INC_DBG := ./build/Debug/llvm

LLVM_BIN := ./build/Release/llvm/bin
LLVM_BIN_DBG := ./build/Debug/llvm/bin

LLVM_LINK_LIBS := core mcjit native bitreader bitwriter ipo irreader debuginfodwarf instrumentation
ifneq ($(ENABLE_INTEL_JIT_EVENTS),0)
LLVM_LINK_LIBS += inteljitevents
endif

NEED_OLD_JIT := $(shell if [ $(LLVM_REVISION) -le 216982 ]; then echo 1; else echo 0; fi )
ifeq ($(NEED_OLD_JIT),1)
	LLVM_LINK_LIBS += jit
endif

ifneq ($(wildcard /usr/local/include/llvm),)
# Global include files can screw up the build, since if llvm moves a header file,
# the compiler will silently fall back to the global one that still exists.
# These include files are persistent because llvm's "make uninstall" does *not*
# delete them if the uninstall command is run on a revision that didn't include
# those files.
# This could probably be handled (somehow blacklist this particular folder?),
# but for now just error out:
$(error "Error: global llvm include files detected")
endif

CLANG_EXE := $(LLVM_BIN)/clang
CLANGPP_EXE := $(LLVM_BIN)/clang++

COMMON_CFLAGS := -g -Werror -Wreturn-type -Wall -Wno-sign-compare -Wno-unused -Isrc -Ifrom_cpython/Include -fno-omit-frame-pointer
COMMON_CFLAGS += -Wextra -Wno-sign-compare
COMMON_CFLAGS += -Wno-unused-parameter # should use the "unused" attribute
COMMON_CXXFLAGS := $(COMMON_CFLAGS)
COMMON_CXXFLAGS += -std=c++11
COMMON_CXXFLAGS += -Woverloaded-virtual
COMMON_CXXFLAGS += -fexceptions -fno-rtti
COMMON_CXXFLAGS += -Wno-invalid-offsetof # allow the use of "offsetof", and we'll just have to make sure to only use it legally.
COMMON_CXXFLAGS += -DENABLE_INTEL_JIT_EVENTS=$(ENABLE_INTEL_JIT_EVENTS)
COMMON_CXXFLAGS += -I$(DEPS_DIR)/pypa-install/include
COMMON_CXXFLAGS += -I$(DEPS_DIR)/lz4-install/include

ifeq ($(ENABLE_VALGRIND),0)
	COMMON_CXXFLAGS += -DNVALGRIND
	VALGRIND := false
	CMAKE_VALGRIND :=
else
	COMMON_CXXFLAGS += -I$(DEPS_DIR)/valgrind-3.10.0/include
	VALGRIND := VALGRIND_LIB=$(DEPS_DIR)/valgrind-3.10.0-install/lib/valgrind $(DEPS_DIR)/valgrind-3.10.0-install/bin/valgrind
	CMAKE_VALGRIND := -DENABLE_VALGRIND=ON -DVALGRIND_DIR=$(DEPS_DIR)/valgrind-3.10.0-install/
endif

COMMON_CXXFLAGS += -DGITREV=$(shell git rev-parse HEAD | head -c 12) -DLLVMREV=$(LLVM_REVISION)

# Use our "custom linker" that calls gold if available
COMMON_LDFLAGS := -B$(TOOLS_DIR)/build_system -L/usr/local/lib -lpthread -lm -lunwind -llzma -L$(DEPS_DIR)/gcc-4.8.2-install/lib64 -lreadline -lgmp -lssl -lcrypto -lsqlite3
COMMON_LDFLAGS += $(DEPS_DIR)/pypa-install/lib/libpypa.a
COMMON_LDFLAGS += $(DEPS_DIR)/lz4-install/lib/liblz4.a

# Conditionally add libtinfo if available - otherwise nothing will be added
COMMON_LDFLAGS += `pkg-config tinfo 2>/dev/null && pkg-config tinfo --libs || echo ""`

# Make sure that we put all symbols in the dynamic symbol table so that MCJIT can load them;
# TODO should probably do the linking before MCJIT
COMMON_LDFLAGS += -Wl,-E

# We get multiple shared libraries (libstdc++, libgcc_s) from the gcc installation:
ifneq ($(GCC_DIR),/usr)
	COMMON_LDFLAGS += -Wl,-rpath $(GCC_DIR)/lib64
endif

ifneq ($(USE_DEBUG_LIBUNWIND),0)
	COMMON_LDFLAGS += -L$(DEPS_DIR)/libunwind-trunk-debug-install/lib

	# libunwind's include files warn on -Wextern-c-compat, so turn that off;
	# ideally would just turn it off for header files in libunwind, maybe by
	# having an internal libunwind.h that pushed/popped the diagnostic state,
	# but it doesn't seem like that important a warning so just turn it off.
	COMMON_CXXFLAGS += -I$(DEPS_DIR)/libunwind-trunk-debug-install/include -Wno-extern-c-compat
else
	COMMON_LDFLAGS += -L$(DEPS_DIR)/libunwind-trunk-install/lib
	COMMON_CXXFLAGS += -I$(DEPS_DIR)/libunwind-trunk-install/include -Wno-extern-c-compat
endif


EXTRA_CXXFLAGS ?=
CXXFLAGS_DBG := $(LLVM_CXXFLAGS) $(COMMON_CXXFLAGS) -O0 -DBINARY_SUFFIX= -DBINARY_STRIPPED_SUFFIX=_stripped $(EXTRA_CXXFLAGS)
CXXFLAGS_PROFILE = $(LLVM_PROFILE_CXXFLAGS) $(COMMON_CXXFLAGS) -pg -O3 -DNDEBUG -DNVALGRIND -DBINARY_SUFFIX=_release -DBINARY_STRIPPED_SUFFIX= -fno-function-sections $(EXTRA_CXXFLAGS)
CXXFLAGS_RELEASE := $(LLVM_RELEASE_CXXFLAGS) $(COMMON_CXXFLAGS) -O3 -fstrict-aliasing -DNDEBUG -DNVALGRIND -DBINARY_SUFFIX=_release -DBINARY_STRIPPED_SUFFIX= $(EXTRA_CXXFLAGS)

LDFLAGS := $(LLVM_LDFLAGS) $(COMMON_LDFLAGS)
LDFLAGS_DEBUG := $(LLVM_DEBUG_LDFLAGS) $(COMMON_LDFLAGS)
LDFLAGS_PROFILE = $(LLVM_PROFILE_LDFLAGS) -pg $(COMMON_LDFLAGS)
LDFLAGS_RELEASE := $(LLVM_RELEASE_LDFLAGS) $(COMMON_LDFLAGS)
# Can't add this, because there are functions in the compiler that look unused but are hooked back from the runtime:
# LDFLAGS_RELEASE += -Wl,--gc-sections


BUILD_SYSTEM_DEPS := Makefile Makefile.local $(wildcard build_system/*)
CLANG_DEPS := $(CLANGPP_EXE)

# settings to make clang and ccache play nicely:
CLANG_CCACHE_FLAGS := -Qunused-arguments
CLANG_EXTRA_FLAGS := -enable-tbaa -ferror-limit=$(ERROR_LIMIT) $(CLANG_CCACHE_FLAGS)
ifeq ($(COLOR),1)
	CLANG_EXTRA_FLAGS += -fcolor-diagnostics
else
	CLANG_EXTRA_FLAGS += -fno-color-diagnostics
endif
CLANGFLAGS := $(CXXFLAGS_DBG) $(CLANG_EXTRA_FLAGS)
CLANGFLAGS_RELEASE := $(CXXFLAGS_RELEASE) $(CLANG_EXTRA_FLAGS)

EXT_CFLAGS := $(COMMON_CFLAGS) -fPIC -Wimplicit -O2 -Ifrom_cpython/Include
EXT_CFLAGS += -Wno-missing-field-initializers
EXT_CFLAGS += -Wno-tautological-compare -Wno-type-limits -Wno-strict-aliasing
EXT_CFLAGS_PROFILE := $(EXT_CFLAGS) -pg
ifneq ($(USE_CLANG),0)
	EXT_CFLAGS += $(CLANG_EXTRA_FLAGS)
endif

# Extra flags to enable soon:
CLANGFLAGS += -Wno-sign-conversion -Wnon-virtual-dtor -Winit-self -Wimplicit-int -Wmissing-include-dirs -Wstrict-overflow=5 -Wundef -Wpointer-arith -Wtype-limits -Wwrite-strings -Wempty-body -Waggregate-return -Wstrict-prototypes -Wold-style-definition -Wmissing-field-initializers -Wredundant-decls -Wnested-externs -Winline -Wint-to-pointer-cast -Wpointer-to-int-cast -Wlong-long -Wvla
# Want this one but there's a lot of places that I haven't followed it:
# CLANGFLAGS += -Wold-style-cast
# llvm headers fail on this one:
# CLANGFLAGS += -Wswitch-enum
# Not sure about these:
# CLANGFLAGS += -Wbad-function-cast -Wcast-qual -Wcast-align -Wmissing-prototypes -Wunreachable-code -Wfloat-equal -Wunused -Wunused-variable
# Or everything:
# CLANGFLAGS += -Weverything -Wno-c++98-compat-pedantic -Wno-shadow -Wno-padded -Wno-zero-length-array

CXX := $(GPP)
CC := $(GCC)
CXX_PROFILE := $(GPP)
CC_PROFILE := $(GCC)
CLANG_CXX := $(CLANGPP_EXE)

ifneq ($(USE_CLANG),0)
	CXX := $(CLANG_CXX)
	CC := $(CLANG_EXE)

	CXXFLAGS_DBG := $(CLANGFLAGS)
	CXXFLAGS_RELEASE := $(CLANGFLAGS_RELEASE)

	BUILD_SYSTEM_DEPS := $(BUILD_SYSTEM_DEPS) $(CLANG_DEPS)
endif

ifeq ($(USE_CCACHE),1)
	CC := ccache $(CC)
	CXX := ccache $(CXX)
	CXX_PROFILE := ccache $(CXX_PROFILE)
	CLANG_CXX := ccache $(CLANG_CXX)
	CXX_ENV += CCACHE_CPP2=yes
	CC_ENV += CCACHE_CPP2=yes
	ifeq ($(USE_DISTCC),1)
		CXX_ENV += CCACHE_PREFIX=distcc
	endif
else ifeq ($(USE_DISTCC),1)
	CXX := distcc $(CXX)
	CXX_PROFILE := distcc $(CXX_PROFILE)
	CLANG_CXX := distcc $(CLANG_CXX)
endif
CXX := $(CXX_ENV) $(CXX)
CXX_PROFILE := $(CXX_ENV) $(CXX_PROFILE)
CC := $(CC_ENV) $(CC)
CLANG_CXX := $(CXX_ENV) $(CLANG_CXX)

BASE_SRCS := $(wildcard src/codegen/*.cpp) $(wildcard src/asm_writing/*.cpp) $(wildcard src/codegen/irgen/*.cpp) $(wildcard src/codegen/opt/*.cpp) $(wildcard src/analysis/*.cpp) $(wildcard src/core/*.cpp) src/codegen/profiling/profiling.cpp src/codegen/profiling/dumprof.cpp $(wildcard src/runtime/*.cpp) $(wildcard src/runtime/builtin_modules/*.cpp) $(wildcard src/gc/*.cpp) $(wildcard src/capi/*.cpp)
MAIN_SRCS := $(BASE_SRCS) src/jit.cpp
STDLIB_SRCS := $(wildcard src/runtime/inline/*.cpp)
SRCS := $(MAIN_SRCS) $(STDLIB_SRCS)
STDLIB_OBJS := stdlib.bc.o stdlib.stripped.bc.o
STDLIB_RELEASE_OBJS := stdlib.release.bc.o
ASM_SRCS := $(wildcard src/runtime/*.S)

STDMODULE_SRCS := \
	errnomodule.c \
	shamodule.c \
	sha256module.c \
	sha512module.c \
	_math.c \
	mathmodule.c \
	md5.c \
	md5module.c \
	_randommodule.c \
	_sre.c \
	operator.c \
	binascii.c \
	pwdmodule.c \
	posixmodule.c \
	_struct.c \
	datetimemodule.c \
	_functoolsmodule.c \
	_collectionsmodule.c \
	itertoolsmodule.c \
	resource.c \
	signalmodule.c \
	selectmodule.c \
	fcntlmodule.c \
	threadmodule.c \
	timemodule.c \
	arraymodule.c \
	zlibmodule.c \
	_codecsmodule.c \
	socketmodule.c \
	unicodedata.c \
	_weakref.c \
	cStringIO.c \
	_io/bufferedio.c \
	_io/bytesio.c \
	_io/fileio.c \
	_io/iobase.c \
	_io/_iomodule.c \
	_io/stringio.c \
	_io/textio.c \
	zipimport.c \
	_csv.c \
	_ssl.c \
	getpath.c \
	_sqlite/cache.c \
	_sqlite/connection.c \
	_sqlite/cursor.c \
	_sqlite/microprotocols.c \
	_sqlite/module.c \
	_sqlite/prepare_protocol.c \
	_sqlite/row.c \
	_sqlite/statement.c \
	_sqlite/util.c \
	stropmodule.c \
	$(EXTRA_STDMODULE_SRCS)

STDOBJECT_SRCS := \
	structseq.c \
	capsule.c \
	stringobject.c \
	exceptions.c \
	floatobject.c \
	unicodeobject.c \
	unicodectype.c \
	bytearrayobject.c \
	bytes_methods.c \
	weakrefobject.c \
	memoryobject.c \
	iterobject.c \
	bufferobject.c \
	cobject.c \
	dictproxy.c \
	$(EXTRA_STDOBJECT_SRCS)

STDPYTHON_SRCS := \
	pyctype.c \
	getargs.c \
	formatter_string.c \
	pystrtod.c \
	dtoa.c \
	formatter_unicode.c \
	structmember.c \
	marshal.c \
	mystrtoul.c \
	$(EXTRA_STDPYTHON_SRCS)

STDPARSER_SRCS := \
	myreadline.c

FROM_CPYTHON_SRCS := $(addprefix from_cpython/Modules/,$(STDMODULE_SRCS)) $(addprefix from_cpython/Objects/,$(STDOBJECT_SRCS)) $(addprefix from_cpython/Python/,$(STDPYTHON_SRCS)) $(addprefix from_cpython/Parser/,$(STDPARSER_SRCS))

# The stdlib objects have slightly longer dependency chains,
# so put them first in the list:
OBJS := $(STDLIB_OBJS) $(SRCS:.cpp=.o) $(FROM_CPYTHON_SRCS:.c=.o) $(ASM_SRCS)
ASTPRINT_OBJS := $(STDLIB_OBJS) $(BASE_SRCS:.cpp=.o) $(FROM_CPYTHON_SRCS:.c=.o) $(ASM_SRCS)
PROFILE_OBJS := $(STDLIB_RELEASE_OBJS) $(MAIN_SRCS:.cpp=.prof.o) $(STDLIB_SRCS:.cpp=.release.o) $(FROM_CPYTHON_SRCS:.c=.prof.o) $(ASM_SRCS)
OPT_OBJS := $(STDLIB_RELEASE_OBJS) $(SRCS:.cpp=.release.o) $(FROM_CPYTHON_SRCS:.c=.release.o) $(ASM_SRCS)

OPTIONAL_SRCS := src/codegen/profiling/oprofile.cpp src/codegen/profiling/pprof.cpp
TOOL_SRCS := $(wildcard $(TOOLS_DIR)/*.cpp)

UNITTEST_DIR := $(TEST_DIR)/unittests
UNITTEST_SRCS := $(wildcard $(UNITTEST_DIR)/*.cpp)

NONSTDLIB_SRCS := $(MAIN_SRCS) $(OPTIONAL_SRCS) $(TOOL_SRCS) $(UNITTEST_SRCS)

.DEFAULT_GOAL := small_all

# The set of dependencies (beyond the executable) required to do `make run_foo`.
# ext_pyston (building test/test_extension) is required even in cmake mode since
# we manually add test/test_extension to the path
RUN_DEPS := ext_pyston

# The set of dependencies (beyond the executable) required to do `make check` / `make check_foo`.
# The tester bases all paths based on the executable, so in cmake mode we need to have cmake
# build all of the shared modules.
check-deps:
	$(NINJA) -C $(CMAKE_DIR_DBG) check-deps

.PHONY: small_all
small_all: pyston_dbg $(RUN_DEPS)

.PHONY: all _all
# all: llvm
	# @# have to do this in a recursive make so that dependency is enforced:
	# $(MAKE) pyston_all
# all: pyston_dbg pyston_release pyston_oprof pyston_prof $(OPTIONAL_SRCS:.cpp=.o) ext_python ext_pyston
all: pyston_dbg pyston_release pyston_gcc unittests check-deps $(RUN_DEPS)

ALL_HEADERS := $(wildcard src/*/*.h) $(wildcard src/*/*/*.h) $(wildcard from_cpython/Include/*.h)
tags: $(SRCS) $(OPTIONAL_SRCS) $(FROM_CPYTHON_SRCS) $(ALL_HEADERS)
	$(ECHO) Calculating tags...
	$(VERB) $(CTAGS) -I noexcept -I noexcept+ -I PYSTON_NOEXCEPT -I STOLEN -I BORROWED $^

TAGS: $(SRCS) $(OPTIONAL_SRCS) $(FROM_CPYTHON_SRCS) $(ALL_HEADERS)
	$(ECHO) Calculating TAGS...
	$(VERB) $(ETAGS) $^

NON_ENTRY_OBJS := $(filter-out src/jit.o,$(OBJS))

define add_unittest
$(eval \
.PHONY: $1_unittest
$1_unittest:
	$(NINJA) -C $(CMAKE_DIR_DBG) $1_unittest $(NINJAFLAGS)
	ln -sf $(CMAKE_DIR_DBG)/$1_unittest .
dbg_$1_unittests: $1_unittest
	zsh -c 'ulimit -m $(MAX_MEM_KB); time $(GDB) $(GDB_CMDS) --args ./$1_unittest --gtest_break_on_failure $(ARGS)'
unittests:: $1_unittest
run_$1_unittests: $1_unittest
	zsh -c 'ulimit -m $(MAX_MEM_KB); time ./$1_unittest $(ARGS)'
run_unittests:: run_$1_unittests
)
endef

GDB_CMDS := $(GDB_PRE_CMDS) --ex "source pyston_gdbinit.txt" --ex "run" --ex "bt 20" $(GDB_POST_CMDS)
BR ?=
ARGS ?=
ifneq ($(BR),)
	override GDB_CMDS := --ex "break $(BR)" $(GDB_CMDS)
endif
$(call add_unittest,gc)
$(call add_unittest,analysis)


define checksha
	test "$$($1 | sha1sum)" = "$2  -"
endef

.PHONY: analyze
analyze:
	$(MAKE) clean
	PATH=$$PATH:$(DEPS_DIR)/llvm-trunk/tools/clang/tools/scan-view $(DEPS_DIR)/llvm-trunk/tools/clang/tools/scan-build/scan-build \
		 --use-analyzer $(CLANGPP_EXE) --use-c++ $(CLANGPP_EXE) -V \
		$(MAKE) pyston_dbg USE_DISTCC=0 USE_CCACHE=0

.PHONY: lint cpplint
lint: $(PYTHON_EXE_DEPS)
	$(ECHO) linting...
	$(VERB) cd src && $(PYTHON) ../tools/lint.py
cpplint:
	$(VERB) $(PYTHON) $(TOOLS_DIR)/cpplint.py --filter=-whitespace,-build/header_guard,-build/include_order,-readability/todo $(SRCS)

.PHONY: check
check:
	@# These are ordered roughly in decreasing order of (chance will expose issue) / (time to run test)

	$(MAKE) pyston_dbg check-deps
	( cd $(CMAKE_DIR_DBG) && ctest -V )

	$(MAKE) pyston_release
	( cd $(CMAKE_DIR_RELEASE) && ctest -V -R pyston )

	echo "All tests passed"

# A stripped down set of tests, meant as a quick smoke test to run before submitting a PR and having
# Travis-CI do the full test.
.PHONY: quick_check
quick_check:
	$(MAKE) pyston_dbg
	$(MAKE) check-deps
	( cd $(CMAKE_DIR_DBG) && ctest -V -R '^(check-format|unittests|pyston_defaults_tests|pyston_defaults_cpython)$$' )


Makefile.local:
	echo "Creating default Makefile.local"
	which ninja-build >/dev/null && echo "NINJA := ninja-build" >> Makefile.local

llvm_up:
	$(CPYTHON) $(TOOLS_DIR)/git_svn_gotorev.py $(LLVM_SRC) $(LLVM_REVISION) ./llvm_patches
	$(CPYTHON) $(TOOLS_DIR)/git_svn_gotorev.py $(LLVM_SRC)/tools/clang $(LLVM_REVISION) ./clang_patches

## TOOLS:

$(TOOLS_DIR)/demangle: $(TOOLS_DIR)/demangle.cpp $(BUILD_SYSTEM_DEPS)
	$(CXX) $< -o $@
.PHONY: demangle
demangle: $(TOOLS_DIR)/demangle
	$(TOOLS_DIR)/demangle $(ARGS)

$(TOOLS_DIR)/mcjitcache: $(TOOLS_DIR)/mcjitcache.o $(LLVM_DEPS) $(BUILD_SYSTEM_DEPS)
	$(CXX) $< $(LDFLAGS) -o $@
# Build a version of mcjitcache off the llvm_release repo mostly to avoid a dependence of the opt builds
# on the llvm_quick build.
$(TOOLS_DIR)/mcjitcache_release: $(TOOLS_DIR)/mcjitcache.release.o $(LLVM_RELEASE_DEPS) $(BUILD_SYSTEM_DEPS)
	$(CXX) $< $(LDFLAGS_RELEASE) -o $@

$(TOOLS_DIR)/publicize: $(TOOLS_DIR)/publicize.o $(LLVM_DEPS) $(BUILD_SYSTEM_DEPS)
	$(ECHO) Linking $(TOOLS_DIR)/publicize
	$(VERB) $(CXX) $< $(LDFLAGS) -o $@ -lLLVMBitWriter

$(TOOLS_DIR)/publicize_release: $(TOOLS_DIR)/publicize.release.o $(LLVM_RELEASE_DEPS) $(BUILD_SYSTEM_DEPS)
	$(ECHO) Linking $(TOOLS_DIR)/publicize_release
	$(VERB) $(CXX) $< $(LDFLAGS_RELEASE) -o $@ -lLLVMBitWriter

$(TOOLS_DIR)/astprint: $(TOOLS_DIR)/astprint.cpp $(BUILD_SYSTEM_DEPS) $(LLVM_DEPS) $(ASTPRINT_OBJS)
	$(ECHO) Linking $(TOOLS_DIR)/astprint
	$(VERB) $(CXX) $< -o $@ $(LLVM_LIB_DEPS) $(ASTPRINT_OBJS) $(LDFLAGS) $(STDLIB_SRCS:.cpp=.o) $(CXXFLAGS_DBG)

.PHONY: astprint astcompare

astprint: $(TOOLS_DIR)/astprint

astcompare: astprint
	$(ECHO) Running libpypa vs CPython AST result comparison test
	$(TOOLS_DIR)/astprint_test.sh && echo "Success" || echo "Failure"

## END OF TOOLS


CODEGEN_SRCS := $(wildcard src/codegen/*.cpp) $(wildcard src/codegen/*/*.cpp)

# args: suffix (ex: ".release"), CXXFLAGS
define make_compile_config
$(eval \
$$(NONSTDLIB_SRCS:.cpp=$1.o): CXXFLAGS:=$2
$$(SRCS:.cpp=$1.o.bc): CXXFLAGS:=$2

## Need to set CXXFLAGS so that this rule doesn't inherit the '-include' rule from the
## thing that's calling it.  At the same time, also filter out "-DGITREV=foo".
%$1.h.pch: CXXFLAGS:=$(filter-out -DGITREV%,$(2))
%$1.h.pch: %.h $$(BUILD_SYSTEM_DEPS)
	$$(ECHO) Compiling $$@
	$$(VERB) rm -f $$@-*
	$$(VERB) $$(CLANGPP_EXE) $$(CXXFLAGS) -MMD -MP -MF $$(patsubst %.pch,%.d,$$@) -x c++-header $$< -o $$@
$$(CODEGEN_SRCS:.cpp=$1.o): CXXFLAGS += -include src/codegen/irgen$1.h
$$(CODEGEN_SRCS:.cpp=$1.o): src/codegen/irgen$1.h.pch

$$(NONSTDLIB_SRCS:.cpp=$1.o): %$1.o: %.cpp $$(BUILD_SYSTEM_DEPS)
	$$(ECHO) Compiling $$@
	$$(VERB) $$(CXX) $$(CXXFLAGS) -MMD -MP -MF $$(patsubst %.o,%.d,$$@) $$< -c -o $$@

# For STDLIB sources, first compile to bitcode:
$$(STDLIB_SRCS:.cpp=$1.o.bc): %$1.o.bc: %.cpp $$(BUILD_SYSTEM_DEPS) $$(CLANG_DEPS)
	$$(ECHO) Compiling $$@
	$$(VERB) $$(CLANG_CXX) $$(CXXFLAGS) $$(CLANG_EXTRA_FLAGS) -MMD -MP -MF $$(patsubst %.bc,%.d,$$@) $$< -c -o $$@ -emit-llvm -g

stdlib$1.unopt.bc: $$(STDLIB_SRCS:.cpp=$1.o.pub.bc)
	$$(ECHO) Linking $$@
	$$(VERB) $$(LLVM_BIN)/llvm-link $$^ -o $$@

)
endef

PASS_SRCS := codegen/opt/aa.cpp
PASS_OBJS := $(PASS_SRCS:.cpp=.standalone.o)

%.o: %.cpp $(CMAKE_SETUP_DBG)
	$(NINJA) -C $(CMAKE_DIR_DBG) src/CMakeFiles/PYSTON_OBJECTS.dir/$(patsubst src/%.o,%.cpp.o,$@) $(NINJAFLAGS)
%.release.o: %.cpp $(CMAKE_SETUP_RELEASE)
	$(NINJA) -C $(CMAKE_DIR_RELEASE) src/CMakeFiles/PYSTON_OBJECTS.dir/$(patsubst src/%.release.o,%.cpp.o,$@) $(NINJAFLAGS)

$(UNITTEST_SRCS:.cpp=.o): CXXFLAGS += -isystem $(GTEST_DIR)/include

$(PASS_SRCS:.cpp=.standalone.o): %.standalone.o: %.cpp $(BUILD_SYSTEM_DEPS)
	$(ECHO) Compiling $@
	$(VERB) $(CXX) $(CXXFLAGS_DBG) -DSTANDALONE -MMD -MP -MF $(patsubst %.o,%.d,$@) $< -c -o $@
$(NONSTDLIB_SRCS:.cpp=.prof.o): %.prof.o: %.cpp $(BUILD_SYSTEM_DEPS)
	$(ECHO) Compiling $@
	$(VERB) $(CXX_PROFILE) $(CXXFLAGS_PROFILE) -MMD -MP -MF $(patsubst %.o,%.d,$@) $< -c -o $@

# Then, publicize symbols:
%.pub.bc: %.bc $(TOOLS_DIR)/publicize
	$(ECHO) Publicizing $<
	$(VERB) $(TOOLS_DIR)/publicize $< -o $@

# Then, compile the publicized bitcode into normal .o files
%.o: %.o.pub.bc $(BUILD_SYSTEM_DEPS) $(CLANG_DEPS)
	$(ECHO) Compiling bitcode to $@
	$(VERB) $(LLVM_BIN)/clang $(CLANGFLAGS) -O3 -c $< -o $@



passes.so: $(PASS_OBJS) $(BUILD_SYSTEM_DEPS)
	$(CXX) -shared $(PASS_OBJS) -o $@ -shared -rdynamic
test_opt: passes.so
	$(LLVM_BUILD)/Release+Asserts/bin/opt -load passes.so test.ll -S -o test.opt.ll $(ARGS)
test_dbg_opt: passes.so
	$(GDB) --args $(LLVM_BUILD)/Release+Asserts/bin/opt -O3 -load passes.so test.ll -S -o test.opt.ll $(ARGS)


# Optimize and/or strip it:
stdlib.bc: OPT_OPTIONS=-O3
stdlib.release.bc: OPT_OPTIONS=-O3 -strip-debug
.PRECIOUS: %.bc %.stripped.bc
%.bc: %.unopt.bc
	$(ECHO) Optimizing $< -\> $@
	$(VERB) $(LLVM_BIN)/opt $(OPT_OPTIONS) $< -o $@
%.stripped.bc: %.bc
	$(ECHO) Stripping $< -\> $@
	$(VERB) $(LLVM_BIN)/opt -strip-debug $< -o $@

# Then do "ld -b binary" to create a .o file for embedding into the executable
# $(STDLIB_OBJS) $(STDLIB_RELEASE_OBJS): %.o: % $(BUILD_SYSTEM_DEPS)
stdli%.bc.o: stdli%.bc $(BUILD_SYSTEM_DEPS)
	$(ECHO) Embedding $<
	$(VERB) ld -r -b binary $< -o $@

# Optionally, disassemble the bitcode files:
%.ll: %.bc
	$(LLVM_BIN)/llvm-dis $<

# Not used currently, but here's how to pre-jit the stdlib bitcode:
%.release.cache: %.release.bc mcjitcache_release
	./mcjitcache_release -p $< -o $@
%.cache: %.bc mcjitcache
	./mcjitcache -p $< -o $@

# args: output suffx (ex: _release), objects to link, LDFLAGS, other deps
define link
$(eval \
pyston$1: $2 $4
	$$(ECHO) Linking $$@
	$$(VERB) $$(CXX) $2 $3 -o $$@
)
endef


# Finally, link it all together:
$(call link,_grwl,stdlib.grwl.bc.o $(SRCS:.cpp=.grwl.o),$(LDFLAGS_RELEASE),$(LLVM_RELEASE_DEPS))
$(call link,_grwl_dbg,stdlib.grwl_dbg.bc.o $(SRCS:.cpp=.grwl_dbg.o),$(LDFLAGS),$(LLVM_DEPS))
$(call link,_nosync,stdlib.nosync.bc.o $(SRCS:.cpp=.nosync.o),$(LDFLAGS_RELEASE),$(LLVM_RELEASE_DEPS))
pyston_oprof: $(OPT_OBJS) src/codegen/profiling/oprofile.o $(LLVM_DEPS)
	$(ECHO) Linking $@
	$(VERB) $(CXX) $(OPT_OBJS) src/codegen/profiling/oprofile.o $(LDFLAGS_RELEASE) -lopagent -o $@
pyston_pprof: $(OPT_OBJS) src/codegen/profiling/pprof.release.o $(LLVM_DEPS)
	$(ECHO) Linking $@
	$(VERB) $(CXX) $(OPT_OBJS) src/codegen/profiling/pprof.release.o $(LDFLAGS_RELEASE) -lprofiler -o $@
pyston_prof: $(PROFILE_OBJS) $(LLVM_DEPS)
	$(ECHO) Linking $@
	$(VERB) $(CXX) $(PROFILE_OBJS) $(LDFLAGS) -pg -o $@
pyston_profile: $(PROFILE_OBJS) $(LLVM_PROFILE_DEPS)
	$(ECHO) Linking $@
	$(VERB) $(CXX) $(PROFILE_OBJS) $(LDFLAGS_PROFILE) -o $@

clang_check:
	@clang --version >/dev/null || (echo "clang not available"; false)

cmake_check:
	@cmake --version >/dev/null || (echo "cmake not available"; false)
	@$(NINJA) --version >/dev/null || (echo "ninja not available"; false)

COMMON_CMAKE_OPTIONS := $(SRC_DIR) -DTEST_THREADS=$(TEST_THREADS) $(CMAKE_VALGRIND) -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -GNinja

.PHONY: cmake_check clang_check
$(CMAKE_SETUP_DBG):
	@$(MAKE) cmake_check
	@$(MAKE) clang_check
	@mkdir -p $(CMAKE_DIR_DBG)
	cd $(CMAKE_DIR_DBG); CC='clang' CXX='clang++' cmake $(COMMON_CMAKE_OPTIONS) -DCMAKE_BUILD_TYPE=Debug
$(CMAKE_SETUP_RELEASE):
	@$(MAKE) cmake_check
	@$(MAKE) clang_check
	@mkdir -p $(CMAKE_DIR_RELEASE)
	cd $(CMAKE_DIR_RELEASE); CC='clang' CXX='clang++' cmake $(COMMON_CMAKE_OPTIONS) -DCMAKE_BUILD_TYPE=Release

# Shared modules (ie extension modules that get built using pyston on setup.py) that we will ask CMake
# to build.  You can flip this off to allow builds to continue even if self-hosting the sharedmods would fail.
CMAKE_SHAREDMODS := sharedmods ext_pyston

.PHONY: pyston_dbg pyston_release
pyston_dbg: $(CMAKE_SETUP_DBG)
	$(NINJA) -C $(CMAKE_DIR_DBG) pyston copy_stdlib copy_libpyston $(CMAKE_SHAREDMODS) ext_cpython $(NINJAFLAGS)
	ln -sf $(CMAKE_DIR_DBG)/pyston $@
pyston_release: $(CMAKE_SETUP_RELEASE)
	$(NINJA) -C $(CMAKE_DIR_RELEASE) pyston copy_stdlib copy_libpyston $(CMAKE_SHAREDMODS) ext_cpython $(NINJAFLAGS)
	ln -sf $(CMAKE_DIR_RELEASE)/pyston $@

CMAKE_SETUP_GCC := $(CMAKE_DIR_GCC)/build.ninja
$(CMAKE_SETUP_GCC):
	@$(MAKE) cmake_check
	@mkdir -p $(CMAKE_DIR_GCC)
	cd $(CMAKE_DIR_GCC); CC='$(GCC)' CXX='$(GPP)' cmake $(COMMON_CMAKE_OPTIONS) -DCMAKE_BUILD_TYPE=Debug
.PHONY: pyston_gcc
pyston_gcc: $(CMAKE_SETUP_GCC)
	$(NINJA) -C $(CMAKE_DIR_GCC) pyston copy_stdlib copy_libpyston $(CMAKE_SHAREDMODS) ext_cpython $(NINJAFLAGS)
	ln -sf $(CMAKE_DIR_GCC)/pyston $@

CMAKE_SETUP_RELEASE_GCC := $(CMAKE_DIR_RELEASE_GCC)/build.ninja
$(CMAKE_SETUP_RELEASE_GCC):
	@$(MAKE) cmake_check
	@mkdir -p $(CMAKE_DIR_RELEASE_GCC)
	cd $(CMAKE_DIR_RELEASE_GCC); CC='$(GCC)' CXX='$(GPP)' cmake $(COMMON_CMAKE_OPTIONS)  -DCMAKE_BUILD_TYPE=Release
.PHONY: pyston_release_gcc
pyston_release_gcc: $(CMAKE_SETUP_RELEASE_GCC)
	$(NINJA) -C $(CMAKE_DIR_RELEASE_GCC) pyston copy_stdlib copy_libpyston $(CMAKE_SHAREDMODS) ext_cpython $(NINJAFLAGS)
	ln -sf $(CMAKE_DIR_RELEASE_GCC)/pyston $@


# GCC PGO build
CMAKE_SETUP_RELEASE_GCC_PGO := $(CMAKE_DIR_RELEASE_GCC_PGO)/build.ninja
$(CMAKE_SETUP_RELEASE_GCC_PGO):
	@$(MAKE) cmake_check
	@mkdir -p $(CMAKE_DIR_RELEASE_GCC_PGO)
	cd $(CMAKE_DIR_RELEASE_GCC_PGO); CC='$(GCC)' CXX='$(GPP)' cmake $(COMMON_CMAKE_OPTIONS) -DCMAKE_BUILD_TYPE=Release -DENABLE_PGO=ON -DPROFILE_STATE=use
.PHONY: pyston_release_gcc_pgo
pyston_release_gcc_pgo: $(CMAKE_SETUP_RELEASE_GCC_PGO) $(CMAKE_DIR_RELEASE_GCC_PGO)/.trained
	$(NINJA) -C $(CMAKE_DIR_RELEASE_GCC_PGO) pyston copy_stdlib copy_libpyston $(CMAKE_SHAREDMODS) ext_cpython $(NINJAFLAGS)
	ln -sf $(CMAKE_DIR_RELEASE_GCC_PGO)/pyston $@

CMAKE_SETUP_RELEASE_GCC_PGO_INSTRUMENTED := $(CMAKE_DIR_RELEASE_GCC_PGO_INSTRUMENTED)/build.ninja
$(CMAKE_SETUP_RELEASE_GCC_PGO_INSTRUMENTED):
	@$(MAKE) cmake_check
	@mkdir -p $(CMAKE_DIR_RELEASE_GCC_PGO_INSTRUMENTED)
	cd $(CMAKE_DIR_RELEASE_GCC_PGO_INSTRUMENTED); CC='$(GCC)' CXX='$(GPP)' cmake $(COMMON_CMAKE_OPTIONS) -DCMAKE_BUILD_TYPE=Release -DENABLE_PGO=ON -DPROFILE_STATE=generate -DPROFILE_DIR=$(CMAKE_DIR_RELEASE_GCC_PGO)

.PHONY: pyston_release_gcc_pgo_instrumented
pyston_release_gcc_pgo_instrumented: $(CMAKE_SETUP_RELEASE_GCC_PGO_INSTRUMENTED)
	$(NINJA) -C $(CMAKE_DIR_RELEASE_GCC_PGO_INSTRUMENTED) pyston copy_stdlib copy_libpyston $(CMAKE_SHAREDMODS) ext_cpython $(NINJAFLAGS)
	ln -sf $(CMAKE_DIR_RELEASE_GCC_PGO_INSTRUMENTED)/pyston $@

PROFILE_TARGET := ./pyston $(SRC_DIR)/minibenchmarks/combined.py

$(CMAKE_DIR_RELEASE_GCC_PGO)/.trained: pyston_release_gcc_pgo_instrumented
	@echo "Training pgo"
	mkdir -p $(CMAKE_DIR_RELEASE_GCC_PGO)
	(cd $(CMAKE_DIR_RELEASE_GCC_PGO_INSTRUMENTED) && $(PROFILE_TARGET) && $(PROFILE_TARGET) ) && touch $(CMAKE_DIR_RELEASE_GCC_PGO)/.trained

pyston_pgo: pyston_release_gcc_pgo
	ln -sf $< $@

.PHONY: format check_format
format: $(CMAKE_SETUP_RELEASE)
	$(NINJA) -C $(CMAKE_DIR_RELEASE) format
check_format: $(CMAKE_SETUP_RELEASE)
	$(NINJA) -C $(CMAKE_DIR_RELEASE) check-format

-include $(wildcard src/*.d) $(wildcard src/*/*.d) $(wildcard src/*/*/*.d) $(wildcard $(UNITTEST_DIR)/*.d) $(wildcard from_cpython/*/*.d) $(wildcard from_cpython/*/*/*.d)

.PHONY: clean
clean:
	@ find src $(TOOLS_DIR) $(TEST_DIR) ./from_cpython ./lib_pyston \( -name '*.o' -o -name '*.d' -o -name '*.py_cache' -o -name '*.bc' -o -name '*.o.ll' -o -name '*.pub.ll' -o -name '*.cache' -o -name 'stdlib*.ll' -o -name '*.pyc' -o -name '*.so' -o -name '*.a' -o -name '*.expected_cache' -o -name '*.pch' \) -print -delete
	@ find $(BUILD_DIR) \( -name 'pyston*' -executable -type f \) -print -delete
	@ rm -vf pyston_dbg pyston_release pyston_gcc
	@ find $(TOOLS_DIR) -maxdepth 0 -executable -type f -print -delete
	@ rm -rf oprofile_data
	@ rm -f *_unittest

# A helper function that lets me run subdirectory rules from the top level;
# ex instead of saying "make tests/run_1", I can just write "make run_1"
#
# The target to ultimately be called must be prefixed with nosearch_, for example:
#     nosearch_example_%: %.py
#         echo $^
#     $(call make_search,example_%)
# This prevents us from searching recursively, which can result in a combinatorial explosion.
define make_search
$(eval \
.PHONY: $1 nosearch_$1
$1: nosearch_$1
$1: $(TESTS_DIR)/nosearch_$1 ;
$1: $(TEST_DIR)/cpython/nosearch_$1 ;
$1: $(TEST_DIR)/integration/nosearch_$1 ;
$1: $(TEST_DIR)/extra/nosearch_$1 ;
$1: ./microbenchmarks/nosearch_$1 ;
$1: ./minibenchmarks/nosearch_$1 ;
$1: ./benchmarks/nosearch_$1 ;
$1: $(HOME)/pyston-perf/benchmarking/benchmark_suite/nosearch_$1 ;
$(patsubst %, $$1: %/nosearch_$$1 ;,$(EXTRA_SEARCH_DIRS))
)
endef

define make_target
$(eval \
.PHONY: test$1 check$1
check$1 test$1: $(PYTHON_EXE_DEPS) pyston$1
	$(PYTHON) $(TOOLS_DIR)/tester.py -R pyston$1 -j$(TEST_THREADS) -a=-S -k $(TESTS_DIR) $(ARGS)
	@# we pass -I to cpython tests and skip failing ones because they are sloooow otherwise
	$(PYTHON) $(TOOLS_DIR)/tester.py -R pyston$1 -j$(TEST_THREADS) -a=-S -k --exit-code-only --skip-failing -t50 $(TEST_DIR)/cpython $(ARGS)
	$(PYTHON) $(TOOLS_DIR)/tester.py -R pyston$1 -j$(TEST_THREADS) -k -a=-S --exit-code-only --skip-failing -t600 $(TEST_DIR)/integration $(ARGS)
	$(PYTHON) $(TOOLS_DIR)/tester.py -a=-X -R pyston$1 -j$(TEST_THREADS) -a=-n -a=-S -t50 -k $(TESTS_DIR) $(ARGS)
	$(PYTHON) $(TOOLS_DIR)/tester.py -R pyston$1 -j$(TEST_THREADS) -a=-O -a=-S -k $(TESTS_DIR) $(ARGS)

.PHONY: run$1 dbg$1
run$1: pyston$1 $$(RUN_DEPS)
	PYTHONPATH=test/test_extension:$${PYTHONPATH} ./pyston$1 $$(ARGS)
dbg$1: pyston$1 $$(RUN_DEPS)
	PYTHONPATH=test/test_extension:$${PYTHONPATH} zsh -c 'ulimit -m $$(MAX_DBG_MEM_KB); $$(GDB) $$(GDB_CMDS) --args ./pyston$1 $$(ARGS)'
nosearch_run$1_%: %.py pyston$1 $$(RUN_DEPS)
	$(VERB) PYTHONPATH=test/test_extension:$${PYTHONPATH} zsh -c 'ulimit -m $$(MAX_MEM_KB); time ./pyston$1 $$(ARGS) $$<'
$$(call make_search,run$1_%)
nosearch_dbg$1_%: %.py pyston$1 $$(RUN_DEPS)
	$(VERB) PYTHONPATH=test/test_extension:$${PYTHONPATH} zsh -c 'ulimit -m $$(MAX_DBG_MEM_KB); $$(GDB) $$(GDB_CMDS) --args ./pyston$1 $$(ARGS) $$<'
$$(call make_search,dbg$1_%)

ifneq ($$(ENABLE_VALGRIND),0)
nosearch_memcheck$1_%: %.py pyston$1 $$(RUN_DEPS)
	PYTHONPATH=test/test_extension:$${PYTHONPATH} $$(VALGRIND) --tool=memcheck --leak-check=no --db-attach=yes ./pyston$1 $$(ARGS) $$<
$$(call make_search,memcheck$1_%)
nosearch_memcheck_gdb$1_%: %.py pyston$1 $$(RUN_DEPS)
	set +e; PYTHONPATH=test/test_extension:$${PYTHONPATH} $$(VALGRIND) -v -v -v -v -v --tool=memcheck --leak-check=no --track-origins=yes --vgdb=yes --vgdb-error=0 ./pyston$1 $$(ARGS) $$< & export PID=$$$$! ; \
	$$(GDB) --ex "set confirm off" --ex "target remote | $$(DEPS_DIR)/valgrind-3.10.0-install/bin/vgdb" --ex "continue" --ex "bt" ./pyston$1; kill -9 $$$$PID
$$(call make_search,memcheck_gdb$1_%)
nosearch_memleaks$1_%: %.py pyston$1 $$(RUN_DEPS)
	PYTHONPATH=test/test_extension:$${PYTHONPATH} $$(VALGRIND) --tool=memcheck --leak-check=full --leak-resolution=low --show-reachable=yes ./pyston$1 $$(ARGS) $$<
$$(call make_search,memleaks$1_%)
nosearch_cachegrind$1_%: %.py pyston$1 $$(RUN_DEPS)
	PYTHONPATH=test/test_extension:$${PYTHONPATH} $$(VALGRIND) --tool=cachegrind ./pyston$1 $$(ARGS) $$<
$$(call make_search,cachegrind$1_%)
endif

.PHONY: perf$1_%
nosearch_perf$1_%: %.py pyston$1
	PYTHONPATH=test/test_extension:$${PYTHONPATH} perf record -g -- ./pyston$1 -q -p $$(ARGS) $$<
	@$(MAKE) perf_report
$$(call make_search,perf$1_%)

)
endef

.PHONY: perf_report
perf_report:
	perf report -n

.PHONY: run run_% dbg_% debug_% perf_%
run: run_dbg
dbg: dbg_dbg
run_%: run_dbg_%
	@true
dbg_%: dbg_dbg_%
	@true
debug_%: dbg_debug_%
	@true
perf_%: perf_release_%
	@true

$(call make_target,_dbg)
$(call make_target,_debug)
$(call make_target,_release)
# $(call make_target,_grwl)
# $(call make_target,_grwl_dbg)
# $(call make_target,_nosync)
$(call make_target,_prof)
$(call make_target,_gcc)
$(call make_target,_release_gcc)

nosearch_runpy_% nosearch_pyrun_%: %.py ext_python
	$(VERB) PYTHONPATH=test/test_extension/build/lib.linux-x86_64-2.7:$${PYTHONPATH} zsh -c 'time $(CPYTHON) $<'
nosearch_pypyrun_%: %.py ext_python
	$(VERB) PYTHONPATH=test/test_extension/build/lib.linux-x86_64-2.7:$${PYTHONPATH} zsh -c 'time $(PYPY) $<'
$(call make_search,runpy_%)
$(call make_search,pyrun_%)
$(call make_search,pypyrun_%)

nosearch_check_%: %.py pyston_dbg check-deps
	$(MAKE) check_dbg ARGS="$(patsubst %.py,%,$(notdir $<)) -K"
$(call make_search,check_%)

nosearch_dbgpy_% nosearch_pydbg_%: %.py ext_pythondbg
	export PYTHON_VERSION=$$(python2.7-dbg -V 2>&1 | awk '{print $$2}'); PYTHONPATH=test/test_extension/build/lib.linux-x86_64-2.7-pydebug $(GDB) --ex "dir $(DEPS_DIR)/python-src/python2.7-$$PYTHON_VERSION/debian" $(GDB_CMDS) --args python2.7-dbg $<
$(call make_search,dbgpy_%)
$(call make_search,pydbg_%)

pydbg: ext_pythondbg
	export PYTHON_VERSION=$$(python2.7-dbg -V 2>&1 | awk '{print $$2}'); PYTHONPATH=test/test_extension/build/lib.linux-x86_64-2.7-pydebug $(GDB) --ex "dir $(DEPS_DIR)/python-src/python2.7-$$PYTHON_VERSION/debian" $(GDB_CMDS) --args python2.7-dbg

# "kill valgrind":
kv:
	ps aux | awk '/[v]algrind/ {print $$2}' | xargs kill -9; true

# gprof-based profiling:
nosearch_prof_%: %.py pyston_prof
	zsh -c 'time ./pyston_prof $(ARGS) $<'
	gprof ./pyston_prof gmon.out > $(patsubst %,%.out,$@)
$(call make_search,prof_%)
nosearch_profile_%: %.py pyston_profile
	time ./pyston_profile -p $(ARGS) $<
	gprof ./pyston_profile gmon.out > $(patsubst %,%.out,$@)
$(call make_search,profile_%)

# pprof-based profiling:
nosearch_pprof_%: %.py $(PYTHON_EXE_DEPS) pyston_pprof
	CPUPROFILE_FREQUENCY=1000 CPUPROFILE=$@.out ./pyston_pprof -p $(ARGS) $<
	pprof --raw pyston_pprof $@.out > $@_raw.out
	$(PYTHON) codegen/profiling/process_pprof.py $@_raw.out pprof.jit > $@_processed.out
	pprof --text $@_processed.out
	# rm -f pprof.out pprof.raw pprof.jit
$(call make_search,pprof_%)

# oprofile-based profiling:
.PHONY: oprof_collect_% opreport
oprof_collect_%: %.py pyston_oprof
	sudo opcontrol --image pyston_oprof
	# sudo opcontrol --event CPU_CLK_UNHALTED:28000
	# sudo opcontrol --cpu-buffer-size=128000 --buffer-size=1048576 --buffer-watershed=1048000
	sudo opcontrol --reset
	sudo opcontrol --start
	time ./pyston_oprof -p $(ARGS) $<
	sudo opcontrol --stop
	sudo opcontrol --dump
	sudo opcontrol --image all --event default --cpu-buffer-size=0 --buffer-size=0 --buffer-watershed=0
	sudo opcontrol --deinit
	sudo opcontrol --init
nosearch_oprof_%: oprof_collect_%
	$(MAKE) opreport
$(call make_search,oprof_%)
opreport:
	! [ -d oprofile_data ]
	opreport -l -t 0.2 -a pyston_oprof
	# opreport lib-image:pyston_oprof -l -t 0.2 -a | head -n 25

.PHONY: oprof_collectcg_% opreportcg
oprof_collectcg_%: %.py pyston_oprof
	operf -g -e CPU_CLK_UNHALTED:90000 ./pyston_oprof -p $(ARGS) $<
nosearch_oprofcg_%: oprof_collectcg_%
	$(MAKE) opreportcg
$(call make_search,oprofcg_%)
opreportcg:
	opreport lib-image:pyston_oprof -l -t 0.2 -a --callgraph

.PHONY: watch_% watch wdbg_%
watch_%:
	@ ( ulimit -t 60; ulimit -m $(MAK_MEM_KB); \
		TARGET=$(dir $@)$(patsubst watch_%,%,$(notdir $@)); \
		clear; $(MAKE) $$TARGET $(WATCH_ARGS); true; \
		while inotifywait -q -e modify -e attrib -e move -e move_self -e create -e delete -e delete_self \
		Makefile $$(find src test plugins \( -name '*.cpp' -o -name '*.h' -o -name '*.py' \) ); do clear; \
			$(MAKE) $$TARGET $(WATCH_ARGS); \
		done )
		# Makefile $$(find \( -name '*.cpp' -o -name '*.h' -o -name '*.py' \) -o -type d ); do clear; $(MAKE) $(patsubst watch_%,%,$@); done )
		# -r . ; do clear; $(MAKE) $(patsubst watch_%,%,$@); done
watch: watch_pyston_dbg
watch_vim:
	$(MAKE) watch WATCH_ARGS='COLOR=0 USE_DISTCC=0 -j1 2>&1 | tee compile.log'
wdbg_%:
	$(MAKE) $(patsubst wdbg_%,watch_dbg_%,$@) GDB_POST_CMDS="--ex quit"

.PHONY: head_%
HEAD := 40
head_%:
	@ bash -c "set -o pipefail; script -e -q -c '$(MAKE) $(dir $@)$(patsubst head_%,%,$(notdir $@))' /dev/null | head -n$(HEAD)"
head: head_pyston_dbg
.PHONY: hwatch_%
hwatch_%:
	@ $(MAKE) $(dir $@)$(patsubst hwatch_%,watch_head_%,$(notdir $@))
hwatch: hwatch_pyston_dbg

.PHONY: test_asm test_cpp_asm
test_asm:
	$(CLANGPP_EXE) $(TEST_DIR)/test.s -c -o test_asm
	objdump -d test_asm | less
	@ rm test_asm
test_cpp_asm:
	$(CLANGPP_EXE) $(TEST_DIR)/test.cpp -o test_asm -c -O3 -std=c++11
	# $(GPP) tests/test.cpp -o test_asm -c -O3
	objdump -d test_asm | less
	rm test_asm
test_cpp_dwarf:
	$(CLANGPP_EXE) $(TEST_DIR)/test.cpp -o test_asm -c -O3 -std=c++11 -g
	# $(GPP) tests/test.cpp -o test_asm -c -O3
	objdump -W test_asm | less
	rm test_asm
test_cpp_ll:
	$(CLANGPP_EXE) $(TEST_DIR)/test.cpp -o test.ll -c -O3 -emit-llvm -S -std=c++11
	less test.ll
	rm test.ll
.PHONY: bench_exceptions
bench_exceptions:
	$(CLANGPP_EXE) $(TEST_DIR)/bench_exceptions.cpp -o bench_exceptions -O3 -std=c++11
	zsh -c 'ulimit -m $(MAX_MEM_KB); time ./bench_exceptions'
	rm bench_exceptions

TEST_EXT_MODULE_NAMES := basic_test descr_test slots_test
TEST_EXT_MODULE_SRCS := $(TEST_EXT_MODULE_NAMES:%=test/test_extension/%.c)
TEST_EXT_MODULE_OBJS := $(TEST_EXT_MODULE_NAMES:%=test/test_extension/%.pyston.so)

SHAREDMODS_NAMES := _multiprocessing pyexpat future_builtins
SHAREDMODS_SRCS := \
	_multiprocessing/multiprocessing.c \
	_multiprocessing/semaphore.c \
	_multiprocessing/socket_connection.c \
	expat/xmlparse.c \
	expat/xmlrole.c \
	expat/xmltok.c \
	expat/xmltok_impl.c \
	expat/xmltok_ns.c \
 	pyexpat.c \
	_elementtree.c\
	future_builtins.c
SHAREDMODS_SRCS := $(SHAREDMODS_SRCS:%=from_cpython/Modules/%)
SHAREDMODS_OBJS := $(SHAREDMODS_NAMES:%=lib_pyston/%.pyston.so)

.PHONY: sharedmods
sharedmods: $(SHAREDMODS_OBJS)

.PHONY: ext_pyston
ext_pyston: $(TEST_EXT_MODULE_OBJS)

# Makefile hackery: we can build test extensions with any build configuration of pyston,
# so try to guess one that will end up being built anyway, and use that as the dependency.
ifneq ($(findstring release,$(MAKECMDGOALS))$(findstring perf,$(MAKECMDGOALS)),)
BUILD_PY:=pyston_release
else
BUILD_PY:=pyston_dbg
endif

# Hax: we want to generate multiple targets from a single rule, and run the rule only if the
# dependencies have been updated, and only run it once for all the targets.
# So just tell make to generate the first extension module, and that the non-first ones just
# depend on the first one.
$(firstword $(TEST_EXT_MODULE_OBJS)): $(TEST_EXT_MODULE_SRCS) | $(BUILD_PY)
	$(VERB) cd $(TEST_DIR)/test_extension; time ../../$(BUILD_PY) setup.py build
	$(VERB) cd $(TEST_DIR)/test_extension; ln -sf $(TEST_EXT_MODULE_NAMES:%=build/lib.linux-x86_64-2.7/%.pyston.so) .
	$(VERB) touch -c $(TEST_EXT_MODULE_OBJS)
$(wordlist 2,9999,$(TEST_EXT_MODULE_OBJS)): $(firstword $(TEST_EXT_MODULE_OBJS))
$(firstword $(SHAREDMODS_OBJS)): $(SHAREDMODS_SRCS) | $(BUILD_PY)
	$(VERB) cd $(TEST_DIR)/test_extension; time ../../$(BUILD_PY) ../../from_cpython/setup.py build --build-lib ../../lib_pyston
	$(VERB) touch -c $(SHAREDMODS_OBJS)
$(wordlist 2,9999,$(SHAREDMODS_OBJS)): $(firstword $(SHAREDMODS_OBJS))

.PHONY: ext_python ext_pythondbg
ext_python: $(TEST_EXT_MODULE_SRCS)
	cd $(TEST_DIR)/test_extension; $(CPYTHON) setup.py build
ext_pythondbg: $(TEST_EXT_MODULE_SRCS)
	cd $(TEST_DIR)/test_extension; python2.7-dbg setup.py build

$(FROM_CPYTHON_SRCS:.c=.o): %.o: %.c $(BUILD_SYSTEM_DEPS)
	$(ECHO) Compiling C file to $@
	$(VERB) $(CC) $(EXT_CFLAGS) -c $< -o $@ -g -MMD -MP -MF $(patsubst %.o,%.d,$@) -O0

$(FROM_CPYTHON_SRCS:.c=.o.ll): %.o.ll: %.c $(BUILD_SYSTEM_DEPS)
	$(ECHO) Compiling C file to $@
	$(VERB) $(CLANG_EXE) $(EXT_CFLAGS) -S -emit-llvm -c $< -o $@ -g -MMD -MP -MF $(patsubst %.o,%.d,$@) -O3 -g0

$(FROM_CPYTHON_SRCS:.c=.release.o): %.release.o: %.c $(BUILD_SYSTEM_DEPS)
	$(ECHO) Compiling C file to $@
	$(VERB) $(CC) $(EXT_CFLAGS) -c $< -o $@ -g -MMD -MP -MF $(patsubst %.o,%.d,$@)

$(FROM_CPYTHON_SRCS:.c=.prof.o): %.prof.o: %.c $(BUILD_SYSTEM_DEPS)
	$(ECHO) Compiling C file to $@
	$(VERB) $(CC_PROFILE) $(EXT_CFLAGS_PROFILE) -c $< -o $@ -g -MMD -MP -MF $(patsubst %.o,%.d,$@)

.PHONY: update_section_ordering
update_section_ordering: pyston_release
	perf record -o perf_section_ordering.data -- ./pyston_release -q minibenchmarks/combined.py
	perf record -o perf_section_ordering.data -- ./pyston_release -q minibenchmarks/combined.py
	$(MAKE) pyston_pgo
	python tools/generate_section_ordering_from_pgo_build.py pyston_pgo perf_section_ordering.data > section_ordering.txt
	rm perf_section_ordering.data



# TESTING:

PLUGINS := $(wildcard plugins/*.cpp)
$(patsubst %.cpp,%.o,$(PLUGINS)): plugins/%.o: plugins/%.cpp $(BUILD_SYSTEM_DEPS)
	ninja -C $(CMAKE_DIR_DBG) llvm/bin/llvm-config clangASTMatchers clangTooling LLVMLTO LLVMDebugInfoPDB LLVMLineEditor LLVMInterpreter LLVMOrcJIT llvm/bin/clang
	$(CMAKE_DIR_DBG)/llvm/bin/clang $< -o $@ -std=c++11 $(shell $(LLVM_BIN_DBG)/llvm-config --cxxflags) -fno-rtti -O0 -I$(LLVM_SRC)/tools/clang/include -I$(LLVM_INC_DBG)/tools/clang/include -c

$(patsubst %.cpp,%.so,$(PLUGINS)): plugins/%.so: plugins/%.o
	$(CMAKE_DIR_DBG)/llvm/bin/clang $< -o $@ -shared -lclangASTMatchers -lclangTooling $(shell $(LLVM_BIN_DBG)/llvm-config --ldflags)
	# $(CXX) $< -o $@ -lclangASTMatchers -lclangRewrite -lclangFrontend -lclangDriver -lclangTooling -lclangParse -lclangSema -lclangAnalysis -lclangAST -lclangEdit -lclangLex -lclangBasic -lclangSerialization $(shell $(LLVM_BIN_DBG)/llvm-config --ldflags --system-libs --libs all)

$(patsubst %.cpp,%,$(PLUGINS)): plugins/%: plugins/%.o $(BUILD_SYSTEM_DEPS)
	$(CXX) $< -o $@ -lclangASTMatchers -lclangRewrite -lclangFrontend -lclangDriver -lclangTooling -lclangParse -lclangSema -lclangAnalysis -lclangAST -lclangEdit -lclangLex -lclangBasic -lclangSerialization $(shell $(LLVM_BIN_DBG)/llvm-config --ldflags --system-libs --libs all)

.PHONY: tool_test
tool_test: plugins/clang_linter.o
	plugins/clang_linter test/test.cpp -- $(shell $(LLVM_BIN_DBG)/llvm-config --cxxflags) -I/usr/lib/llvm-3.5/include

.PHONY: superlint
superlint: plugins/clang_linter.so
	for fn in $(MAIN_SRCS); do $(CLANG_CXX) -Xclang -load -Xclang plugins/clang_linter.so -Xclang -plugin -Xclang pyston-linter $$fn -c -Isrc/ -Ifrom_cpython/Include -Ibuild/Debug/from_cpython/Include $(shell $(LLVM_BIN_DBG)/llvm-config --cxxflags) -no-pedantic -Wno-unused-variable -DNVALGRIND -Wno-invalid-offsetof -Wno-mismatched-tags -Wno-unused-function -Wno-unused-private-field -Wno-sign-compare || break; done

.PHONY: lint_%
lint_%: %.cpp plugins/clang_linter.so
	$(ECHO) Linting $<
	$(VERB) $(CLANG_CXX) -Xclang -load -Xclang plugins/clang_linter.so -Xclang -plugin -Xclang pyston-linter src/runtime/float.cpp $< -c -Isrc/ -Ifrom_cpython/Include -Ibuild/Debug/from_cpython/Include $(shell $(LLVM_BIN_DBG)/llvm-config --cxxflags) $(COMMON_CXXFLAGS) -no-pedantic -Wno-unused-variable -DNVALGRIND -Wno-invalid-offsetof -Wno-mismatched-tags -Wno-unused-function -Wno-unused-private-field -Wno-sign-compare -DLLVMREV=$(LLVM_REVISION) -Ibuild_deps/lz4/lib -DBINARY_SUFFIX= -DBINARY_STRIPPED_SUFFIX=_stripped  -Ibuild_deps/libpypa/src/ -Wno-covered-switch-default -Ibuild/Debug/libunwind/include -Wno-extern-c-compat -Wno-unused-local-typedef -Wno-inconsistent-missing-override

REFCOUNT_CHECKER_BUILD_PATH := $(CMAKE_DIR_DBG)/plugins/refcount_checker/llvm/bin/refcount_checker
REFCOUNT_CHECKER_RUN_PATH := $(CMAKE_DIR_DBG)/llvm/bin/refcount_checker
$(REFCOUNT_CHECKER_RUN_PATH): refcount_checker

.PHONY: refcount_checker
refcount_checker:
	$(NINJA) -C $(CMAKE_DIR_DBG) refcount_checker copy_stdlib $(NINJAFLAGS)
	cp $(REFCOUNT_CHECKER_BUILD_PATH) $(REFCOUNT_CHECKER_RUN_PATH)

.PHONY: refcheck_%
refcheck_%: %.cpp refcount_checker
	cd $(CMAKE_DIR_DBG); $(REFCOUNT_CHECKER_RUN_PATH) ../../$<
.PHONY: dbg_refcheck_%
dbg_refcheck_%: %.cpp refcount_checker
	cd $(CMAKE_DIR_DBG); $(GDB) --ex run --ex "bt 20" --args $(REFCOUNT_CHECKER_RUN_PATH) ../../$<


.PHONY: clang_lint
clang_lint: $(foreach FN,$(MAIN_SRCS),$(dir $(FN))lint_$(notdir $(FN:.cpp=)))

# 'make package' will build a package using the pgo build, since that's the
# configuration with the best performance.  Testing that is a pain since it
# requires rerunning the pgo build, so there's also 'make package_nonpgo' mostly
# for testing.
package: pyston_pgo
	$(NINJA) -C $(CMAKE_DIR_RELEASE_GCC_PGO) package

package_nonpgo:
	$(NINJA) -C $(CMAKE_DIR_RELEASE) package
