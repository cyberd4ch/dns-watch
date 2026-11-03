#!/usr/bin/env bash
# dnswatch offline test suite — runs dnswatch.sh against a mocked dig.
# No network access, no root, deterministic. Exit 0 = all scenarios pass.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
WORK="$HERE/work"
SCRIPT="$SRC/dnswatch.sh"
PASS=0; FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); say "  ok    - $1"; }
bad()  { FAIL=$((FAIL+1)); say "  FAIL  - $1"; }

assert_log_has() { # assert_log_has <logfile> <pattern> <label>
  if grep -q -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing pattern: $2)"; fi
}
assert_log_has_not() {
  if grep -q -- "$2" "$1" 2>/dev/null; then bad "$3 (unexpected pattern: $2)"; else ok "$3"; fi
}

fresh() {
  rm -rf "$WORK"; mkdir -p "$WORK"
  # Self-heal the exec bit: it is easy to lose in a tarball/copy, and if the
  # mock is not executable, PATH silently falls through to the REAL dig and
  # the suite produces confusing SKIP/CLEAN results from live DNS.
  chmod +x "$HERE/mocks/dig"
  # Fail loudly if the mock is not the dig that would actually be used.
  local resolved
  resolved="$(PATH="$HERE/mocks:$PATH" command -v dig)"
  if [ "$(cd "$HERE/mocks" && pwd)" != "$(dirname "$resolved")" ]; then
    bad "mock dig is not first on PATH (resolved: $resolved); aborting"
    say "results: $PASS passed, $FAIL failed"
    exit 1
  fi
  PATH="$HERE/mocks:$PATH"
  export MOCKDB="$WORK/mockdb.tsv"
  : > "$MOCKDB"
}

# ---------------------------------------------------------------- scenario 1
say "1. baseline then repeat run logs BASELINE + CLEAN"
fresh
cat <<'EOF' > "$WORK/targets.txt"
zt.test
auth.test
admin.test@MX
EOF
cat <<'EOF' >> "$MOCKDB"
zt.test	A	zt-edge.test,34.86.130.99
zt.test	CNAME	zt-edge.test
auth.test	A	13.248.244.122,76.223.106.8
auth.test	CNAME	auth-edge.testnet
admin.test	MX	mail.test
EOF
bash "$SCRIPT" -t "$WORK/targets.txt" -s "$WORK/state" -l "$WORK/watch.log" \
      -d test -c zt.test:34.86.130.99 >/dev/null 2>&1
sleep 1
bash "$SCRIPT" -t "$WORK/targets.txt" -s "$WORK/state" -l "$WORK/watch.log" \
      -d test -c zt.test:34.86.130.99 >/dev/null 2>&1
assert_log_has "$WORK/watch.log" "BASELINE" "baseline line written"
assert_log_has "$WORK/watch.log" "CLEAN" "repeat run logs CLEAN"
assert_log_has "$WORK/watch.log" "canary: none" "canary none under mock NXDOMAIN"
assert_log_has_not "$WORK/watch.log" "CHANGES" "no spurious CHANGES on repeat run"
snap1="$(find "$WORK/state" -name 'snapshot-*.txt' | sort | tail -n 1)"
if [ -n "$snap1" ]; then
  assert_log_has "$snap1" "admin.test MX -> .*mail.test" "record-type suffix line lands in snapshot"
else
  bad "record-type suffix line lands in snapshot (no snapshot found)"
fi

# ---------------------------------------------------------------- scenario 2
say "2. simulating resolver IP-order shuffling stays CLEAN"
fresh
cat <<'EOF' > "$WORK/targets.txt"
auth.test
EOF
cat <<'EOF' >> "$MOCKDB"
auth.test	A	13.248.244.122,76.223.106.8,edge.testnet
auth.test	CNAME	edge.testnet
EOF
bash "$SCRIPT" -t "$WORK/targets.txt" -s "$WORK/state" -l "$WORK/watch.log" >/dev/null 2>&1
sleep 1
DNSWATCH_MOCK_REVERSE=1 \
  bash "$SCRIPT" -t "$WORK/targets.txt" -s "$WORK/state" -l "$WORK/watch.log" >/dev/null 2>&1
assert_log_has "$WORK/watch.log" "CLEAN" "reverse answer order not a diff"

