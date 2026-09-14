#!/bin/bash
#
# pgindex.sh - build <host>.<domain>.index.db from Wikimedia stub-meta-history dumps
#
# Called by pgcount.awk buildindex() when there is no cache to use, or standalone.
# Design, measurements, open questions: 0BUILDER.md
#
#   pgindex.sh -h en -d wikipedia.org
#
# Exit 0 only when index.db was published. Any non-zero leaves index.db absent and
# pgcount falls through to the API crawl - slow, but not a failed run.
#
# Resumable: partial downloads resume (wget -c), verified parts and parsed parts are
# both marked, so a re-run skips work already done.
#

set -u

# ------------------------------------------------------------------ config
# Everything deployment-specific lives here. Installing elsewhere = edit this block.

# Default tree. pgcount passes -H with its own G["home"] so the two cannot disagree about
# which tree they operate on. Only standalone invocations fall back to this default.
PG_HOME=/home/greenc/toolforge/pgcount/
DUMPHOST=https://dumps.wikimedia.org
MAXDL=3                 # concurrent downloads. WMF guidance is 2-3 - do not raise
PARSEJOBS=6             # concurrent parses. CPU-bound, slater has 16 cores
KEEPPARTS=0             # 1 = keep .xml.gz after parsing (debugging)

# Where dump parts are downloaded and parsed. A relative name sits under the pgcount tree;
# give an absolute path to put the work on a different filesystem.
#
# This is the only part of pgcount that needs real disk. For enwiki expect ~25-30 GB in
# flight - MAXDL parts downloading plus PARSEJOBS parsing at ~4 GB each, every part deleted
# as soon as it parses. If parsing falls behind downloading it can approach the full 114 GB.
# What survives between runs is small: the .tsv rows (~250 MB) and the marker files.
WORKDIR=dumpwork

# Ambiguity policy, applied at JOIN time - changing it costs a re-join, not a re-download.
# Omitted pages are simply absent from index.db, so pgcount asks the API for them.
#
#   OMIT_DISORDERED - skip pages where the earliest-timestamp revision is not first in
#                     rev_id order. Measured on enwiki part 1 (the oldest, worst case):
#                     catches 9 of 9 dump/API disagreements, costs 12,976 omissions,
#                     ie. ~1,442 omissions per error avoided. Base error rate without
#                     it is 9 in 20,745 = 0.043%.
#   OMIT_TIE        - skip pages where two revisions share the earliest timestamp.
#                     Measured: catches 0 of 9. Off by default; it is pure cost.
OMIT_DISORDERED=1
OMIT_TIE=0
# Contact address for the User-Agent. Read from a file at runtime, never hardcoded - same
# convention as pgcount.awk's emailfp. This file is published to a public repo.
USERID=User:GreenC
EMAILFP=/home/greenc/toolforge/scripts/secrets/greenc.email

# Dump wiki name per domain. Deliberately explicit: "<host>wiki" is right for
# wikipedia.org but wrong for wikidata, commons and the *.wikimedia.org family.
wikiname() {
  case "$2" in
    wikipedia.org) echo "${1}wiki" ;;
    *)             return 1 ;;
  esac
}

# --------------------------------------------------------------------------

PROG=$(basename "$0")

say()  { echo "$(date -u '+%Y%m%d-%H:%M:%S') $PROG: $*"; }
die()  { say "ERROR: $*"; exit 1; }

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

WIKI=$(wikiname "$HOST" "$DOMAIN") || die "no dump wiki name known for domain '$DOMAIN' - add it to wikiname()"

