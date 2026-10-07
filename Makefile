# MacStats: a Swift package built with the Xcode Command Line Tools alone.
#
#   make app        builds build/MacStats.app (release)
#   make install    builds and installs it into ~/Applications with a login agent (install.sh)
#   make uninstall  removes it and the login agent
#   make test       builds a debug MacStats and runs the test program against it
#   make clean
#
# SWIFT_FLAGS passes extra flags to swift build; Homebrew's formula sets --disable-sandbox.

SWIFT_FLAGS ?=

.PHONY: build app install uninstall test clean

build:
	swift build -c release $(SWIFT_FLAGS)

app: build
	sh scripts/bundle.sh .build/release/MacStats

install:
	sh install.sh

uninstall:
	sh install.sh --uninstall

test:
	swift build $(SWIFT_FLAGS)
	.build/debug/MacStatsTests

clean:
	rm -rf .build build
