#**************************************************************************
#*                                                                        *
#*                                 OCaml                                  *
#*                                                                        *
#*                 Xavier Clerc, SED, INRIA Rocquencourt                  *
#*                                                                        *
#*   Copyright 2010 Institut National de Recherche en Informatique et     *
#*     en Automatique.                                                    *
#*                                                                        *
#*   All rights reserved.  This file is distributed under the terms of    *
#*   the GNU Lesser General Public License version 2.1, with the          *
#*   special exception on linking described in the file LICENSE.          *
#*                                                                        *
#**************************************************************************

.NOTPARALLEL:

BASEDIR := $(shell pwd)

FIND=find
TOPDIR := ..
include $(TOPDIR)/Makefile.tools

OCAMLTESTDIR_CYGPATH=$(shell $(CYGPATH) $(BASEDIR)/$(DIR)/_ocamltest)

failstamp := failure.stamp

TESTLOG ?= _log

ocamltest_directory := ../ocamltest

ocamltest_program := $(or \
  $(wildcard $(ocamltest_directory)/ocamltest.opt$(EXE)),\
  $(wildcard $(ocamltest_directory)/ocamltest$(EXE)))

ifeq "$(UNIX_OR_WIN32)" "unix"
  ifeq "$(SYSTEM)" "cygwin"
    find := /usr/bin/find
  else # Non-cygwin Unix
    find := find
  endif
  FLEXLINK_ENV =
else # Windows
  find := /usr/bin/find
  FLEXDLL_SUBMODULE_PRESENT := $(wildcard ../flexdll/Makefile)
  ifeq "$(FLEXDLL_SUBMODULE_PRESENT)" ""
    FLEXLINK_ENV =
  else
    ROOT := $(shell cd .. && pwd| cygpath -m -f -)
    FLEXLINK_ENV = \
      OCAML_FLEXLINK="$(ROOT)/boot/ocamlrun $(ROOT)/flexdll/flexlink.exe"
  endif
endif

ifeq "$(ocamltest_program)" ""
  ocamltest = $(error ocamltest not found in $(ocamltest_directory))
else
  ifeq "$(FLEXLINK_ENV)" ""
    ocamltest := MKDLL="$(MKDLL)" SORT=$(SORT) MAKE=$(MAKE) $(ocamltest_program)
  else
    FLEXLINK_DLL_LDFLAGS=$(if $(OC_DLL_LDFLAGS), -link "$(OC_DLL_LDFLAGS)")
    MKDLL=$(WINTOPDIR)/boot/ocamlrun $(WINTOPDIR)/flexdll/flexlink.exe \
                                     $(FLEXLINK_FLAGS) $(FLEXLINK_DLL_LDFLAGS)

    ocamltest := $(FLEXLINK_ENV) MKDLL="$(MKDLL)" SORT=$(SORT) MAKE=$(MAKE) \
                                 $(ocamltest_program)
  endif
endif

# PROMOTE is only meant to be used internally in recursive calls;
# users should call the 'promote' target explicitly.
PROMOTE =
ifeq "$(PROMOTE)" ""
  OCAMLTEST_PROMOTE_FLAG :=
else
  OCAMLTEST_PROMOTE_FLAG := -promote
endif

# KEEP_TEST_DIR_ON_SUCCESS should be set by the user (to a non-empty value)
# if they want to pass the -keep-test-dir-on-success option to ocamltest,
# to preserve test data of successful tests.
KEEP_TEST_DIR_ON_SUCCESS ?=
ifeq "$(KEEP_TEST_DIR_ON_SUCCESS)" ""
  OCAMLTEST_KEEP_TEST_DIR_ON_SUCCESS_FLAG :=
else
  OCAMLTEST_KEEP_TEST_DIR_ON_SUCCESS_FLAG := -keep-test-dir-on-success
endif

OCAMLTESTFLAGS := \
  $(OCAMLTEST_PROMOTE_FLAG) \
  $(OCAMLTEST_KEEP_TEST_DIR_ON_SUCCESS_FLAG)

