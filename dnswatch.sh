#!/usr/bin/env bash
# dnswatch — DNS drift watcher for bug-bounty scopes and personal infra.
#
# Built during an actual bug-bounty engagement after a recon pass kept
# producing inconsistent snapshots. Survives NAT-blackholed resolvers,
# flaky system DNS, and burst-load UDP packet loss (see README "Why TCP").
#
# What it does:
#   * takes a targets file of hostnames (one FQDN per line, # comments ok)
#   * records A + CNAME for each host into a state snapshot (timestamped
#     file, timestamp-free CONTENT so diffs surface value changes only)
#   * diffs the newest snapshot vs the previous one and appends a summary
#     to a change log (CHANGES block, or a CLEAN line when nothing moved)
#   * optionally watches a wildcard canary: a fresh random label each run
#     (a non-empty answer means a wildcard record appeared)
#   * optionally gates every run with a resolver health control: a known
#     stable name:ip pair must resolve correctly or the run logs SKIP and
#     refuses to diff (prevents flaky-DNS false positives)
#
# Exits: 0 on any completed run (BASELINE/CLEAN/CHANGES/SKIP all log),
#        2 on usage/config errors (missing targets file, bad control spec).
set -u

VERSION="1.1.1"
DIG_TIME="${DNSWATCH_DIG_TIME:-3}"
# "" (system resolver) is always tried LAST, whether or not it is listed.
RESOLVERS=" ${DNSWATCH_RESOLVERS:-@1.1.1.1 @8.8.8.8} "

UDP_MODE=0
TARGETS_FILE=""
STATE_DIR=""
LOG_FILE=""
CANARY_DOMAIN=""
CONTROL_SPEC=""
TAKEOVER_SPEC=""

usage() {
  cat <<USAGE
dnswatch ${VERSION} — record & diff the DNS posture of a list of hosts.

Usage: dnswatch.sh -t targets.txt [-s state-dir] [-l log-file]
                   [-d canary-domain] [-c name:ip] [--udp] [-h]

Required:
  -t, --targets FILE    One FQDN per line. Blank lines and #comments skipped.
                        Optional record-type suffix: name@MX / name@NS / name@TXT
                        / name@A / name@CNAME watch that single record type
                        instead of A+CNAME (e.g. apex MX/Ns appearance).

Optional:
  -s, --state DIR       Snapshot directory (default: ./dns-state)
  -l, --log FILE        Change log, append-only (default: ./dns-watch.log)
  -d, --canary DOMAIN   Wildcard-watch: a fresh random label under DOMAIN is
                        resolved every run; non-empty answer = wildcard found.
                        The canary is logged OUTSIDE the snapshot so a fresh
                        random label never trips the diff.
  -c, --control NAME:IP Resolver health gate. If querying NAME for A does not
                        include IP, the run logs SKIP and does NOT write a
                        diff (protects against resolver outages producing
                        false CHANGES).
  --udp                 Use UDP instead of TCP (TCP is the default because it
                        survives NAT packet loss; --udp exists for parity with
                        very old resolver stacks).
  -T, --takeover FILE   EXPERIMENTAL takeover-candidate tagging. After each
                        run, every watched host carrying a CNAME gets its alias
                        chain walked (DNS only); a link in the chain that
                        answers nothing logs a takeover-candidate line,
                        classified by the signature table in FILE (TSV:
                        suffix<TAB>provider<TAB>verify-hint, longest suffix wins;
                        ships as signatures.tsv). The tool never sends the
                        verification request itself; snapshot content and exit
                        codes are unaffected.
  -V, --version         Print version.
  -h, --help            This text.

Environment:
  DNSWATCH_RESOLVERS    Space-separated dig resolver args. Default:
                        '@1.1.1.1 @8.8.8.8' with the system resolver last.
  DNSWATCH_DIG_TIME     Per-query dig timeout seconds (default 3).

Cron example (every 6 hours at :17):
  17 */6 * * * /usr/local/bin/dnswatch.sh -t /etc/dnswatch/targets.txt \\
      -s /var/lib/dnswatch/state -l /var/log/dnswatch.log \\
      -d example.com -c status.example.com:203.0.113.7
USAGE
}

die() { echo "dnswatch: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    -t|--targets)  TARGETS_FILE="${2-}";    case "${2-}" in -*) shift 1;; *) shift 2;; esac ;;
    -s|--state)    STATE_DIR="${2-}";       case "${2-}" in -*) shift 1;; *) shift 2;; esac ;;
    -l|--log)      LOG_FILE="${2-}";        case "${2-}" in -*) shift 1;; *) shift 2;; esac ;;
    -d|--canary)   CANARY_DOMAIN="${2-}";   case "${2-}" in -*) shift 1;; *) shift 2;; esac ;;
    -c|--control)  CONTROL_SPEC="${2-}";    case "${2-}" in -*) shift 1;; *) shift 2;; esac ;;
    -T|--takeover) TAKEOVER_SPEC="${2-}";   case "${2-}" in -*) shift 1;; *) shift 2;; esac ;;
    --udp)         UDP_MODE=1; shift ;;
    -V|--version)  echo "$VERSION"; exit 0 ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown argument: $1 (see --help)" ;;
  esac
