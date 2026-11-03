# Contributing to dnswatch

Thanks for helping. dnswatch is a small, dependency-free bash tool, and
"small" is a design decision, not a limitation.

**This tool is and always will be free.** There are no paid tiers, no
premium gates, and there never will be a freemium split. If you want it to
keep existing, the best thing you can do is contribute a feature — or
[sponsor the project](#sponsorship) to fund a month of resolver costs.

## Setup

```bash
git clone <this repo> && cd dns-watch
make test        # offline mock-dig test suite; no network, no permissions
make shellcheck  # shellcheck on the script, the test runner and the dig mock
```

Requirements while developing: `bash`, `dig` (bind9-dnsutils / dnsutils /
bind-tools), `diff`, coreutils, and `shellcheck`. Everything runs on Linux
and macOS (including Apple's stock bash 3.2 — the script is written for it).

## The rules of the engine

If you touch `dnswatch.sh`, these invariants are non-negotiable. Each one
exists because removing it once produced a lying watcher (the birth-story
version) or a false `CHANGES` block (the resolver-flap version):

1. **TCP transport by default.** `--udp` exists only for parity with old
   resolver stacks. UDP under NAT packet loss made the same host flip
   between present and empty on consecutive runs.
2. **Sorted multi-record answers.** Resolver answer order is noise;
   "IPs shuffled" must never register as a diff.
3. **Timestamp-free snapshot content.** The timestamp lives in the
   filename only, so the diff is pure value-change.
4. **The health control refuses to diff on failure.** A resolver outage may
   never masquerade as real drift. A watcher that can lie is worse than no
   watcher; one that says `SKIP` is honest.
5. **The canary is logged outside the snapshot.** A fresh random label every
   run must never trip the diff.
6. **Exit codes stay as documented** (README): `0` = run completed,
   `2` = usage/config error.

Anything you add must keep the same property: **the log you can grep in
five seconds is the product.** Plain text, append-only, no dashboard
required.

## What you must keep zero

No runtime dependency may be added. The tool works with `bash`, `dig`,
`diff` and standard coreutils — that is the whole allowed list. If your
change needs Python, a package manager, a daemon, a config file format, or
any network call other than `dig`, it does not belong in `dnswatch.sh`.

Proposing a feature? Open an issue first with one sentence: *does this keep
the tool free to run and free to maintain?* A feature the maintainer can't
support for free stays unshipped — please don't take that personally; it's
the whole point of the project.

## Good first contributions

These are the spots the roadmap reserves for first-timers — self-contained,
tested offline, and no engine surgery required:

* **Takeover-fingerprint signature table** (roadmap M2 — prototype shipped
  in v1.1.0 as the opt-in `-T signatures.tsv` flag). The matcher walks CNAME
  chains and tags dangling links as candidates; `signatures.tsv` holds the
  provider fingerprints. The first-timer surface now is the table itself:
  add providers whose fingerprints you can verify are stable, and harden
  the matcher's edges (CNAME chains with multiple records, NODATA vs
  NXDOMAIN, more mocked-dig scenarios). **Accuracy rule:** the table must
  be pluggable and conservative — an honest output about uncertainty beats
  a loud wrong "takeover candidate!". A false positive here is worse than
  a quiet negative, so keep the `verify:` hints pointing at manual checks;
  the tool never sends the verification request itself.
* **Packaging** (roadmap M3). Homebrew formula, GitHub Action
  (`dnswatch/dnswatch-action`-style, cron in the workflow), nix package.
  Each is one install away from a new user.
* **Portability.** The suite runs on Apple's stock bash 3.2 and modern
  Linux coreutils. Every portability fix that survives both is welcome.
* **Test coverage.** The mocked-`dig` suite (`tests/run_tests.sh`,
  `tests/mocks/dig`) is the harness for scenarios 4+: a `SKIP`-recovery
  scenario (health control failing, then passing) and a canary-hit scenario
  (non-none canary in run 2) are the two most wanted.

## Pull requests

* Keep PRs small and single-purpose. One scenario, one diff.
* All three checks must pass on your branch: `make test`, `make shellcheck`,
  and — if the log output changed — a re-read of the README examples (copy
  its sample `dns-watch.log` if the format moved).
* Local and CI shellcheck versions differ; the CI one is older and flags
  info-level findings (SC2015-style `A && B || C`) that newer local versions
  may not. If CI goes red while your local gate is green, read the CI log —
  fix the finding at the root; never suppress it.
* If you added or changed a documented behavior, update `README.md` in the
  same PR. The README is the manual; there is no wiki.
* No signing-off ceremony: MIT license, your PR, your code. By contributing
  you confirm it is yours to license under the existing MIT terms.

## Sponsorship

If dnswatch has saved you a session of re-reconning (or caught a CNAME going
stale), the GitHub Sponsors link in the README funds a month of resolver
and hosted-instance costs. Sponsors and contributors get equal-standing
shout-outs in the release notes — free project, flat hierarchy.