.PHONY: default
default:
	@echo "Available targets:"
	@echo "  all             launch all tests"
	@echo "  all-foo         launch all tests beginning with foo"
	@echo "  parallel        launch all tests using GNU parallel"
	@echo "  parallel-foo    launch all tests beginning with foo using \
	GNU parallel"
	@echo "  one TEST=f      launch just this single test"
	@echo "  one DIR=p       launch the tests located in path p"
	@echo "  one LIST=f      launch the tests listed in f (one per line)"
	@echo "  promote TEST=f  promote the output for this single test"
	@echo "  promote DIR=p   promote the output for the tests located in path p"
	@echo "  promote LIST=f  promote the output for the tests listed in f (one \
	per line)"
	@echo "  lib             build library modules"
	@echo "  tools           build test tools"
	@echo "  clean           delete generated files"
	@echo "  report          print the report for the last execution"
	@echo
	@echo "all*, parallel* and list can automatically re-run failed test"
	@echo "directories if MAX_TESTSUITE_DIR_RETRIES permits"
	@echo "(default value = $(MAX_TESTSUITE_DIR_RETRIES))"

.PHONY: all
all:
	@rm -f $(TESTLOG)
	@$(MAKE) --no-print-directory new-without-report
	@$(MAKE) --no-print-directory report

.PHONY: new-without-report
new-without-report: lib tools
	@rm -f $(failstamp)
	@(IFS=$$(printf "\r\n"); \
	$(ocamltest) -find-test-dirs tests | while IFS='' read -r dir; do \
	  echo Running tests from \'$$dir\' ... ; \
	  $(MAKE) exec-ocamltest DIR=$$dir \
	    OCAMLTESTENV=""; \
	done || echo outer loop >> $(failstamp)) 2>&1 | tee -a $(TESTLOG)
	@$(MAKE) check-failstamp

.PHONY: check-failstamp
check-failstamp:
	@if [ -f $(failstamp) ]; then \
	  echo 'Unexpected error in the test infrastructure:'; \
	  cat $(failstamp); \
	  rm $(failstamp); \
	  exit 1; \
	fi

.PHONY: all-%
all-%: lib tools
	@for dir in tests/$**; do \
	  $(MAKE) --no-print-directory exec-one DIR=$$dir; \
	done 2>&1 | tee $(TESTLOG)
	@$(MAKE) report

# The targets below use GNU parallel to parallelize tests
# 'make all' and 'make parallel' should be equivalent
#
# parallel uses specific logic to make sure the output of the commands
# run in parallel are not mangled. By default, it will reproduce
# the output of each completed command atomically, in order of completion.
#
# With the --keep-order option, we ask it to save the completed output
# and replay them in invocation order instead. In theory this costs
# a tiny bit of performance, but I could not measure any difference.
# In theory again, the reporting logic works fine with test outputs
# coming in in arbitrary order (so we should not need --keep-order),
# but keeping the output deterministic is guaranteed to make
# someone's life easier at least once in the future.
#
# Finally, note that the command we run has a 2>&1 redirection, as
# in the other make targets. If we removed the quoting around
# "$(MAKE) ... 2>&1", the rediction would apply to the complete output
# of parallel, and have a slightly different behavior: by default parallel
# cleanly separates the stdout and stderr output of each completed command,
# printing stderr first then stdout second (for each command).
# I chose to keep the previous behavior exactly unchanged,
# but the demangling separation is arguably nicer behavior that we might
# want to implement at the exec-one level to also have it in the 'all' target.
.PHONY: parallel-%
parallel-%: lib tools
	@echo | parallel >/dev/null 2>/dev/null \
	 || (echo "Unable to run the GNU parallel tool;";\
	     echo "You should install it before using the parallel* targets.";\
	     exit 1)
	@echo | parallel --gnu --no-notice >/dev/null 2>/dev/null \
	 || (echo "Your 'parallel' tool seems incompatible with GNU parallel.";\
	     echo "This target requires GNU parallel.";\
	     exit 1)
	@for dir in tests/$**; do echo $$dir; done \
	 | parallel --gnu --no-notice --keep-order \
	     "$(MAKE) --no-print-directory exec-one DIR={} 2>&1" \
	 | tee $(TESTLOG)
	@$(MAKE) report

.PHONY: parallel
parallel: parallel-*

.PHONY: list
list: lib tools
	@if [ -z "$(FILE)" ]; \
    then echo "No value set for variable 'FILE'."; \
    exit 1; \
  fi
	@$(MAKE) --no-print-directory one LIST="$(FILE)"

.PHONY: list-parallel
list-parallel: lib tools
	@if [ -z "$(FILE)" ]; \
	  then echo "No value set for variable 'FILE'."; \
	  exit 1; \
	fi
	@echo | parallel >/dev/null 2>/dev/null \
	 || (echo "Unable to run the GNU parallel tool;";\
	     echo "You should install it before using the parallel* targets.";\
	     exit 1)
	@echo | parallel --gnu --no-notice >/dev/null 2>/dev/null \
	 || (echo "Your 'parallel' tool seems incompatible with GNU parallel.";\
	     echo "This target requires GNU parallel.";\
	     exit 1)
	@cat $(FILE) \
	 | parallel --gnu --no-notice --keep-order \
	   "$(MAKE) $(NO_PRINT) exec-one DIR={} 2>&1" \
	 | tee $(TESTLOG)
	@$(MAKE) report

.PHONY: one
one: lib tools
	@case "$(words $(DIR) $(LIST) $(TEST))" in \
   0) echo 'No value set for variable DIR, LIST or TEST'>&2; exit 1;; \
   1) exit 0;; \
   *) echo 'Please specify exactly one of DIR, LIST or TEST'>&2; exit 1;; \
   esac
	@if [ -n '$(DIR)' ] && [ ! -d '$(DIR)' ]; then \
    echo "Directory '$(DIR)' does not exist."; exit 1; \
  fi
	@if [ -n '$(TEST)' ] && [ ! -e '$(TEST)' ]; then \
    echo "Test '$(TEST)' does not exist."; exit 1; \
  fi
	@if [ -n '$(LIST)' ] && [ ! -e '$(LIST)' ]; then \
    echo "File '$(LIST)' does not exist."; exit 1; \
  fi
	@if [ -n '$(DIR)' ] ; then \
    $(MAKE) --no-print-directory exec-one DIR=$(DIR); fi
	@if [ -n '$(TEST)' ] ; then \
    TERM=dumb $(OCAMLTESTENV) $(ocamltest) $(OCAMLTESTFLAGS) $(TEST); fi
	@$(MAKE) check-failstamp
	@if [ -n '$(LIST)' ] ; then \
     while IFS='' read -r LINE; do \
       $(MAKE) --no-print-directory exec-one DIR="`echo $$LINE | sed 's/^ *//g'`" ; \
     done < $$LIST 2>&1 | tee $(TESTLOG) ; \
     $(MAKE) report ; fi