done

[ -n "$TARGETS_FILE" ] || die "-t targets file is required"
[ -f "$TARGETS_FILE" ] || die "targets file not readable: $TARGETS_FILE"
STATE_DIR="${STATE_DIR:-$PWD/dns-state}"
LOG_FILE="${LOG_FILE:-$PWD/dns-watch.log}"

CONTROL_NAME="" CONTROL_IP=""
if [ -n "$CONTROL_SPEC" ]; then
  case "$CONTROL_SPEC" in
    *:*) CONTROL_NAME="${CONTROL_SPEC%%:*}"; CONTROL_IP="${CONTROL_SPEC##*:}" ;;
    *)   die "-c expects NAME:IP (got: $CONTROL_SPEC)" ;;
  esac
  if [ -z "$CONTROL_NAME" ] || [ -z "$CONTROL_IP" ]; then
    die "-c name and ip must both be non-empty in: $CONTROL_SPEC"
  fi
fi

if [ -n "$TAKEOVER_SPEC" ]; then
  [ -f "$TAKEOVER_SPEC" ] || die "-T signatures table not readable: $TAKEOVER_SPEC"
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$STATE_DIR" || die "cannot create state dir: $STATE_DIR"
SNAP="$STATE_DIR/snapshot-$TS.txt"
# Snapshots are named by UTC timestamp, so lexical order == chronological
# order: "newest by name" is deterministic and immune to mtime quirks.
PREV="$(find "$STATE_DIR" -maxdepth 1 -name 'snapshot-*.txt' -type f | sort | tail -n 1)"

# dig1 <name> <rrtype> — first non-empty answer across the resolver chain,
# sorted so multi-record answer ORDER can never produce a false diff.
# A genuinely empty answer (NXDOMAIN / NODATA) returns "" on purpose.
dig1() {
  local h="$1" rr="$2" out="" r
  for r in $RESOLVERS ""; do
    [ -z "$r" ] || r="@${r#@}"
    # Build the dig argv as an array so the empty-resolver fallthrough stays
    # a NON-argument (unquoted $TRANSPORT/$r would split or vanish wrongly).
    local -a dargs=(+short +time="${DIG_TIME}" +tries=1 "$rr" "$h")
    [ "$UDP_MODE" = 1 ] || dargs=("+tcp" "${dargs[@]}")
    [ -n "$r" ] && dargs=("${dargs[@]}" "$r")
    out="$(dig "${dargs[@]}" 2>/dev/null \
      | grep -v '^;;' | sed '/^$/d')"
    [ -n "$out" ] && break
  done
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | sort | tr '\n' ';'
  fi
}

# ---- takeover candidate tagging (opt-in -T FILE) ----------------------------
# DNS-only candidate detection: walk every watched host's CNAME chain; a link
# that answers nothing for CNAME, A and NS alike is reported as a
# takeover-candidate, classified against a signature table
# (TSV: suffix<TAB>provider<TAB>verify-hint, longest suffix wins; ships as
# signatures.tsv). The tool never sends the verification request itself, so
# output stays a candidate, not a verdict. Snapshot content and exit codes
# are unaffected: lines go to the change log only.

# tak_classify <name> — echo classification of a dangling name:
#   <suffix>|<provider>|<verify-hint>   (suffix=unknown when no row matches)
tak_classify() {
  local name="$1" row s p v best="" prov="" hint=""
  while IFS=$'\t' read -r s p v; do
    row="$s"
    case "$row" in ''|'#'*) continue ;; esac
    s="${s%.}"
    case "$name" in
      "$s"|*."$s")
        if [ "${#s}" -gt "${#best}" ]; then
          best="$s"; prov="$p"; hint="${v:-}"
        fi
        ;;
    esac
  done < "$TAKEOVER_SPEC"
  if [ -z "$best" ]; then
    best="unknown"; prov="unknown"
    hint="verify manually (HTTP GET the name; match body against the hosting service of record)"
  fi
  printf '%s|%s|%s\n' "$best" "$prov" "$hint"
}

