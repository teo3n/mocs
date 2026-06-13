BIN := mocsd
SRC := main.mm

CXX := clang++
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc
FRAMEWORKS := -framework Cocoa -framework ApplicationServices -framework Carbon

PREFIX ?= $(HOME)/.local

# set to a self-signed identity name
CODESIGN_IDENTITY ?= -

all: $(BIN)

$(BIN): $(SRC)
	$(CXX) $(CXXFLAGS) $(FRAMEWORKS) -o $@ $<
	codesign --force --sign "$(CODESIGN_IDENTITY)" $@

install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/$(BIN)

clean:
	rm -f $(BIN)

.PHONY: all install clean
