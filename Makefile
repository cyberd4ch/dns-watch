.PHONY: test shellcheck install clean release-artifact

SCRIPT := dnswatch.sh

test:
	@echo "== dnswatch offline test suite (mock dig, no network) =="
	@bash tests/run_tests.sh

shellcheck:
	shellcheck $(SCRIPT) tests/run_tests.sh tests/mocks/dig \
		scripts/build-release-artifact.sh

install: $(SCRIPT)
	install -m 0755 $(SCRIPT) /usr/local/bin/dnswatch

clean:
	rm -rf tests/work

# Deterministic release tarball -> /tmp/dnswatch-<ver>.tar.gz + sha256.
# VER_TAG = HEAD|vX.Y.Z (defaults to HEAD). Same recipe CI's tap-bump runs.
release-artifact:
	@bash scripts/build-release-artifact.sh "$(VER_TAG)"