# ---------------------------------------------------------------- scenario 3
say "3. an actual record change logs a CHANGES block"
fresh
cat <<'EOF' > "$WORK/targets.txt"
auth.test
EOF
cat <<'EOF' >> "$MOCKDB"
auth.test	A	13.248.244.122,76.223.106.8
auth.test	CNAME	edge.testnet
EOF
bash "$SCRIPT" -t "$WORK/targets.txt" -s "$WORK/state" -l "$WORK/watch.log" >/dev/null 2>&1
sleep 1
# the estate deletes the record: both A and CNAME disappear.
# NOTE: grep -v exits 1 when it removes EVERY line, so mv must not depend
# on grep's status — use ; not && (this bit cost a debug cycle, keep it).
grep -v '^auth.test' "$MOCKDB" > "$MOCKDB.new"; mv "$MOCKDB.new" "$MOCKDB"
bash "$SCRIPT" -t "$WORK/targets.txt" -s "$WORK/state" -l "$WORK/watch.log" >/dev/null 2>&1
assert_log_has "$WORK/watch.log" "CHANGES" "record deletion surfaces CHANGES"
assert_log_has "$WORK/watch.log" "^  < auth.test" "diff shows the old answer"

# ---------------------------------------------------------------- scenario 4
say "4. resolver health control failure logs SKIP, not CHANGES"
fresh
cat <<'EOF' > "$WORK/targets.txt"
zone.test
EOF
cat <<'EOF' >> "$MOCKDB"
zone.test	A	1.2.3.4
EOF
bash "$SCRIPT" -t "$WORK/targets.txt" -s "$WORK/state" -l "$WORK/watch.log" \
      -c status9.test:10.9.9.9 >/dev/null 2>&1
sleep 1
grep -v '^zone' "$MOCKDB" > "$MOCKDB.new"; mv "$MOCKDB.new" "$MOCKDB"
bash "$SCRIPT" -t "$WORK/targets.txt" -s "$WORK/state" -l "$WORK/watch.log" \
      -c status9.test:10.9.9.9 >/dev/null 2>&1
assert_log_has "$WORK/watch.log" "SKIP" "control failure logs SKIP"
assert_log_has_not "$WORK/watch.log" "CHANGES" "SKIP run writes no diff"

# ---------------------------------------------------------------- scenario 5
say "5. bad invocations exit 2"
if bash "$SCRIPT" -t "$WORK/missing.txt" >/dev/null 2>&1; then
  bad "missing targets must fail"
else
  ok "missing targets exits non-zero"
fi
if bash "$SCRIPT" -t "$WORK/targets.txt" -c malformed >/dev/null 2>&1; then
  bad "bad -c must fail"
else
  ok "malformed control exits non-zero"
fi
bash "$SCRIPT" --version >/dev/null 2>&1 && ok "--version exits 0"

# ---------------------------------------------------------------- scenario 6
say "6. opt-in takeover tagging: dangling CNAME chain classified; nothing logs without -T"
fresh
cat <<'EOF' > "$WORK/targets.txt"
alive.test
dead.test
EOF
cat <<'EOF' >> "$MOCKDB"
alive.test	A	13.248.244.122
alive.test	CNAME	alive-edge.testnet
alive-edge.testnet	A	76.223.106.8
dead.test	CNAME	danglbucket.s3.amazonaws.com
EOF
# signature table with REAL tabs (printf interprets \t in the format string)
printf 's3.amazonaws.com\tAWS S3\tHTTP GET: body says NoSuchBucket\nherokuapp.com\tHeroku\tHTTP GET: body says No such app\n' > "$WORK/sigs.tsv"

bash "$SCRIPT" -t "$WORK/targets.txt" -s "$WORK/state" -l "$WORK/watch.log" >/dev/null 2>&1
assert_log_has_not "$WORK/watch.log" "takeover-candidate" "no -T: no takeover lines"
assert_log_has_not "$WORK/watch.log" "takeover-check" "no -T: no takeover summary"

bash "$SCRIPT" -t "$WORK/targets.txt" -s "$WORK/takstate" -l "$WORK/tak.log" \
      -T "$WORK/sigs.tsv" >/dev/null 2>&1
sleep 1
bash "$SCRIPT" -t "$WORK/targets.txt" -s "$WORK/takstate" -l "$WORK/tak.log" \
      -T "$WORK/sigs.tsv" >/dev/null 2>&1