.PHONY: exec-one
exec-one:
	@if $(ocamltest) -list-tests $(DIR) >/dev/null 2>&1; then \
	  echo "Running tests from '$$DIR' ..."; \
	  $(MAKE) exec-ocamltest DIR=$(DIR) \
	    OCAMLTESTENV="OCAMLTESTDIR=$(OCAMLTESTDIR_CYGPATH)"; \
	else \
	  for dir in $(DIR)/*; do \
	    if [ -d $$dir ]; then \
	      $(MAKE) exec-one DIR=$$dir; \
	    fi; \
	  done; \
	fi

.PHONY: exec-ocamltest
exec-ocamltest:
	@if [ -z "$(DIR)" ]; then exit 1; fi
	@if [ ! -d "$(DIR)" ]; then exit 1; fi
	@(IFS=$$(printf "\r\n"); \
	$(ocamltest) -list-tests $(DIR) | while IFS='' read -r testfile; do \
	   TERM=dumb $(OCAMLTESTENV) \
	     $(ocamltest) $(OCAMLTESTFLAGS) $(DIR)/$$testfile || \
	   echo " ... testing '$$testfile' => unexpected error"; \
	done) || echo directory "$(DIR)" >>$(failstamp)

.PHONY: clean-one
clean-one:
	@if [ ! -f $(DIR)/Makefile ]; then \
	  for dir in $(DIR)/*; do \
	    if [ -d $$dir ]; then \
	      $(MAKE) clean-one DIR=$$dir; \
	    fi; \
	  done; \
	else \
	  cd $(DIR) && $(MAKE) TERM=dumb BASEDIR=$(BASEDIR) clean; \
	fi

.PHONY: promote
promote: lib tools
	@$(MAKE) one PROMOTE=true

.PHONY: lib
lib:
	@$(MAKE) -s -C lib

.PHONY: tools
tools:
	@cd tools && $(MAKE) -s BASEDIR=$(BASEDIR)

.PHONY: clean
clean:
	@$(MAKE) -C lib clean
	@cd tools && $(MAKE) BASEDIR=$(BASEDIR) clean
	$(FIND) . -name '*_ocamltest*' | xargs rm -rf
	rm -f $(failstamp)

.PHONY: report
report:
	@if [ ! -f $(TESTLOG) ]; then echo "No $(TESTLOG) file."; exit 1; fi
	@$(AWK) -f ./summarize.awk < $(TESTLOG)
