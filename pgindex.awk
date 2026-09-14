#!/usr/bin/awk -f

#
# pgindex.awk - stream a MediaWiki stub-meta-history dump, emit "title <TAB> creator"
#
# Parser half of pgindex.sh, which drives it over each dump part. Design, measurements and rationale: 0BUILDER.md
#
# Reads decompressed stub XML on stdin. Writes one row per ns0 non-redirect page that has
# a recoverable creator:
#
#   title <TAB> creator <TAB> seq <TAB> tie
#
#     seq - position, in document (rev_id) order, of the earliest-timestamp revision.
#           1 means rev_id order and timestamp order agree for the first revision.
#     tie - 1 if two revisions share the earliest timestamp.
#
# EXTRACTION ONLY - no ambiguity policy here. pgindex.sh decides at join time what to keep.
# Extraction costs 114 GB and hours; the predicate is a one-line judgement call we want to
# re-decide in seconds. Keeping them separate means changing our mind costs a re-join, not
# a re-download. See 0BUILDER.md
#
# Stub dumps carry one element per line and no <text> content, so a line-oriented
# scanner is sufficient - no XML parser needed.
#
# Globals, bucketed (no bare scattered vars):
#   R[] - per-page record state, cleared at <page>
#   N[] - counters, reported in END
#

#
# Text between the first '>' and the next '<' eg. "<ns>0</ns>" -> "0"
#
function field(s) {
  sub(/^[^>]*>/, "", s)
  sub(/<.*$/, "", s)
  return s
}

#
# Decode XML entities. Mandatory: dump titles carry &amp; etc, while allpages.db comes
#  from decoded API JSON. Skip this and every title containing an ampersand fails to join.
#
function unxml(s) {
  gsub(/&lt;/,   "<",  s)
  gsub(/&gt;/,   ">",  s)
  gsub(/&quot;/, "\"", s)
  gsub(/&#0?39;|&apos;/, "'", s)
  gsub(/&amp;/,  "\\&", s)      # last - an entity may itself be &amp;-escaped
  return s
}

BEGIN {

  # Declared up front so END prints zeros rather than empties on an input with no pages
  N["page"] = N["ns0"] = N["redirect"] = N["rev"] = 0
  N["out"] = N["nocreator"] = N["disordered"] = N["tie"] = 0

}

/<page>/ {
  delete R
  N["page"]++
  next
}

/<title>/     { R["title"] = unxml(field($0)); next }
/<ns>/        { R["ns"] = field($0); next }
/<redirect /  { R["redirect"] = 1; next }
/<timestamp>/ { R["ts"] = field($0); next }
/<username>/  { R["user"] = unxml(field($0)); next }
/<ip>/        { R["user"] = field($0); next }

/<\/revision>/ {

  N["rev"]++
  R["nrev"]++

  if (R["user"] != "") {
    if (R["bestts"] == "" || R["ts"] < R["bestts"]) {
      R["bestts"] = R["ts"]
      R["best"] = R["user"]
      R["bestseq"] = R["nrev"]
      R["tie"] = 0
    }
    else if (R["ts"] == R["bestts"]) {
      R["tie"] = 1
    }
  }

  R["user"] = ""
  R["ts"] = ""
  next

}

/<\/page>/ {

  if (R["ns"] != "0")
    next

  N["ns0"]++

  if (R["redirect"]) {           # allpages.db is non-redirect; drop these early to keep
    N["redirect"]++              #  the intermediate small
    next
  }
  if (R["best"] == "") {         # every revision had <contributor deleted="deleted"/>
    N["nocreator"]++
    next
  }

  if (R["bestseq"] != 1)
    N["disordered"]++
  if (R["tie"])
    N["tie"]++

  printf("%s\t%s\t%d\t%d\n", R["title"], R["best"], R["bestseq"], R["tie"] + 0)
  N["out"]++
  next

}

END {

  printf("pages=%d ns0=%d redirects=%d revisions=%d emitted=%d nocreator=%d disordered=%d tie=%d\n",
         N["page"], N["ns0"], N["redirect"], N["rev"], N["out"], N["nocreator"],
         N["disordered"], N["tie"]) > "/dev/stderr"
  close("/dev/stderr")

}