KEY=$HOST.$DOMAIN
DB=${PG_HOME}db
# Resolved after getopts so -H is honoured. Absolute WORKDIR escapes the tree entirely.
case "$WORKDIR" in
  /*) WORK=$WORKDIR/$WIKI ;;
  *)  WORK=${PG_HOME}$WORKDIR/$WIKI ;;
esac
ALLPAGES=$DB/$KEY.allpages.db
INDEX=$DB/$KEY.index.db
PARSER=${PG_HOME}pgindex.awk

for t in jq wget pigz gawk sha1sum; do
  command -v "$t" >/dev/null || die "missing required command: $t"
done

# Build the UA now that die() exists. WMF requires a contact address; fail loud rather than
# send requests without one.
[ -s "$EMAILFP" ] || die "contact file $EMAILFP missing or empty - required for the WMF User-Agent"
UA="pgcount-pgindex/1.0 (https://en.wikipedia.org/wiki/$USERID; $(tr -d '[:space:]' < "$EMAILFP"))"
[ -s "$ALLPAGES" ] || die "$ALLPAGES missing or empty - the index is joined against it, so it must exist first"
[ -s "$PARSER" ] || die "$PARSER missing"

mkdir -p "$WORK" || die "cannot create $WORK"

say "building index for $KEY (wiki=$WIKI)"

# ---- 1. newest dump whose stub job actually completed --------------------
#
# Not "latest/" - that symlink can point at a run still in progress.

DATE=""
for d in $(wget -qO- --user-agent="$UA" "$DUMPHOST/$WIKI/" \
           | grep -oE '>[0-9]{8}/<' | tr -dc '0-9\n' | sort -rn); do
  s=$WORK/dumpstatus.$d.json
  wget -qO "$s" --user-agent="$UA" "$DUMPHOST/$WIKI/$d/dumpstatus.json" || continue
  if [ "$(jq -r '.jobs.xmlstubsdump.status // "missing"' "$s")" = "done" ]; then
    DATE=$d
    STATUS=$s
    break
  fi
  say "dump $d: stub job not done, trying older"
done
[ -n "$DATE" ] || die "no dump with a completed xmlstubsdump job found"

say "using dump $DATE"

# The parts, not the recombined single file (that job is xmlstubsdumprecombine, so an
# un-numbered name here is a small wiki's single part - eg. slwiki - not the recombine).
FILES=$(jq -r '.jobs.xmlstubsdump.files | keys[]
               | select(test("stub-meta-history[0-9]*\\.xml\\.gz$"))' "$STATUS" | sort -V)
[ -n "$FILES" ] || die "no stub-meta-history parts listed in $STATUS"

NPARTS=$(echo "$FILES" | wc -l)
TOTAL=$(jq -r '[.jobs.xmlstubsdump.files | to_entries[]
                | select(.key | test("stub-meta-history[0-9]*\\.xml\\.gz$"))
                | .value.size] | add' "$STATUS")
say "$NPARTS parts, $(( TOTAL / 1073741824 )) GB compressed"

# ---- 2. download in the background, verifying sha1 -----------------------

echo "$FILES" | xargs -P "$MAXDL" -I{} bash -c '
  f=$1; work=$2; status=$3; host=$4; ua=$5
  [ -e "$work/$f.ok" ] && exit 0
  url=$(jq -r --arg f "$f" ".jobs.xmlstubsdump.files[\$f].url"  "$status")
  want=$(jq -r --arg f "$f" ".jobs.xmlstubsdump.files[\$f].sha1" "$status")
  wget -c -q --user-agent="$ua" -O "$work/$f" "$host$url" || exit 1
  got=$(sha1sum "$work/$f" | cut -d" " -f1)
  if [ "$got" != "$want" ]; then
    echo "sha1 mismatch on $f - discarding" >&2
    rm -f "$work/$f"
    exit 1
  fi
  touch "$work/$f.ok"
' _ {} "$WORK" "$STATUS" "$DUMPHOST" "$UA" &
DLPID=$!

# ---- 3. parse each part as soon as it lands -----------------------------
#
# Download is ~12 min/part and parse ~10 min/part, so parsing behind the downloads
# keeps total wall time download-bound rather than the sum of the two.

parse_one() {
  local f=$1
  local out=$WORK/${f%.xml.gz}.tsv
  [ -e "$out.done" ] && { say "parse $f: already done"; return 0; }
  pigz -dc "$WORK/$f" \
    | LC_ALL=C grep -E '<(page|title|ns|timestamp|username|ip)>|<redirect |</(revision|page)>' \
    | LC_ALL=C gawk -f "$PARSER" > "$out" 2>> "$WORK/parse.log"
  local rc=${PIPESTATUS[2]}
  [ "$rc" = "0" ] || { say "parse $f: FAILED (rc=$rc)"; return 1; }
  touch "$out.done"
  [ "$KEEPPARTS" = "1" ] || rm -f "$WORK/$f"
  say "parse $f: $(wc -l < "$out") rows"
  return 0
}

running=0
for f in $FILES; do
  while [ ! -e "$WORK/$f.ok" ]; do
    if ! kill -0 "$DLPID" 2>/dev/null; then
      wait "$DLPID"
      [ -e "$WORK/$f.ok" ] || die "download did not produce $f - see above"
      break
    fi
    sleep 5
  done
  parse_one "$f" &
  running=$((running + 1))
  if [ "$running" -ge "$PARSEJOBS" ]; then
    wait -n 2>/dev/null || true
    running=$((running - 1))
  fi
done
wait

# ---- 4. join against allpages.db ---------------------------------------
#
# This is what gives index.db exact line alignment with allpages.db, which loadindex()
# depends on, and it drops redirects and anything deleted since the dump for free.

say "joining $(cat "$WORK"/*.tsv 2>/dev/null | wc -l) dump rows against $(wc -l < "$ALLPAGES") articles"

TMP=$INDEX.tmp.$$
LC_ALL=C gawk -v omitdis="$OMIT_DISORDERED" -v omittie="$OMIT_TIE" '
# Select on FILENAME, not FNR==NR: that idiom only covers the FIRST input file, so with
# 27 .tsv parts it would load part 1 and silently treat the other 26 as allpages input.
FILENAME ~ /[.]tsv$/ {
  n = split($0, f, "\t")
  if (n < 4) next
  rows++
  if (omitdis && f[3] != 1) { skipdis++; next }
  if (omittie && f[4] == 1) { skiptie++; next }
  C[f[1]] = f[2]
  next
}
{
  if ($0 in C) {
    print $0 " ---- " C[$0]
    hit++
  }
  else miss++
}
END {
  printf("dumprows=%d omitted_disordered=%d omitted_tie=%d joined=%d missing=%d\n",
         rows, skipdis + 0, skiptie + 0, hit, miss) > "/dev/stderr"
}' "$WORK"/*.tsv "$ALLPAGES" > "$TMP" 2> "$WORK/join.log" || { rm -f "$TMP"; die "join failed"; }

cat "$WORK/join.log"

LINES=$(wc -l < "$TMP")
[ "$LINES" -gt 0 ] || { rm -f "$TMP"; die "join produced an empty index - refusing to publish"; }

# ---- 5. publish atomically ---------------------------------------------
#
# A truncated index.db that pgcount trusts is worse than no index.db.

mv -f "$TMP" "$INDEX" || { rm -f "$TMP"; die "cannot move $TMP to $INDEX"; }

say "published $INDEX with $LINES entries from dump $DATE"
say "remaining articles will be fetched from the API as cache misses"

exit 0
