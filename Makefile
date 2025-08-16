# Simple entrypoints for normal users

.PHONY: all install status reset-auto reset-addresses read-counters

all: install

install:
	chmod +x epson.sh scripts/common.sh scripts/epson_status.sh scripts/epson_reset.sh
	@echo "Bootstrapping environment (first run may take a moment)..."
	@./epson.sh status >/dev/null || true
	@echo "Install complete. Try: ./epson.sh status"

status:
	./epson.sh status

reset-auto:
	./epson.sh reset --auto

# Usage: make reset-addresses ADDRS="0x2f,0x30,0x31"
reset-addresses:
	@test -n "$(ADDRS)" || (echo "ADDRS is required, e.g. make reset-addresses ADDRS=0x2f,0x30" && exit 1)
	./epson.sh reset --addresses $(ADDRS)

# Convenience read without resetting (sudo may be required on macOS)
read-counters:
	LATEST=$$(ls -1t logs/STATUS_*.log 2>/dev/null | head -n1); \
	ADDRS=$$( [ -n "$$LATEST" ] && grep -oE 'WASTE_ADDRS:\\s*0x[0-9a-fA-F]{1,2}(,0x[0-9a-fA-F]{1,2})*' "$$LATEST" | sed -E 's/^WASTE_ADDRS:\\s*//' | tr ',' ' ' ); \
	[ -z "$$ADDRS" ] && ADDRS="0x2f 0x30 0x31 0x32 0x33 0x34 0x35 0x36 0x37"; \
	echo "Reading: $$ADDRS"; \
	printf '%s\n' $${=ADDRS} | sudo ./.env/bin/python3 -c 'import sys; from reinkpy import UsbDevice; addrs=[int(l.strip(),16) for l in sys.stdin if l.strip()]; d=next(UsbDevice.ifind(), None); assert d, "No USB device"; e=d.epson; res=e.read_eeprom(*addrs);\
	print("CURRENT WASTE COUNTERS:");\
	[print(f" - addr 0x{a:02x} = "+("NA" if v is None else f"0x{v:02x}")+" ("+("NA" if v is None else f"{(v/255.0)*100:.1f}%")+")") for a,v in res]'
