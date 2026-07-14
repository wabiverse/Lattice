# ----------------------------------------------------------------
#  Lattice
# ----------------------------------------------------------------

PRODUCT_NAME = LatticeDemo
VERSION = $(version)

PREFIX ?= /usr/local

CD = cd
CP = /bin/cp -Rf
GIT = /usr/bin/git
MKDIR = /bin/mkdir -p
RM = /bin/rm -rf
SED = /usr/bin/sed
SWIFT ?= $(shell xcrun -f swift 2>/dev/null || which swift)
ZIP = /usr/bin/zip -r

SHARED_SWIFT_BUILD_FLAGS = --configuration release --disable-sandbox --product $(PRODUCT_NAME)

VERSION_FILE = Sources/LatticeCore/Version.swift

# Optional stage to open in the demo:  make run usd=/path/to/stage.usda
# Expands to `--usd <path>` when `usd` is set, and to nothing when it isn't,
# so `make run` with no argument launches the demo with its built-in scene.
usd ?=
USD_ARG = $(if $(usd),--usd $(usd),)

.PHONY: help
help:
	@echo "usage: make [target]"
	@echo ""
	@echo "targets:"
	@echo "  headers                  regenerate the wabi/ Swift->C++ interop headers"
	@echo "  build                    build LatticeDemo in release mode (regenerates headers first)"
	@echo "  run [usd=PATH]           run LatticeDemo (optionally opening a .usda/.usdc stage)"
	@echo "  test                     run the test suite"
	@echo "  install                  install LatticeDemo to \$$PREFIX/bin (default: /usr/local/bin)"
	@echo "  uninstall                remove LatticeDemo from \$$PREFIX/bin"
	@echo "  clean                    clean build artifacts"
	@echo "  package-darwin-arm64     package for macOS arm64"
	@echo "  package-darwin-x86_64    package for macOS x86_64"
	@echo "  package-darwin-universal package universal macOS binary"
	@echo "  package-linux-x86_64     package for Linux x86_64"
	@echo "  package-linux-arm64      package for Linux arm64"
	@echo "  release version=X.Y.Z    tag and push a release"
	@echo ""
	@echo "examples:"
	@echo "  make run"
	@echo "  make run usd=~/scenes/kitchen.usda"

.PHONY: all
all: build

# Regenerate the wabi/ Swift->C++ interop headers so the checked-in headers
# never drift from the Swift sources. Everything that compiles depends on this.
.PHONY: headers
headers:
	$(SWIFT) scripts/generate_wabi_headers.swift

.PHONY: build
build: headers
	$(SWIFT) build $(SHARED_SWIFT_BUILD_FLAGS)

# Runs in release.
.PHONY: run
run: headers
	$(SWIFT) run --configuration release --disable-sandbox $(PRODUCT_NAME) $(USD_ARG)

.PHONY: test
test: headers
	$(SWIFT) test

.PHONY: install
install: build
	$(eval BUILD_DIRECTORY := $(shell $(SWIFT) build --show-bin-path $(SHARED_SWIFT_BUILD_FLAGS)))
	$(MKDIR) $(PREFIX)/bin
	$(CP) "$(BUILD_DIRECTORY)/$(PRODUCT_NAME)" "$(PREFIX)/bin"

.PHONY: uninstall
uninstall:
	$(RM) "$(PREFIX)/bin/$(PRODUCT_NAME)"

.PHONY: clean
clean:
	$(SWIFT) package clean

.PHONY: package-darwin-arm64
package-darwin-arm64:
	$(eval TRIPLE := arm64-apple-macosx)
	$(eval FLAGS := $(SHARED_SWIFT_BUILD_FLAGS) --triple $(TRIPLE))
	$(eval DIR := $(shell $(SWIFT) build --show-bin-path $(FLAGS)))
	$(SWIFT) build $(FLAGS)
	$(CD) "$(DIR)" && $(ZIP) "$(PRODUCT_NAME).zip" "$(PRODUCT_NAME)"

.PHONY: package-darwin-x86_64
package-darwin-x86_64:
	$(eval TRIPLE := x86_64-apple-macosx)
	$(eval FLAGS := $(SHARED_SWIFT_BUILD_FLAGS) --triple $(TRIPLE))
	$(eval DIR := $(shell $(SWIFT) build --show-bin-path $(FLAGS)))
	$(SWIFT) build $(FLAGS)
	$(CD) "$(DIR)" && $(ZIP) "$(PRODUCT_NAME).zip" "$(PRODUCT_NAME)"

.PHONY: package-darwin-universal
package-darwin-universal:
	$(eval X86_FLAGS := $(SHARED_SWIFT_BUILD_FLAGS) --triple x86_64-apple-macosx)
	$(eval X86_DIR := $(shell $(SWIFT) build --show-bin-path $(X86_FLAGS)))
	$(SWIFT) build $(X86_FLAGS)

	$(eval ARM_FLAGS := $(SHARED_SWIFT_BUILD_FLAGS) --triple arm64-apple-macosx)
	$(eval ARM_DIR := $(shell $(SWIFT) build --show-bin-path $(ARM_FLAGS)))
	$(SWIFT) build $(ARM_FLAGS)

	$(MKDIR) release
	lipo -create -output "release/$(PRODUCT_NAME)" \
	"$(X86_DIR)/$(PRODUCT_NAME)" \
	"$(ARM_DIR)/$(PRODUCT_NAME)"
	$(ZIP) "release/$(PRODUCT_NAME).zip" "release/$(PRODUCT_NAME)"

.PHONY: package-linux-x86_64
package-linux-x86_64:
	$(eval TRIPLE := x86_64-unknown-linux-gnu)
	$(eval FLAGS := $(SHARED_SWIFT_BUILD_FLAGS) --triple $(TRIPLE))
	$(eval DIR := $(shell $(SWIFT) build --show-bin-path $(FLAGS)))
	$(SWIFT) build $(FLAGS)
	tar --directory "$(DIR)" --create --xz --file "$(PRODUCT_NAME).tar.xz" "$(PRODUCT_NAME)"

.PHONY: package-linux-arm64
package-linux-arm64:
	$(eval TRIPLE := aarch64-unknown-linux-gnu)
	$(eval FLAGS := $(SHARED_SWIFT_BUILD_FLAGS) --triple $(TRIPLE))
	$(eval DIR := $(shell $(SWIFT) build --show-bin-path $(FLAGS)))
	$(SWIFT) build $(FLAGS)
	tar --directory "$(DIR)" --create --xz --file "$(PRODUCT_NAME).tar.xz" "$(PRODUCT_NAME)"

.PHONY: release
release:
ifeq ($(strip $(VERSION)),)
	@echo "error: version is required, e.g. 'make release version=1.2.3'"; exit 1
endif
	$(SED) -i '' 's/version = ".*"/version = "$(VERSION)"/' $(VERSION_FILE)
	$(GIT) add $(VERSION_FILE)
	$(GIT) commit -m "Bump version to $(VERSION)"
	$(GIT) push origin main
	$(GIT) tag $(VERSION)
	$(GIT) push origin $(VERSION)
