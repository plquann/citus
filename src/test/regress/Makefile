# Makefile for tests of the Citus extension

citus_subdir = src/test/regress
citus_top_builddir = ../../..

include $(citus_top_builddir)/Makefile.global

# ensure MAJORVERSION is defined (missing in older versions)
ifndef MAJORVERSION
MAJORVERSION := $(basename $(VERSION))
endif

# Add ./bin to $PATH so we use our custom diff instead of the default diff tool.
# We do this to be able to mask shard Ids, placement Ids, node ports, etc.
MAKEFILE_DIR := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))
export PATH := $(MAKEFILE_DIR)/bin:$(PATH)
export PG_REGRESS_DIFF_OPTS = -dU10 -w
# Use lower isolation test timeout, the 5 minute default is waaay too long for
# us so we use 5 seconds instead. We should detect blockages very quickly and
# the queries we run are also very fast.
export PGISOLATIONTIMEOUT = 5

##
## Citus regression support
##
MULTI_INSTALLDIR=$(CURDIR)/tmp_check/install
pg_regress_multi_check = $(PERL) $(citus_abs_srcdir)/pg_regress_multi.pl --pgxsdir="$(pgxsdir)" --bindir="$(bindir)" --libdir="$(libdir)" --majorversion="$(MAJORVERSION)" --postgres-builddir="$(postgres_abs_builddir)"  --postgres-srcdir="$(postgres_abs_srcdir)"
MULTI_REGRESS_OPTS = --inputdir=$(citus_abs_srcdir) $(pg_regress_locale_flags) --launcher="$(citus_abs_srcdir)/log_test_times"

pg_upgrade_check = $(citus_abs_srcdir)/upgrade/pg_upgrade_test.py
citus_upgrade_check = $(citus_abs_srcdir)/upgrade/citus_upgrade_test.py

template_isolation_files = $(shell find $(citus_abs_srcdir)/spec/ -name '*.spec')
generated_isolation_files = $(patsubst $(citus_abs_srcdir)/spec/%,$(citus_abs_srcdir)/build/specs/%,$(template_isolation_files))

