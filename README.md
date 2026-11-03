# dnswatch

[![tests](https://github.com/cyberd4ch/dns-watch/actions/workflows/tests.yml/badge.svg)](https://github.com/cyberd4ch/dns-watch/actions/workflows/tests.yml)
[![tag](https://img.shields.io/github/v/tag/cyberd4ch/dns-watch?style=flat-square)](https://github.com/cyberd4ch/dns-watch/tags)
[![license](https://img.shields.io/github/license/cyberd4ch/dns-watch?style=flat-square)](./LICENSE)

A small, dependency-free DNS drift watcher: point it at a list of hostnames
and a cron schedule, and it tells you — in a plain-text log — whenever
anything in that list changes. Built originally to watch a bug-bounty
estate between sessions, where *nobody looked at DNS for days at a time*
was exactly how a takeoverable subdomain or a quietly-launched internal
service would go unnoticed.

```
$ dnswatch.sh -t targets.txt -s state/ -l dns-watch.log \
      -d example.com -c status.example.com:203.0.113.7
dnswatch: done. snapshot=state/snapshot-20261028T205106Z.txt log=dns-watch.log

$ cat dns-watch.log
BASELINE 20261028T205106Z; canary: none
CLEAN 20261028T220106Z; canary: none
CHANGES 20261029T040206Z (vs snapshot-20261028T220106Z.txt):
  < auth-testing.example.com A -> 13.248.244.122;... CNAME -> custom.example-cdn.net.;
  > auth-testing.example.com A -> "" CNAME -> ""
canary: none (non-none = wildcard record appeared)
```

A dangling CNAME or a vanished A record (the classic subdomain-takeover
precursor) shows up as a `CHANGES` line the next time cron fires — without
you having to remember to dig.

## Why not just look at DNS?

Because recon gives you a snapshot, not a movie. Between two sessions:

* a CNAME can go stale (takeover-able!)
* a wildcard `*.domain` can appear (new phishing-real-estate)
* a hostname you logged as "doesn't exist yet" can go live
* multi-record A answers can (visibly) shuffle IP order

dnswatch turns all four into a plain-text diff you can read in five seconds.

## What's in the box

* **Sorted multi-record answers** — A-record records are thrown back in a
  different order at the whim of the resolver; sorting them keeps "IP order
  changed" from registering as a diff.
* **Timestamp in the filename only** — snapshot *content* is timestamp-free,
  so the diff is pure value-change; no per-run header noise.
* **TCP transport by default** (`dig +tcp`) — UDP under NAT packet loss made
  the same host flip between present and empty on consecutive runs. TCP is
  impervious to that; `--udp` exists only for parity.
* **Resolver fallback chain** — 1.1.1.1 → 8.8.8.8 → system resolver, first
  non-empty answer wins (configurable via `DNSWATCH_RESOLVERS`).
* **Resolver health control** (`-c name:ip`) — a known-stable answer must
  resolve or the run logs `SKIP` and refuses to diff. This is what makes the
  tool trustworthy: a resolver outage can no longer masquerade as real
  drift.
* **Wildcard canary** (`-d domain`) — resolves a fresh random label each
  run; non-empty = a wildcard record appeared on the zone. Logged outside
  the snapshot so random labels never trip the diff.

## Install

Four supported paths; all land on the same one-file `dnswatch` binary.

**Homebrew** — the tag-pinned, sha256-verified route:

```bash
brew install cyberd4ch/dnswatch/dnswatch
# signature table lands at $(brew --prefix)/share/dnswatch/signatures.tsv
# (pass that path to -T; requires dig, which macOS ships)
```

**From source (recommended for contributors)** — keeps the test suite one
`make test` away:

```bash
git clone https://github.com/cyberd4ch/dns-watch.git && cd dns-watch
make test     # runs the offline mock-dig test suite; no network needed
sudo make install
```

**Manual single file** — one script, no git, no checkout; review it first,
it is ~170 lines of shell:

```bash
curl -sSL https://raw.githubusercontent.com/cyberd4ch/dns-watch/main/dnswatch.sh \
      -o /tmp/dnswatch
less /tmp/dnswatch                      # your eyeballs are the checksum
sudo install -m 0755 /tmp/dnswatch /usr/local/bin/dnswatch
rm /tmp/dnswatch
```

**Release tarball** — pinned copy of a tagged version, no `main` drift:

```bash
curl -sSL https://github.com/cyberd4ch/dns-watch/archive/refs/tags/v1.1.0.tar.gz \
      | tar -xz && cd dns-watch-1.1.0
sudo make install
```

If you want takeover tagging (`-T`), also put `signatures.tsv` somewhere
permanent and pass its path; the file is data, not part of the binary and
is extended by the community over time.

### Sanity check

```bash
dnswatch --version
dnswatch -t targets.list.example -s /tmp/dw-state -l /tmp/dw.log
```

Requirements: `bash`, `dig` (bind9-dnsutils / bind-tools / `dnsutils` package),
`diff`, standard coreutils. Everything runs on Linux/macOS. macOS ships
`dig`; on Debian/Ubuntu it is `apt install bind9-dnsutils`, on Alpine
`apk add bind-tools`, and Linuxbrew users want `brew install bind`.

## Usage

```bash
# one-off baseline + diff into ~/watch
dnswatch.sh -t targets.list.example -s ~/watch/state -l ~/watch/log -d example.net

# production cron (every 6h at :17)
crontab -e
17 */6 * * * /usr/local/bin/dnswatch.sh -t /etc/dnswatch/targets.txt \
      -s /var/lib/dnswatch/state -l /var/log/dnswatch.log \
      -d mytarget.com -c status.mytarget.com:203.0.113.7
```

Exit codes: `0` = run completed (check the log for BASELINE/CLEAN/CHANGES/SKIP),
`2` = bad invocation (missing targets file, malformed `-c`, etc.).

Targets may carry a record-type suffix (`name@MX`, `name@NS`, `name@TXT`) to
watch that single record type instead of A+CNAME — the way to keep an eye on
apex records (MX or A appearing on a zone that should stay quiet).

## Takeover candidate tagging (experimental, opt-in)

`-T signatures.tsv` adds the thing the drift log alone can't say. After
every run, each watched host that carries a CNAME gets its alias chain
walked the way a resolver would — CNAME hop to next name, depth 5. A chain
link that answers nothing for CNAME, A and NS alike (the classic
subdomain-takeover precursor) gets tagged:

```
takeover-candidate: dead.example.com -> danglbucket.s3.amazonaws.com \
[provider=AWS S3] verify: HTTP GET apex: body says NoSuchBucket; ...
takeover-check: 0 dangling chain(s) of 21 aliased host(s) watched
```

Same invariants as the rest of the tool:

* **DNS only.** The tool never sends the verification request itself — the
  `verify:` hint is the manual step for the human. Output stays a
  *candidate*, not a verdict; a loud wrong "takeover candidate!" is worse
  than a quiet one.
* **Snapshot content and exit codes are untouched.** Tag lines go to the
  change log only, so `-T` can never create or suppress a `CHANGES` diff.
* **Pluggable classification.** `signatures.tsv` is a data file: suffix,
  provider, verify-hint — longest matching suffix wins. Extending it is the
  natural first contributor surface (see `CONTRIBUTING.md` for what makes
  a good row). Suffixes with no row log `provider=unknown`.

```bash
dnswatch.sh -t targets.txt -s state -l dns-watch.log -T signatures.tsv
```

## Tests

`make test` runs six scenarios against a **mocked `dig`** (no network, no
permissions needed):

1. baseline + repeat run → `BASELINE` then `CLEAN`; the canary reports
   `none` under mock NXDOMAIN
2. simulated resolver shuffling of a multi-record answer between runs →
   still `CLEAN` (this is the sorted-answer invariant in action)
3. an injected record change between runs → `CHANGES` block logs the
   exact `diff` of the two snapshots
4. failing health control → `SKIP`, no diff written
5. bad invocations exit `2` (missing targets file, malformed `-c`);
   `--version` exits `0`
6. the takeover drill: a provider endpoint goes dark between runs and the
   target gets classified **by the shipped `signatures.tsv`** — including a
   `NOT claimable` provider logging its honest label instead of a soft one —
   while an unrelated deletion still fires `CHANGES` in the same run

CI runs the same six scenarios plus `shellcheck` on every push
(`.github/workflows/tests.yml`).

## Origin & honesty section

This was written for and battle-tested during a real engagement, where the
original v2 (UDP, no health control) produced false `CHANGES` under NAT
resolver flaps and v3 burned five minutes per run chasing a blackholed
9.9.9.9. The final design is the boring, correct one: TCP, sorted answers,
a control that refuses to lie. If you find the idea derivative: yes —
`dnstwist` finds lookalikes, takeover tools check one instant in time, and
Detectify/SecurityTrails monitor at SaaS prices. dnswatch is the five-minute,
readable-log middle ground for one box and one cron entry.License: MIT. See `LICENSE`.

## Sponsorship

dnswatch is free forever — no tiers, no premium gates. The Sponsor button
(this repo's `FUNDING.yml`) funds a month of resolver and hosted-instance
costs when the [Sponsors profile](https://github.com/sponsors/cyberd4ch)
accepts payouts; contributions to the signature table and packaging count
for more than money does.
