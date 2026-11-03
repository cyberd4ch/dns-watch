.PHONY: test shellcheck install clean

SCRIPT := dnswatch.sh

test:
	@echo "== dnswatch offline test suite (mock dig, no network) =="
	@bash tests/run_tests.sh

shellcheck:
	shellcheck $(SCRIPT) tests/run_tests.sh tests/mocks/dig

install: $(SCRIPT)
	install -m 0755 $(SCRIPT) /usr/local/bin/dnswatch

clean:
	rm -rf tests/work