# Test input and expected files.  These are created by pg_regress itself, so we
# don't have a rule to create them.  We do need rules to clean them however.
input_files := $(patsubst $(citus_abs_srcdir)/input/%.source,sql/%.sql, $(wildcard $(citus_abs_srcdir)/input/*.source))
output_files := $(patsubst $(citus_abs_srcdir)/output/%.source,expected/%.out, $(wildcard $(citus_abs_srcdir)/output/*.source))

# have make check actually run all tests, but keep check-full as an
# intermediate, for muscle memory backward compatibility.
check: check-full
# check-full triggers all tests that ought to be run routinely
check-full: check-multi check-multi-mx check-worker check-operations check-follower-cluster check-failure


ISOLATION_DEPDIR=.deps/isolation
ISOLATION_BUILDDIR=build/specs

# this can be used to print a value of variable
# ex: make print-generated_isolation_files
print-%  : ; @echo $* = $($*)

.PHONY: create-symbolic-link create-tablespaces

create-symbolic-link:
	mkdir -p $(citus_abs_srcdir)/build
	ln -fsn $(citus_abs_srcdir)/expected $(citus_abs_srcdir)/build/

create-tablespaces:
	rm -rf $(citus_abs_srcdir)/tmp_check/ts1
	mkdir -p $(citus_abs_srcdir)/tmp_check/ts1
	rm -rf $(citus_abs_srcdir)/tmp_check/ts0
	mkdir -p $(citus_abs_srcdir)/tmp_check/ts0
	rm -rf $(citus_abs_srcdir)/tmp_check/ts2
	mkdir -p $(citus_abs_srcdir)/tmp_check/ts2

# How this target works:
# cpp is used before running isolation tests to preprocess spec files.
# This way we can include any file we want to. Currently this is used to include mx common part.
# spec files are put to /build/specs for clear separation between generated files and template files
# a symbolic link is created for /expected in build/expected/.
# when running isolation tests, as the inputdir, build is passed so
# it runs the spec files from build/specs and checks the expected output from build/expected.
# /specs is renamed as /spec because postgres first look at the specs file under current directory,
# so this is renamed to avoid that since we are running the isolation tests from build/specs now.
$(generated_isolation_files): $(citus_abs_srcdir)/build/specs/%: $(citus_abs_srcdir)/spec/% Makefile
	@mkdir -p $(citus_abs_srcdir)/$(ISOLATION_DEPDIR) $(citus_abs_srcdir)/$(ISOLATION_BUILDDIR)
	@# -MF is used to store dependency files(.Po) in another directory for separation
	@# -MT is used to change the target of the rule emitted by dependency generation.
	@# -P is used to inhibit generation of linemarkers in the output from the preprocessor.
	@# -undef is used to not predefine any system-specific or GCC-specific macros.
	@# `man cpp` for further information
	@# sed is used to strip the final // comments, because OSX cpp is weird
	cd $(citus_abs_srcdir) && cpp -undef -w -P -MMD -MP -MF$(ISOLATION_DEPDIR)/$(*F).Po -MT$@ $< | sed '/^\/\//d' | sed '/^$$/d' > $@


Isolation_Po_files := $(wildcard $(ISOLATION_DEPDIR)/*.Po)
ifneq (,$(Isolation_Po_files))
include $(Isolation_Po_files)
endif

isolation_test_files=$(generated_isolation_files) create-symbolic-link

ifndef CITUS_VALGRIND_LOG_FILE
CITUS_VALGRIND_LOG_FILE := citus_valgrind_test_log.txt
endif

ifndef COLUMNAR_VALGRIND_LOG_FILE
COLUMNAR_VALGRIND_LOG_FILE := columnar_valgrind_test_log.txt
endif

# using pg_regress_multi_check unnecessarily starts up multiple nodes, which isn't needed
# for check-worker. But that's harmless besides a few cycles.
check-worker: all
	$(pg_regress_multi_check) --load-extension=citus \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/worker_schedule $(EXTRA_TESTS)

# check-base only sets up a testing environment so you can specify all your tests using EXTRA_TESTS
check-base: all
	$(pg_regress_multi_check) --load-extension=citus \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/base_schedule $(EXTRA_TESTS)

# check-minimal only sets up the cluster
check-minimal: all create-tablespaces
	$(pg_regress_multi_check) --load-extension=citus \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/minimal_schedule $(EXTRA_TESTS)

check-base-vg: all
	$(pg_regress_multi_check) --load-extension=citus \
	--valgrind --pg_ctl-timeout=360 --connection-timeout=500000 --valgrind-path=valgrind --valgrind-log-file=$(CITUS_VALGRIND_LOG_FILE) \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/base_schedule $(EXTRA_TESTS)

check-base-mx: all
	$(pg_regress_multi_check) --load-extension=citus \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/mx_base_schedule $(EXTRA_TESTS)

check-minimal-mx: all
	$(pg_regress_multi_check) --load-extension=citus \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/mx_minimal_schedule $(EXTRA_TESTS)


check-empty: all
	$(pg_regress_multi_check) --load-extension=citus \
	-- $(MULTI_REGRESS_OPTS) $(EXTRA_TESTS)

check-multi: all
	$(pg_regress_multi_check) --load-extension=citus \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/multi_schedule $(EXTRA_TESTS)

check-multi-1: all
	$(pg_regress_multi_check) --load-extension=citus \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/multi_1_schedule $(EXTRA_TESTS)

check-multi-hyperscale: all
	$(pg_regress_multi_check) --conninfo="$(conninfo)" --load-extension=citus \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/multi_schedule_hyperscale $(EXTRA_TESTS)

check-multi-hyperscale-superuser: all
	$(pg_regress_multi_check) --conninfo="$(conninfo)" --worker-1-public-hostname="$(worker_1_public_hostname)" --worker-2-public-hostname="$(worker_2_public_hostname)" --load-extension=citus \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/multi_schedule_hyperscale_superuser $(EXTRA_TESTS)

check-multi-vg: all
	$(pg_regress_multi_check) --load-extension=citus --valgrind \
	--pg_ctl-timeout=360 --connection-timeout=500000 --valgrind-path=valgrind --valgrind-log-file=$(CITUS_VALGRIND_LOG_FILE) \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/multi_schedule $(EXTRA_TESTS)

check-columnar-vg: all
	$(pg_regress_multi_check) --load-extension=citus --valgrind \
	--pg_ctl-timeout=360 --connection-timeout=500000 --valgrind-path=valgrind --valgrind-log-file=$(COLUMNAR_VALGRIND_LOG_FILE) \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/columnar_schedule $(EXTRA_TESTS)

check-isolation: all  $(isolation_test_files)
	$(pg_regress_multi_check) --load-extension=citus --isolationtester \
	-- $(MULTI_REGRESS_OPTS) --inputdir=$(citus_abs_srcdir)/build --schedule=$(citus_abs_srcdir)/isolation_schedule $(EXTRA_TESTS)

check-isolation-base: all  $(isolation_test_files)
	$(pg_regress_multi_check) --load-extension=citus --isolationtester \
	-- $(MULTI_REGRESS_OPTS) --inputdir=$(citus_abs_srcdir)/build --schedule=$(citus_abs_srcdir)/base_isolation_schedule $(EXTRA_TESTS)

check-vanilla: all
	# it is possible that sometimes vanilla tests will fail, which is related to postgres.
	# So we try it once more if it fails to prevent some failures in our CI.
	${MAKE} check-vanilla-internal  || ${MAKE} check-vanilla-internal

check-vanilla-internal:
	$(pg_regress_multi_check) --load-extension=citus --vanillatest

check-multi-mx: all
	$(pg_regress_multi_check) --load-extension=citus \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/multi_mx_schedule $(EXTRA_TESTS)

check-follower-cluster: all
	$(pg_regress_multi_check) --load-extension=citus --follower-cluster \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/multi_follower_schedule $(EXTRA_TESTS)

check-operations: all
	$(pg_regress_multi_check) --load-extension=citus \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/operations_schedule $(EXTRA_TESTS)

check-columnar:
	$(pg_regress_multi_check) --load-extension=citus \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/columnar_schedule $(EXTRA_TESTS)

check-columnar-isolation: all  $(isolation_test_files)
	$(pg_regress_multi_check) --load-extension=citus --isolationtester \
	-- $(MULTI_REGRESS_OPTS) --inputdir=$(citus_abs_srcdir)/build --schedule=$(citus_abs_srcdir)/columnar_isolation_schedule $(EXTRA_TESTS)

check-failure: all
	$(pg_regress_multi_check) --load-extension=citus --mitmproxy \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/failure_schedule $(EXTRA_TESTS)

check-failure-base: all
	$(pg_regress_multi_check) --load-extension=citus --mitmproxy \
	-- $(MULTI_REGRESS_OPTS) --schedule=$(citus_abs_srcdir)/failure_base_schedule $(EXTRA_TESTS)

check-pg-upgrade:
	$(pg_upgrade_check) --old-bindir=$(old-bindir) --new-bindir=$(new-bindir) --pgxsdir=$(pgxsdir)

check-citus-upgrade:
	$(citus_upgrade_check) \
		--bindir=$(bindir) \
		--pgxsdir=$(pgxsdir) \
		--citus-pre-tar=$(citus-pre-tar) \
		--citus-post-tar=$(citus-post-tar)

check-citus-upgrade-mixed:
	$(citus_upgrade_check) \
		--bindir=$(bindir) \
		--pgxsdir=$(pgxsdir) \
		--citus-pre-tar=$(citus-pre-tar) \
		--citus-post-tar=$(citus-post-tar) \
		--mixed

check-citus-upgrade-local: clean-upgrade-artifacts
	$(citus_upgrade_check) \
		--bindir=$(bindir) \
		--pgxsdir=$(pgxsdir) \
		--citus-old-version=$(citus-old-version)

check-citus-upgrade-mixed-local: clean-upgrade-artifacts
	$(citus_upgrade_check) \
		--bindir=$(bindir) \
		--pgxsdir=$(pgxsdir) \
		--citus-old-version=$(citus-old-version) \
		--mixed

clean-upgrade-artifacts:
	rm -rf $(citus_abs_srcdir)/tmp_citus_tarballs/ $(citus_abs_srcdir)/tmp_citus_upgrade/ /tmp/citus_copy/

clean distclean maintainer-clean:
	rm -f $(output_files) $(input_files)
	rm -rf tmp_check/

all: create-tablespaces