# tak_check <host> — echo one line telling the caller how <host>'s alias
# chain ended:
#   ALIVE                       — host carries a CNAME and every link resolves
#   DEAD|name|suffix|prov|hint  — a chain link answers nothing (candidate)
#   (nothing)                   — host carries no CNAME at all
# Depth limit 5. All communication via stdout: tak_check runs in a command
# substitution, so variable side effects can never reach the caller.
tak_check() {
  local h="$1" cur="$1" alias a ns i=0
  while [ "$i" -lt 5 ]; do
    i=$((i+1))
    alias="$(dig1 "$cur" CNAME)"
    case "${alias:-}" in
      ''|none) : ;;
      *)
        cur="${alias%%;*}"
        cur="${cur%.}"
        continue
        ;;
    esac
    if [ "$cur" = "$h" ]; then
      return 0   # no CNAME anywhere: nothing to dangle
    fi
    a="$(dig1 "$cur" A)"
    case "${a:-}" in ''|none) : ;; *) echo "ALIVE"; return 0 ;; esac
    ns="$(dig1 "$cur" NS)"
    case "${ns:-}" in ''|none) : ;; *) echo "ALIVE"; return 0 ;; esac
    # A link that answers nothing at all: dangles.
    printf 'DEAD|%s|' "$cur"
    tak_classify "$cur"
    return 0
  done
}

# Resolver health control: when configured and failing, SKIP and do not diff.
ctrl=""
if [ -n "$CONTROL_NAME" ]; then
  ctrl="$(dig1 "$CONTROL_NAME" A)"
  case ";$ctrl" in
    *";$CONTROL_IP;"*) : ;;
    *)
      echo "SKIP $TS — resolver health control failed for $CONTROL_NAME (got: ${ctrl:-nothing}, expected: $CONTROL_IP)" >> "$LOG_FILE"
      echo "dnswatch: SKIP — health control failed, diff suppressed." >&2
      exit 0
      ;;
  esac
fi

echo "# dnswatch snapshot (content is timestamp-free; filename carries it)" > "$SNAP"

while IFS= read -r h || [ -n "${h:-}" ]; do
  case "$h" in ''|\#*) continue ;; esac
  # Optional record-type suffix (name@MX etc.): watch that one record type.
  case "$h" in
    *@A|*@CNAME|*@MX|*@NS|*@TXT)
      tname="${h%@*}"
      trr="${h##*@}"
      echo "$tname $trr -> $(dig1 "$tname" "$trr" || true)" >> "$SNAP"
      ;;
    *)
      echo "$h A -> $(dig1 "$h" A || true) CNAME -> $(dig1 "$h" CNAME || true)" >> "$SNAP"
      ;;
  esac
done < "$TARGETS_FILE"

# Wildcard canary — fresh random label each run, logged OUTSIDE the snapshot.
canary_result="disabled"
if [ -n "$CANARY_DOMAIN" ]; then
  canary_label="c$RANDOM$(date +%s)"
  canary_result="$(dig1 "$canary_label.$CANARY_DOMAIN" A || true)"
  [ -z "$canary_result" ] && canary_result="none"
fi

if [ -n "$PREV" ]; then
  if diff -q "$PREV" "$SNAP" >/dev/null; then
    echo "CLEAN $TS; canary: $canary_result" >> "$LOG_FILE"
  else
    {
      echo "CHANGES $TS (vs $(basename "$PREV")):"
      diff "$PREV" "$SNAP" | sed 's/^/  /'
      echo "canary: $canary_result (non-none = wildcard record appeared)"
    } >> "$LOG_FILE"
  fi
else
  echo "BASELINE $TS; canary: $canary_result" >> "$LOG_FILE"
fi

# Takeover tagging (opt-in): for each watched host, walk its alias chain and
# report dead links. Runs regardless of CLEAN/CHANGES — a chain can dangle
# silently between snapshots — and logs a summary every run.
if [ -n "$TAKEOVER_SPEC" ]; then
  tak_dang=0
  tak_aliased=0
  while IFS= read -r h || [ -n "${h:-}" ]; do
    case "$h" in ''|\#*) continue ;; esac
    case "$h" in *@*) continue ;; esac   # record-type-suffixed lines are no alias chains
    res="$(tak_check "$h")"
    case "$res" in
      'ALIVE')
        tak_aliased=$((tak_aliased+1))
        ;;
      'DEAD'*)
        tak_dang=$((tak_dang+1))
        tak_aliased=$((tak_aliased+1))
        rest="${res#*|}"                 # after DEAD|
        dead="${rest%%|*}"; rest="${rest#*|}"   # after dead| -> suffix|prov|hint
        rest="${rest#*|}"               # after suffix| -> prov|hint
        prov="${rest%%|*}"
        hint="${rest#*|}"
        echo "takeover-candidate: $h -> $dead [provider=$prov] verify: $hint" >> "$LOG_FILE"
        ;;
      *) : ;;   # host carries no CNAME: nothing to check
    esac
  done < "$TARGETS_FILE"
  echo "takeover-check: $tak_dang dangling chain(s) of $tak_aliased aliased host(s) watched" >> "$LOG_FILE"
fi

echo "dnswatch: done. snapshot=$SNAP log=$LOG_FILE" >&2
