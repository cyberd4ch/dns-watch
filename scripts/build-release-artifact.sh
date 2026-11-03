#!/usr/bin/env bash
# Deterministic release-tarball build for dns-watch.
#
#   usage: build-release-artifact.sh <vX.Y.Z|HEAD>
#   output: /tmp/dnswatch-<version>.tar.gz + its sha256 (to stdout)
#
# Byte-stability contract (this is what makes the sha256 in the homebrew
# tap formula a real pin, not a guess):
#   * tree comes from `git archive` of the tag — nothing runs from a
#     working copy that might carry untracked files
#   * flat mtimes (2000-01-01), no extended attributes
#   * file order inside the zip is sorted (LC_ALL=C), zip flag `-X` strips
#     uid/gid/platform metadata *and* gzip timestamps are zeroed
#   * the result installs from the archive root: Homebrew's bin.install
#     gets `dnswatch.sh`, `signatures.tsv`; the auto-generated
#     src-tar* assets are unused
set -euo pipefail

VER_RESOLVE="${1:?usage: build-release-artifact.sh <vX.Y.Z|HEAD>}"
REPO="$(git rev-parse --show-toplevel)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dw-artifact.XXXXXX")"
BASE_TAR="$WORK/base.tar"
TREE="$WORK/tree"

mkdir -p "$TREE"
echo "[1/4] git archive $VER_RESOLVE" >&2
git -C "$REPO" archive --format=tar -o "$BASE_TAR" "$VER_RESOLVE"
tar -xf "$BASE_TAR" -C "$TREE"

echo "[2/4] normalize mtimes" >&2
find "$TREE" -type d -exec touch -t 200001010000.00 {} +
find "$TREE" -type f -exec touch -t 200001010000.00 {} +

VER_NO_V=""
if (cd "$TREE" && ./dnswatch.sh --version >/dev/null 2>&1); then
  VER_NO_V="$(cd "$TREE" && ./dnswatch.sh --version)"
fi
if [ -z "$VER_NO_V" ]; then
  # tag not shipped yet in dir: parse from the archive contents instead
  VER_NO_V="$(sed -n 's/.*VERSION="\([0-9.]*\)".*/\1/p' "$TREE/dnswatch.sh" | head -n1)"
fi
OUT="$WORK/dnswatch-$VER_NO_V.tar.gz"

echo "[3/4] zip -> $OUT" >&2
cd "$TREE"
find . -type f | LC_ALL=C sort | zip -X -q "$OUT" -@

cd "$WORK"
cp "dnswatch-$VER_NO_V.tar.gz" "${OUTDIR:-/tmp}/dnswatch-$VER_NO_V.tar.gz"
echo "[4/4] sha256:" >&2
shasum -a 256 "${OUTDIR:-/tmp}/dnswatch-$VER_NO_V.tar.gz"
echo "${OUTDIR:-/tmp}/dnswatch-$VER_NO_V.tar.gz"
