###############################################################################
# Global makefile configuration
###############################################################################
# Name of the Debian Source Package
DSC_NAME := $(shell dpkg-parsechangelog -S Source)
# Debian package version (<upstream>-<inc>)
DEB_VERSION := $(shell dpkg-parsechangelog -S Version)
# Debian package upstream version (<upstream>)
UPSTREAM_VERSION := $(shell echo $(DEB_VERSION) | rev | cut -d- -f2- | rev)
# Original upstream archive (generated from git repo)
UPSTREAM_TARBALL := $(DSC_NAME)_$(UPSTREAM_VERSION).orig.tar.xz
# Python module version
PY_VERSION := $(shell grep __version__ uno/__init__.py | cut -d= -f2- | tr -d \" | cut '-d ' -f2-)
# Name of the Python module
PY_NAME := $(shell grep '^name =' pyproject.toml | cut -d= -f2- | tr -d \" | cut '-d ' -f2-)
ifneq ($(PY_NAME),uno)
$(warning unexpected Python module name: '$(PY_NAME)')
endif
# Docker image for the Debian Builder container
DEB_BUILDER ?= mentalsmash/debian-builder:latest
# Docker image for the Debian Tester container
DEB_TESTER ?= mentalsmash/debian-tester:latest
# Local uno clone
UNO_DIR ?= $(shell pwd)
# Directory where to generate test logs
# When running inside do It MUST be a subdirectory of UNO_DIR
TEST_RESULTS_DIR ?= $(UNO_DIR)/test-results
# A unique ID for the test run
TEST_ID ?= local
# The date when the tests were run
TEST_DATE ?= $(shell date +%Y%m%d-%H%M%S)
# Common prefix for the JUnit XML report generated by tests
TEST_JUNIT_REPORT ?= $(PY_NAME)-test-$(TEST_ID)__$(TEST_DATE)
# Docker image used to run tests
TEST_IMAGE ?= mentalsmash/uno-test-runner:latest
# Global flag telling the makefile to perform actions (e.g. run unit test) in a container.
IN_DOCKER ?=
# Directory targeted by the fix-file-ownership target
FIX_DIR ?= $(UNO_DIR)
# Directory where to generate file
OUT_DIR ?= $(UNO_DIR)

# Set default verbosity from DEBUG flag
ifneq ($(DEBUG),)
VERBOSITY ?= debug
endif
export VERBOSITY
export DEBUG

ifneq ($(UPSTREAM_VERSION),$(PY_VERSION))
$(warning unexpected debian upstream version ('$(UPSTREAM_VERSION)' != '$(PY_VERSION)'))
endif
ifneq ($(DSC_NAME),$(PY_NAME))
$(warning unexpected debian source package name ('$(DSC_NAME)' != '$(PY_NAME)'))
endif

INVALID_RTI_LICENSE_FILE := \
  printf -- "ERROR: no RTI_LICENSE_FILE when testing without NO_LICENSE\n" >&2 \
    && exit 1

ifneq ($(NO_LICENSE),)
ifneq ($(RTI_LICENSE_FILE),)
$(warning suppressing RTI_LICENSE_FILE := $(RTI_LICENSE_FILE))
endif
override undefine RTI_LICENSE_FILE
else # ifneq ($(NO_LICENSE),)
ifeq ($(RTI_LICENSE_FILE),)
$(warning no RTI_LICENSE_FILE specified)
CHECK_RTI_LICENSE_FILE = $(INVALID_RTI_LICENSE_FILE)
else
ifeq ($(wildcard $(RTI_LICENSE_FILE)),)
$(warning invalid RTI_LICENSE_FILE ('$(RTI_LICENSE_FILE)'))
CHECK_RTI_LICENSE_FILE = $(INVALID_RTI_LICENSE_FILE)
endif
endif
endif # ifneq ($(NO_LICENSE),)
ifeq ($(CHECK_RTI_LICENSE_FILE),)
CHECK_RTI_LICENSE_FILE := true
endif # ifeq ($(CHECK_RTI_LICENSE_FILE),)
# Export to make sure it's available to subprocesses
ifneq ($(RTI_LICENSE_FILE),)
override RTI_LICENSE_FILE := $(realpath $(RTI_LICENSE_FILE))
endif
export RTI_LICENSE_FILE

ifeq ($(UNO_MIDDLEWARE),)
EXPECT_MIDDLEWARE := uno.middleware.connext
else
EXPECT_MIDDLEWARE := $(UNO_MIDDLEWARE)
endif

ifneq ($(IN_DOCKER),)
IN_DOCKER_PREFIX := \
  docker run --rm \
		-v $(UNO_DIR):$(UNO_DIR) \
		$$([ -n "$(TEST_RELEASE)" -o -n "$(NO_LICENSE)" ] || \
		  printf -- '-v $(RTI_LICENSE_FILE):/rti_license.dat') \
    -w $(UNO_DIR) \
    -e VERBOSITY=$(VERBOSITY) \
    -e DEBUG=$(DEBUG) \
    -e EXPECT_MIDDLEWARE=$(EXPECT_MIDDLEWARE) \
    $(TEST_IMAGE)
override undefine EXPECT_MIDDLEWARE
else # ifneq ($(IN_DOCKER),)
IN_DOCKER_PREFIX :=
endif # ifneq ($(IN_DOCKER),)
export EXPECT_MIDDLEWARE

# export INTEGRATION_TEST_ARGS in case it's needed by a recursive call
export INTEGRATION_TEST_ARGS

.PHONY: \
  build \
  changelog \
  clean \
	code \
	code-check \
	code-format \
	code-format-check \
	code-style \
	code-style-check \
	deb \
	debtest \
  debuild \
	dockerimages \
	extract-license \
	fix-file-permissions \
  tarball \
	test \
	test-integration \
	test-unit \
	venv-install \
	code \
	code-check \
	code-format

# Perform all build tasks
build: build/default ;

# Build uno into a static binary using pyinstaller.sh
build/%: ../$(UPSTREAM_TARBALL)
	rm -rf $@ dist/bundle/$*
	mkdir -p dist/src
	tar -xvaf $< -C dist/src
	scripts/bundle/pyinstaller.sh $*

# Delete files generated by "build"
clean:
	rm -rf build

# Generate upstream archive
tarball: ../$(UPSTREAM_TARBALL) ;

../$(UPSTREAM_TARBALL):
	git ls-files --recurse-submodules | tar -cvaf $@ -T-

# Update changelog entry and append build codename to version
# Requires the Debian Builder image.
changelog:
	# Try to make sure changelog is at a clean version
	git checkout debian/changelog || true
	docker run --rm \
		-v $(UNO_DIR)/:/uno \
		-w /uno \
		$(DEB_BUILDER)  \
		/uno/scripts/bundle/update_changelog.sh

# Build uno's debian packages.
# Requires the Debian Builder image.
debuild:
	docker run --rm \
		-v $(UNO_DIR)/:/uno \
		-w /uno \
		$(DEB_BUILDER)  \
		/uno/scripts/debian_build.sh

# Run integration tests using the debian package.
# Requires the Debian Tester image
debtest: .venv
	$(MAKE) -C $(UNO_DIR) test-integration \
	  TEST_IMAGE=$(DEB_TESTER) \
	  TEST_RUNNER=runner

# Build the uno debian pacakge locally
deb:
	$(MAKE) -C $(UNO_DIR) debuild
	$(MAKE) -C $(UNO_DIR) dockerimage-debian-tester
	$(MAKE) -C $(UNO_DIR) debtest

# Run both unit and integration tests
test: test-unit test-integration ;

# Run unit tests
BASE_UNIT_TEST_COMMAND := \
  pytest -s -v \
    --junit-xml=$(TEST_RESULTS_DIR)/$(TEST_JUNIT_REPORT)__unit.xml \
    test/unit
# When run by a (non-release) CI test, the test image is expected 
# to contain an embedded RTI license at /rti_license.dat.
# To test without it, we must change the test command to delete
# the license.
ifeq ($(TEST_RELEASE),)
ifneq ($(NO_LICENSE),)
UNIT_TEST_COMMAND := \
	sh -exc '\
	rm -f /rti_license.dat; \
	unset RTI_LICENSE_FILE; \
	$(BASE_UNIT_TEST_COMMAND) $(UNIT_TEST_ARGS)'
endif # ifneq ($(NO_LICENSE),)
endif # ifeq ($(TEST_RELEASE),)
ifeq ($(UNIT_TEST_COMMAND),)
UNIT_TEST_COMMAND := $(BASE_UNIT_TEST_COMMAND) $(UNIT_TEST_ARGS)
endif # ifeq ($(UNIT_TEST_COMMAND),)

test-unit: .venv
	@$(CHECK_RTI_LICENSE_FILE)
	mkdir -p $(TEST_RESULTS_DIR)
	$(IN_DOCKER_PREFIX) $(UNIT_TEST_COMMAND)

# Run integration tests
test-integration: .venv
	@$(CHECK_RTI_LICENSE_FILE)
	mkdir -p $(TEST_RESULTS_DIR)
	$</bin/pytest -s -v \
		--junit-xml=$(TEST_RESULTS_DIR)/$(TEST_JUNIT_REPORT)__integration.xml \
		test/integration \
		$(INTEGRATION_TEST_ARGS)

# Change file ownership back to the current user
fix-file-ownership:
	docker run --rm \
	  -v $(FIX_DIR):/workspace \
	  $(TEST_IMAGE) \
	  fix-file-ownership $$(id -u):$$(id -g) /workspace

# Extract the license from a docker image to OUT_DIR
extract-license:
	docker run --rm \
	  -v $(OUT_DIR):/workspace \
	  $(TEST_IMAGE) \
	  cp /rti_license.dat /workspace/rti_license.dat

# Install uno and its dependencies in a virtual environment.
venv-install: .venv ;

# It would be nice to use poetry but there doesn't seem to be
# an easy and consistent way to install a working version in a
# virtual environment. Specifically, it seems to be a problem with
# calling poetry from the Makefile: the installed version will
# likely work from a normal shell, but when called from the makefile
# it starts behaving "weirdly", specifically, it seems like it
# starts looking for/trying to install packages in system directories,
# and then it either runs into version parsing error (because ubuntu
# published python packages with a version number incompatible with
# PEP440), or into a permission error (because it tries to write a
# system directory).
# For this reason, we are currently falling back to using a "plain"
# venv + pip to support automation, until a solution is found to
# make poetry work from the makefile.
# Developers can still use poetry, because, as mentrioned before,
# calling `poetry install` from a shell does seem to work. So, to
# bootstrap a local dev environments, the following should work:
#
#  make poetry
#
#  .venv-poetry/bin/poetry install --with=dev --with=connext
#
poetry: .venv-poetry ;
.venv-poetry:
	# curl -sSL https://install.python-poetry.org | POETRY_HOME=$$(pwd)/$@  python3 -
	python3 -m venv $@
	$@/bin/pip install -U pip setuptools virtualenv
	$@/bin/pip install poetry

ifneq ($(USE_POETRY),)
.venv: .venv-poetry \
       pyproject.toml \
       $(wildcard plugins/*/pyproject.toml)
	rm -rf $@ poetry.lock
	$</bin/poetry install --with=dev \
	  $$([ -n "$(UNO_MIDDLEWARE)" ] || printf -- --with=connext)
	$@/bin/pip install -e plugins/$(UNO_MIDDLEWARE)
else # ifneq ($(USE_POETRY),)
.venv: pyproject.toml \
       $(wildcard plugins/*/pyproject.toml)
	rm -rf $@
	python3 -m venv $@
	$@/bin/pip install -U pip setuptools ruff pre-commit
	$@/bin/pip install -e .
	[ -z "$(UNO_MIDDLEWARE)" ] || $@/bin/pip install -e plugins/$(UNO_MIDDLEWARE)
	[ -n "$(UNO_MIDDLEWARE)" ] || $@/bin/pip install rti.connext
endif # ifneq ($(USE_POETRY),)

# Build images required for development
dockerimages: \
  dockerimage-test-runner \
  dockerimage-debian-builder ;

# Convenience target to build an image with `docker compose build`
dockerimage-%:
	docker compose build $*


# Code validation targets
code: \
  code-style \
  code-format ;

code-check: \
  code-precommit ;

code-format: .venv
	$</bin/ruff format

code-format-check: .venv
	$</bin/ruff format --check

code-style: .venv
	$</bin/ruff check --fix

code-style-check: .venv
	$</bin/ruff check

code-precommit: .venv
	$</bin/pre-commit run --all
