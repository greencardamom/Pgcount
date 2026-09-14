#!/usr/bin/awk -f

#
# pgalign.awk - re-align an index.db against a freshly built allpages.db
#
#   gawk -f pgalign.awk <index.db> <allpages.db> > aligned.index.db
#
# WHY
#
#   loadindex() reads a window of index.db by LINE NUMBER - "tail -n +sp-30000 | head -n
#   70000" - on the assumption that index.db line N corresponds to allpages.db line N. That
#   holds the day the index is built and decays afterwards: every article created or deleted
#   shifts everything below it. Once cumulative drift exceeds the +/-30,000 window, lookups
#   fall outside the loaded block and miss, so pgcount pays API time for articles the cache
#   actually holds.
#
#   Re-joining against the current allpages.db fixes the order. Emitting a PLACEHOLDER for
#   articles with no cached creator fixes the rest: output is exactly one line per
#   allpages.db line, in the same order, so drift is zero by construction rather than merely
#   small. Without placeholders the index is a subsequence and drift returns immediately,
#   growing by every article created since the index was built.
#
# PLACEHOLDER FORMAT
#
#   A bare title with no " ---- " separator. loadindex() does split(line, a, " ---- ") and
#   stores Inx[a[1]] = a[2]; with one field a[2] is unset, so Inx[title] is empty, and
#   runbot() treats an empty Inx entry as a cache miss and calls the API. Exactly the
#   behaviour wanted, with no change to loadindex() or runbot().
#
# MEMORY
#
#   Hash join, so it holds the whole index in memory - roughly 1.5 GB for enwiki's 7.2M
#   rows. A merge join would be O(1), but it would depend on both files sharing a sort
#   collation, and would fail silently and expensively if that ever stopped being true.
#   This runs once per run, briefly, on a host with plenty of RAM.
#
# Files are distinguished by ARGIND, not FNR==NR, which only covers the first input file.
#

ARGIND == 1 {

  i = index($0, " ---- ")
  if (i == 0) {          # placeholder from a previous alignment - no creator to carry over
    N["placeholder_in"]++
    next
  }
  C[substr($0, 1, i - 1)] = substr($0, i + 6)
  N["cached"]++
  next

}

{

  N["articles"]++

  if ($0 in C) {
    print $0 " ---- " C[$0]
    N["hit"]++
  }
  else {
    print $0                     # placeholder - pgcount will fetch this one from the API
    N["miss"]++
  }

}

END {

  printf("cached=%d (placeholders_in=%d) articles=%d hit=%d miss=%d hitrate=%.2f%%\n",
         N["cached"], N["placeholder_in"], N["articles"], N["hit"], N["miss"],
         N["articles"] ? 100 * N["hit"] / N["articles"] : 0) > "/dev/stderr"
  close("/dev/stderr")

}
