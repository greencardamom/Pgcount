#!/bin/bash
#
# pgalign.sh - re-align <host>.<domain>.index.db against the current allpages.db
#
# Called by pgcount.awk alignindex() at the start of a fresh run, or standalone.
# Rationale and format: pgalign.awk, 0BUILDER.md
#
#   pgalign.sh -h en -d wikipedia.org
#
# Exit 0 only when a verified aligned index was installed. Any non-zero leaves the existing
# index.db untouched - a stale-but-working index beats a half-written one.
#

set -u

# ------------------------------------------------------------------ config
# Default tree. pgcount passes -H with its own G["home"], so the two never disagree about
# which tree they are operating on - they did once, and a testbed run reached for the live
# tree's files. Only standalone invocations fall back to this default.
PG_HOME=/home/greenc/toolforge/pgcount/
# --------------------------------------------------------------------------

PROG=$(basename "$0")
say() { echo "$(date -u '+%Y%m%d-%H:%M:%S') $PROG: $*"; }
die() { say "ERROR: $*"; exit 1; }

HOST=""
DOMAIN=""
while getopts "h:d:H:" c; do
  case "$c" in
    h) HOST=$OPTARG ;;
    d) DOMAIN=$OPTARG ;;
    H) PG_HOME=$OPTARG ;;
    *) die "usage: $PROG -h <host> -d <domain> [-H <home>]" ;;
  esac
done
[ -n "$HOST" ] && [ -n "$DOMAIN" ] || die "usage: $PROG -h <host> -d <domain> [-H <home>]"
PG_HOME=${PG_HOME%/}/

KEY=$HOST.$DOMAIN
DB=${PG_HOME}db
INDEX=$DB/$KEY.index.db
ALLPAGES=$DB/$KEY.allpages.db
ALIGNER=${PG_HOME}pgalign.awk

command -v gawk >/dev/null || die "gawk not found"
[ -s "$INDEX" ]    || die "$INDEX missing or empty - nothing to align"
[ -s "$ALLPAGES" ] || die "$ALLPAGES missing or empty - alignment is against it"
[ -s "$ALIGNER" ]  || die "$ALIGNER missing"

WANT=$(wc -l < "$ALLPAGES")
BEFORE=$(wc -l < "$INDEX")

# Sanity-check the INPUT, not just our own output. Article counts drift by a percent or two
# a month, so an allpages.db much smaller than the existing index means truncated or partial
# input - and aligning to it would shrink the cache to match, destroying it. newallpages()
# guards the same class of problem with its "magic" size check on curpages.db.
MINPCT=90
if [ "$BEFORE" -gt 0 ] && [ "$(( WANT * 100 / BEFORE ))" -lt "$MINPCT" ]; then
  die "allpages.db has $WANT rows against an index of $BEFORE (under $MINPCT%) - refusing to align, this looks like truncated input"
fi

say "aligning $KEY: index $BEFORE rows -> allpages $WANT rows"

TMP=$INDEX.align.$$
LC_ALL=C gawk -f "$ALIGNER" "$INDEX" "$ALLPAGES" > "$TMP" 2> "$TMP.stats" || {
  rm -f "$TMP" "$TMP.stats"
  die "aligner failed"
}

sed 's/^/  /' "$TMP.stats"

# The whole point is one output line per allpages line. If that does not hold, something is
# wrong and installing would corrupt loadindex()'s line arithmetic - worse than doing nothing.
GOT=$(wc -l < "$TMP")
if [ "$GOT" != "$WANT" ]; then
  rm -f "$TMP" "$TMP.stats"
  die "aligned index has $GOT rows, expected $WANT - refusing to install"
fi

mv -f "$TMP" "$INDEX" || { rm -f "$TMP" "$TMP.stats"; die "cannot install $INDEX"; }
rm -f "$TMP.stats"

say "installed $INDEX, $GOT rows, exactly aligned to allpages.db"

exit 0