assert_log_has "$WORK/tak.log" "takeover-candidate: dead.test -> danglbucket.s3.amazonaws.com" "dangling chain tagged as candidate"
assert_log_has "$WORK/tak.log" "provider=AWS S3" "signature table classified provider"
assert_log_has "$WORK/tak.log" "takeover-check: 1 dangling chain(s) of 2 aliased host(s)" "run summary line"
assert_log_has "$WORK/tak.log" "CLEAN" "second -T run still CLEAN (tagging outside snapshot)"
snap_a="$(find "$WORK/state" -name 'snapshot-*.txt' | sort | tail -n 1)"
snap_b="$(find "$WORK/takstate" -name 'snapshot-*.txt' | sort | tail -n 1)"
if [ -n "$snap_a" ] && [ -n "$snap_b" ] && diff -q "$snap_a" "$snap_b" >/dev/null 2>&1; then
  ok "snapshots identical with and without -T (content invariant intact)"
else
  bad "snapshots identical with and without -T (content invariant intact)"
fi

# ---------------------------------------------------------------- scenario 7
say "7. takeover drill: drift->candidate pipeline against the SHIPPED signatures.tsv"
# This is the end-to-end drill of the -T path: a provider-dangling chain
# fires its classification from the real table (not a fixture copy), the
# honest NOT-claimable label survives to the log, and a run that is both
# CHANGES and candidate-tagged proves tagging never eats the diff.
fresh
cat <<'EOF' > "$WORK/targets.txt"
steady.test
drift-s3.test
drift-fastly.test
EOF
cat <<'EOF' >> "$MOCKDB"
steady.test	CNAME	steady-edge.testnet
steady-edge.testnet	A	99.84.0.1
drift-s3.test	CNAME	live-bucket.s3.amazonaws.com
live-bucket.s3.amazonaws.com	A	52.94.0.1
drift-fastly.test	CNAME	live.fastly.net
live.fastly.net	A	151.101.0.1
EOF

bash "$SCRIPT" -t "$WORK/targets.txt" -s "$WORK/drillstate" -l "$WORK/drill.log" \
      -T "$SRC/signatures.tsv" >/dev/null 2>&1
assert_log_has_not "$WORK/drill.log" "takeover-candidate" "healthy buckets: no candidates at baseline"

sleep 1
# Run 2: both provider endpoints go dark && steady's CNAME is deleted.
# Three independent greps, each with || true-driven mv (see scenario 3 note).
grep -v '^live-bucket\.s3\.amazonaws\.com' "$MOCKDB" > "$MOCKDB.new"; mv "$MOCKDB.new" "$MOCKDB"
grep -v '^live\.fastly\.net' "$MOCKDB" > "$MOCKDB.new"; mv "$MOCKDB.new" "$MOCKDB"
grep -v '^steady\.test' "$MOCKDB" > "$MOCKDB.new"; mv "$MOCKDB.new" "$MOCKDB"
bash "$SCRIPT" -t "$WORK/targets.txt" -s "$WORK/drillstate" -l "$WORK/drill.log" \
      -T "$SRC/signatures.tsv" >/dev/null 2>&1

assert_log_has "$WORK/drill.log" "CHANGES" "steady CNAME deletion still fires CHANGES"
assert_log_has "$WORK/drill.log" "takeover-candidate: drift-s3.test -> live-bucket.s3.amazonaws.com \[provider=AWS S3 (static website bucket)\]" "S3 row classified by the shipped table"
assert_log_has "$WORK/drill.log" "verify: HTTP GET apex" "full verify-hint travels with the tag"
assert_log_has "$WORK/drill.log" "takeover-candidate: drift-fastly.test -> live.fastly.net \[provider=Fastly (community list: NOT claimable)\]" "NOT-claimable label preserved, not softened"
if [ "$(grep -c 'takeover-candidate: steady.test' "$WORK/drill.log")" -eq 0 ]; then
  ok "steady.test never mis-tagged (healthy, then unaliased)"
else
  bad "steady.test never mis-tagged (healthy, then unaliased)"
fi
assert_log_has "$WORK/drill.log" "takeover-check: 2 dangling chain(s) of 2 aliased host(s)" "drill summary counts"

say ""
say "results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
