ROOT := $(shell pwd)
BIN := $(ROOT)/bin
MCGRAB_SRC := $(ROOT)/deps/mcgrab
ZGRAB2_SRC := $(ROOT)/deps/zgrab2

.PHONY: all clean mcgrab zgrab2

all: clean mcgrab zgrab2

clean:
	@echo "[*] Cleaning binaries..."
	rm -rf -- $(BIN)
	mkdir -p -- $(BIN)

mcgrab:
	@echo "[*] Building mcgrab..."
	cd $(MCGRAB_SRC) && \
	go mod tidy && \
	GOOS=linux GOARCH=amd64 go build -o $(BIN)/mcgraber .

zgrab2:
	@echo "[*] Building zgrab2..."
	cd $(ZGRAB2_SRC) && \
	go build -o $(BIN)/zgrab2 ./cmd/zgrab2

	@chmod +x $(BIN)/zgrab2
	@echo "[*] zgrab2 installed to $(BIN)/zgrab2"
