#!/usr/bin/awk -bE

#
# Count number of articles created by top 10,000 users
# https://github.com/greencardamom/Pgcount
#

# The MIT License (MIT)
#
# Copyright (c) 2019-2024 by User:GreenC (at en.wikipedia.org)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

BEGIN { # Bot cfg

  _defaults = "home      = /home/greenc/toolforge/pgcount/ \
               emailfp   = /home/greenc/toolforge/scripts/secrets/greenc.email \
               userid    = User:GreenC \
               version   = 1.5 \
               copyright = 2026"

  asplit(G, _defaults, "[ ]*[=][ ]*", "[ ]{9,}")
  BotName = "pgcount"
  Home = G["home"]
  Engine = 3

  # Set before @include so syscfg.awk's guarded defaults honor it. syscfg has no entries for these
  Exe["pgindex"] = G["home"] "pgindex.sh"    # dump -> index.db builder. See 0BUILDER.md
  Exe["pgalign"] = G["home"] "pgalign.sh"    # re-align index.db to a fresh allpages.db
  Exe["allpages"] = "/home/greenc/scripts/allpages.awk"   # download list of all page titles. Ships with BotWikiAwk (bin/)

  # Agent string format non-compliance could result in 429 (too many requests) rejections by WMF API
  Agent = BotName "-" G["version"] "-" G["copyright"] " (" G["userid"] "; mailto:" strip(readfile(G["emailfp"])) ")"
  
  IGNORECASE = 1

}


@include "botwiki.awk"
@include "library.awk"
@include "json.awk"

#
# pgcount saves state info to file so it can recover from crash where it left off counting
#
# File descriptions:
#
#   ~/db/en.wikipedia.org.allpages.db        - sorted list of all article names (5.5M). Rebuilt once all names are processed.
#   ~/db/en.wikipedia.org.curpages.db        - unsorted allpages most recent download
#   ~/db/en.wikipedia.org.index.db           - cache of results eg <username> ---- <article_name>
#   ~/db/en.wikipedia.org.journal.db         - buffer that will become index.db when finished
#   ~/db/en.wikipedia.org.journal-offset.db  - rolling 10000-long list flushed into journal.db
#   ~/db/en.wikipedia.org.result-raw.db      - raw list of unsorted usernames
#   ~/db/en.wikipedia.org.result-rawoffset.db - rolling 10000-long list flushed into result-raw.db
#   ~/db/en.wikipedia.org.result-sorted.db   - sorted and counted list of usernames
#   ~/db/en.wikipedia.org.1-1000.html        - HTML output - one file per block
#
#   ~/log/en.wikipedia.org.allpages.done     - block log of position in allpages.db
#   ~/log/en.wikipedia.org.allpages.offset   - rolling 10000-long artice log of position in allpages.db
#

BEGIN {

  Optind = Opterr = 1
  while ((C = getopt(ARGC, ARGV, "h:d:R")) != -1) {
      opts++
      if(C == "h")                 #  -h <hostname>   Hostname eg. "en"
        G["hostname"] = verifyval(Optarg)
      if(C == "d")                 #  -d <domain>     Domain eg. "wikipedia.org"
        G["domain"] = verifyval(Optarg)
      if(C == "R")                 #  -R              Rebuild index.db from a dump before crawling,
        G["rebuild"] = 1           #                  even if one already exists. See buildindex()
  }

  if(opts == 0 || empty(G["domain"]) || empty(G["hostname"]) ) {
    print "Problem with arguments"
    exit(0)
  }

  debug1 = 0 

  P["log"] = G["home"] "log/"            # journal logging
  P["db"]  = G["home"] "db/"             # article name database files
  P["key"] = G["hostname"] "." G["domain"]
  P["blsize"] = 10000               # size of blocks ie. tail -n +#

  # batch mode. 0 = for testing small batch or single page.
  #             1 = for production of allpages.db
  # If BM = 0, further adjustments needed below
  P["BM"]       = 1


  # Translations
  # See also: search on "stats =" for an inline translation
  
  # English Wikipedia
  T["en.wikipedia.org"]["mainpage"] = "Wikipedia:List of Wikipedians by article count"
  T["en.wikipedia.org"]["anonymous"] = "Anonymous"
  T["en.wikipedia.org"]["optoutpage"] = "Wikipedia:List of Wikipedians by number of edits/Anonymous"
  T["en.wikipedia.org"]["editsummary"] = "[[User:GreenC_bot/Job_19|pgcount]] bot update"
  T["en.wikipedia.org"]["User"] = "User"
  T["en.wikipedia.org"]["No"] = "No"
  T["en.wikipedia.org"]["Pages"] = "Pages"
  T["en.wikipedia.org"]["thousand"] = ","     # Separator character for numbers eg. 10,000
  T["en.wikipedia.org"]["toprankno"] = "100"  # Optionally the Top X are displayed with no ranking
                                              # To disable this feature set value to "0"

  # Turkish Wikipedia
  T["tr.wikipedia.org"]["mainpage"] = "Vikipedi:Başlattığı madde sayısına göre Vikipedistler listesi"
  T["tr.wikipedia.org"]["anonymous"] = "Anonim"
  T["tr.wikipedia.org"]["optoutpage"] = "Vikipedi:Başlattığı madde sayısına göre Vikipedistler listesi/Anonim"
  T["tr.wikipedia.org"]["editsummary"] = "[[Kullanıcı:GreenC_bot|pgcount]] bot güncellemesi"
  T["tr.wikipedia.org"]["User"] = "Kullanıcı"
  T["tr.wikipedia.org"]["No"] = "No"
  T["tr.wikipedia.org"]["Pages"] = "Sayfa"
  T["tr.wikipedia.org"]["thousand"] = "."     # Separator character for numbers eg. 10,000
  T["tr.wikipedia.org"]["toprankno"] = "0"    # Optionally the Top X are displayed with no ranking
                                              # To disable this feature set value to "0"

  # Slovenian Wikipedia
  T["sl.wikipedia.org"]["mainpage"] = "Wikipedija:Seznam Wikipedistov po številu člankov"
  T["sl.wikipedia.org"]["anonymous"] = "Neznanec"
  T["sl.wikipedia.org"]["optoutpage"] = "Wikipedija:Seznam Wikipedistov po številu člankov/Neznanec"
  T["sl.wikipedia.org"]["editsummary"] = "[[Uporabnik:GreenC_bot|pgcount]] bot nadgradnja"
  T["sl.wikipedia.org"]["User"] = "Uporabnik"
  T["sl.wikipedia.org"]["No"] = "St"
  T["sl.wikipedia.org"]["Pages"] = "Strani"
  T["sl.wikipedia.org"]["thousand"] = "."     # Separator character for numbers eg. 10,000
  T["sl.wikipedia.org"]["toprankno"] = "0"    # Optionally the Top X are displayed with no ranking
                                              # To disable this feature set value to "0"

  main()

  healthcheckwatch()
  
}

#
#
#
function main() {

  if( startup() )
    runSearch()

}

#
# 
#
function startup(  other) {

  # Bail if a run is already under way for this wiki.
  #  newallpages() below treats existing state files as "resume from here", but it can't
  #  tell a dead previous run from a live one - so a crontab start landing on top of a
  #  months-long run becomes a second worker on the first one's state files.
  other = otherinstance()
  if( other ) {
    parallelWrite("Skipping: " BotName " already running for " P["key"] " as pid " other " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
    return 0
  }

  # Download allpages.db if missing
  if( newallpages() ) {

    # Flush offsets if they exist
    flushoffsets()

    # Seed the cache from a dump rather than crawling every article through the API.
    #  Runs here because newallpages() has just produced allpages.db, which the builder
    #  joins against so index.db comes out aligned line-for-line.
    if( G["rebuild"] || ( ! checkexists(P["db"] P["key"] ".index.db") && P["freshstart"] ) )
      buildindex()

    # Re-align the cache to the allpages.db just built. Only on a fresh start: mid-run the
    #  index is already aligned to the allpages.db this run is walking.
    if( P["freshstart"] && checkexists(P["db"] P["key"] ".index.db") )
      alignindex()

    # Flag if index.db exists, needed info later
    if (checkexists(P["db"] P["key"] ".index.db") )
      P["index"] = 1
    else
      P["index"] = 0
  }
  else {            # error creating/finding allpages.db
    return 0
  }

  return 1

}

#
# Check all articles, runbot() on each, stop when ["tags"] limit is reached
#  Runs in different modes, 2 debugging and 1 production, set by P[project]["BM"] in BEGIN{}
#
function runSearch(  i,a,c,j,bz,sz,ez,sp,z,command,dn,la,startpoint,offset,endall,bl,article,al,artblock,done) {

  # batch mode. 0 = for testing small batch or single page. 1 = for production of allpages.db
  # BM = 0

  if(P["BM"] == 0) {

    # Single page mode. Set to 0 to disable single page mode, or set to name of article
    # sp = 0
    # sp = "Wikipedia talk:Bots/Requests for approval/GreenC bot 8"
    # sp = "Hydraulic fracturing by country"
    # sp = "ᛒ"
    
    # batch size. 1000 default
    bz = 50

    # Start location. Set sz = "0" for first batch, "1000" for second etc..
    sz = 100

    # End location. Set ez = "1000" for first batch, "2000" for second etc..
    ez = 150

    for(z = sz + 1; z <= ez; z = z + bz) {

      if(!sp) { # batch mode - for testing

        command = Exe["tail"] " -n +" z " " P["db"] P["key"] ".allpages.db | " Exe["head"] " -n " bz " > " P["db"] P["key"] ".runpages.db"
        sys2var(command)

        if( checkexists(P["db"] P["key"] ".runpages.db") ) {
          for(i = 1; i <= splitn(P["db"] P["key"] ".runpages.db", a, i); i++) {
            stdErr("Processing " a[i] " (" i ")" )
            runbot(a[i])
          }
          flushoffsets()
          dn = z "-" z + (bz - 1)
          print dn " of " ez " " date8() >> P["log"] P["key"] ".batch-done"
          close(P["log"] P["key"] ".batch-done")
        }

      }

      else {  # single page mode - for testing

        # Run bot on given article title
        print runbot(sp)
        break

      }
    }

  }

  # Run allpages.db
  #  Below method of processing allpages.db (5+ million lines) is designed to minimize memory on Toolforge grid,
  #  keep log files small, and gracefully handles frequent stops by the grid. But also works on any server.
  #   allpages.db     = file containing complete list of millions of article titles. 
  #   allpages.done   = permanent log. One line equates to 10000 articles processed.
  #   allpages.offset = temporary log. One line equates to one article processed. This resets to 0-len with
  #                     each new 10000 block. If the bot halts mid-way through, it will pick up where left off.

  else if(P["BM"] == 1) {

    # Establish startpoint ie. the line number in allpages.db where processing will begin

    # To manually set startpoint. Set along a P["blsize"] (eg. 1000) boundary ending in 1 eg. 501001 OK. 501100 !OK
    # startpoint = 25000

    # To auto start where it left-off, use last entry in allpages.done as block startpoint
    if(empty(startpoint) && checkexists(P["log"] P["key"] ".allpages.done")) {

      startpoint = sys2var(Exe["tail"] " -n 1 " P["log"] P["key"] ".allpages.done | " Exe["grep"] " -oE \"^[^-]*[^-]\"")

      if(!isanumber(startpoint)) {  # log corrupted
        email(Exe["from_email"], Exe["to_email"], "NOTIFY: " BotName "(" P["key"] ") unable to restart", "")
        exit 0
      }

      # allpages.done is written *after* a block completes, so its last line is the last
      #  block finished - resume at the one after it. Starting at the logged block re-ran
      #  10000 already-counted articles on every restart.
      #  If the bot stopped mid-block, that next block is the partly-done one and the
      #  offset below resumes it at the right article.
      startpoint = int(startpoint) + P["blsize"]

      parallelWrite(curtime() " ---- Bot (re)start (" startpoint "-" startpoint + (P["blsize"] - 1) ")", P["log"] P["key"] ".restart", 0)

    }

    # All else fails (eg. first run) start at 1
    if(empty(startpoint))
      startpoint = 1

    if (checkexists(P["db"] P["key"] ".allpages.db") ) {

      # Check for offset ie. bot previously halted mid-way through a block
      if (checkexists(P["log"] P["key"] ".allpages.offset")) {
        offset = int(splitx(sys2var(Exe["tail"] " -n 1 " P["log"] P["key"] ".allpages.offset"), " ", 1)) + 1
        if(offset == 0 || empty(offset) ) {
          offset = 1
        }
        # A full-length offset means the block finished but its offset file outlived the
        #  allpages.done write by a moment. Re-run that block from the top: with the
        #  startpoint now one block on, keeping the offset would skip 1..blsize-1 and
        #  leave a hole in the count. Duplicates are repairable, gaps are not.
        if(offset > P["blsize"] )
          offset = 1

        removefile2(P["log"] P["key"] ".allpages.offset")

      }
      else {
        offset = 1
      }

      if(debug1) parallelWrite("offset = " offset " (" datehms() ")", "/dev/stdout", 0)
      if(debug1) parallelWrite("startpoint = " startpoint " (" datehms() ")", "/dev/stdout", 0)


      # Iterate through allpages.db creating blocks of 10000 articles each
      for(bl = startpoint; bl > 0; bl += P["blsize"]) {

        # Retrieve a 10000 block from allpages.db - unix tail/head is most efficient
        command = Exe["tail"] " -n +" bl " " P["db"] P["key"] ".allpages.db | " Exe["head"] " -n " P["blsize"]
        if(debug1) parallelWrite("command = " command " (" datehms() ")", "/dev/stdout", 0)
        artblock = sys2var(command)
        if(debug1) parallelWrite("command end" " (" datehms() ")", "/dev/stdout", 0)

        # Load Inx[][] with a 130,000 block (-60000 to 10000 to +60000 surrounding bl location in index.db)
        # reset P["misscache"] to 0
        loadindex(bl)
 
        # Iterate through the 1..10000 individual articles in artblock
        c = split(artblock, article, "\n")
        if(debug1) parallelWrite("article size = " length(article) " (" datehms() ")", "/dev/stdout", 0)
        if(debug1) parallelWrite("c = " c " (" datehms() ")", "/dev/stdout", 0)
        artblock = ""  # free memory

        for(al = offset; al <= c; al++) {

          if(debug1) parallelWrite("article[al] = " article[al] " (" datehms() ")", "/dev/stdout", 0)

          # Log page-number to offset-file in log directory
          parallelWrite(al, P["log"] P["key"] ".allpages.offset", 0)

          # Run bot on given article and save in result-raw.db and journal-offset.db
          runbot(article[al])

        }

        delete article # free mem

        # Flush journal-offset.db -> journal.db every 10000 articles
        # Flush result-rawoffset.db -> result-raw.db every 10000 articles
        flushoffsets()

        # Log the block complete at allpages.done 
        P["totalcache"] += P["misscache"] 
        parallelWrite(bl "-" bl + (P["blsize"] - 1) " " date8() " " datehms() " " P["misscache"] " (" P["misscache"] / P["blsize"] ") " P["totalcache"], P["log"] P["key"] ".allpages.done", 0)
        # Reached end of allpages.db, prepare for next run and exit
        if(al < (P["blsize"] + 1) ) {
          processresult()
          finished()
          return
        }

        # Successful completion of 10000 articles, clear offset file
        removefile2(P["log"] P["key"] ".allpages.offset")

        # Reset offset to 1 
        offset = 1

      }
    }
  }

}

#
# Create and upload wikisource tables
#
function processresult(  command,d,a,c,j,i,t,re,id,blockid,userblock,html,rank,sort1,sort2,res,blocks,tailstart,c1,c2,c3,c4,stats,nc,nu,na,norankblock,save_sorted,toprankno,cr,ca) {

  # Every article is counted at most once, so result-raw.db can never be longer than
  #  allpages.db. Longer means the same articles were counted twice - duplicated blocks
  #  inflate each user's total unevenly, which reorders the published ranking. Stop here
  #  rather than upload it.
  cr = int(linecount(P["db"] P["key"] ".result-raw.db"))
  ca = int(linecount(P["db"] P["key"] ".allpages.db"))
  if(cr > ca) {
    parallelWrite("Error: result-raw.db (" cr ") longer than allpages.db (" ca ") - duplicate counts, aborting before upload for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
    email(Exe["from_email"], Exe["to_email"], "NOTIFY: " BotName "(" P["key"] ") result-raw.db (" cr ") longer than allpages.db (" ca "). Duplicate counts - nothing uploaded. Check for concurrent runs.", "")
    exit
  }

  sort1 = Exe["sort"] " --temporary-directory=" G["home"] "db  --buffer-size=40M --parallel=1 " P["db"] P["key"] ".result-raw.db"
  sort2 = Exe["sort"] " --temporary-directory=" G["home"] "log --buffer-size=40M --parallel=1 -nr"

  # Sort username file with most username instances first, etc..
  if(checkexists(P["db"] P["key"] ".result-raw.db")) {
    command = sort1 " | " Exe["uniq"] " -ic | " sort2 " > " P["db"] P["key"] ".result-sorted.db"
    sys2var(command)
    system("")
    sleep(30, "unix")
  }

  # Create the "As of last update.." statistics
  c1 = linecount(P["db"] P["key"] ".allpages.db")
  c2 = linecount(P["db"] P["key"] ".result-sorted.db")
  if(c1 > 0 && c2 > 0) {
    c3 = sys2var("awk '{c=c+$1;i++;if(i==10000)exit}END{print c}' " P["db"] P["key"] ".result-sorted.db")
    c4 = substr((c3/c1)*100,1,4)
    if(G["hostname"] == "en")
      stats = "As of the last update on " date8dash() " there are " sprintf("%'d", c1) " mainspace pages created by " sprintf("%'d", c2) " unique users. The top 10,000 users created " sprintf("%'d", c3) " pages or " c4 "% of Wikipedia.<ref>As a rule of thumb the top 20% of users will create approximately 80% of the articles per the [[80/20 rule]]. For example as of October 2019, the top 20% created 88% of the articles.</ref>" 
    else if(G["hostname"] == "tr")
      stats = date8dash() "'daki son güncelleme itibarıyla " gsubi(",", ".", sprintf("%'d", c2)) " tekil kullanıcı tarafından oluşturulan " gsubi(",", ".", sprintf("%'d", c1)) " ana sayfa vardır. En iyi 10.000 kullanıcı " gsubi(",", ".", sprintf("%'d", c3)) " sayfa veya Vikipedi'nin %" gsubi("[.]", ",", c4) "'ini oluşturdu."
    else if(G["hostname"] == "sl")
      stats = "Od zadnje posodobitve " date8revsp() " je " gsubi(",", ".", sprintf("%'d", c2)) " strani glavnega prostora ustvarilo " gsubi(",", ".", sprintf("%'d", c1)) " edinstvenih uporabnikov. 10.000 najboljših uporabnikov je ustvarilo " gsubi(",", ".", sprintf("%'d", c3)) " strani ali " gsubi("[.]", ",", c4) "% Wikipedije."
    else
      stats = ""
  }
  else {
    email(Exe["from_email"], Exe["to_email"], "NOTIFY: " BotName "(" P["key"] "). c1 or c2 == 0 problem with program aborting. Check why.", "")
    exit
  }

  loadoptout()

  for(i = 1; i <= 10; i++) {

    # Create table header for each of 10 tables
    if(i == 1) {
      id = 1
      blockid = "1–1000"
      tailstart = 1
    }
    else {
      id = (i - 1) "000"
      blockid = (id + 1) "–" (i "000")
      tailstart = (i - 1) "001"
    }
    html = ""
    if(i == 1) 
      html = html stats "\n"
    html = html "=== " blockid " ===\n"
    html = html "{| class=\"wikitable sortable\" style=\"white-space:nowrap; width: 50%; height: 14em;\"\n"
    html = html "|-\n"
    html = html "! " T[P["key"]]["No"] ".\n"
    html = html "! " T[P["key"]]["User"] "\n"
    html = html "! " T[P["key"]]["Pages"] "\n"

    # Get a 1000 block of names 
    # tail -n +5000 result-sorted.db | head -n 1000
    userblock = sys2var(Exe["tail"] " -n +" tailstart " " P["db"] P["key"] ".result-sorted.db | " Exe["head"] " -n 1000")

    # Create table entry for first Top X with no ranking when "toprankno" is set
    toprankno = int(T[P["key"]]["toprankno"])
    if(toprankno > 0 && i == 1) {
      tailstart = 1 + toprankno
      userblock = sys2var(Exe["tail"] " -n +" tailstart " " P["db"] P["key"] ".result-sorted.db | " Exe["head"] " -n " 1000 - toprankno)
      rank = toprankno # reset rank 
      norankblock = sys2var(Exe["tail"] " -n +1 " P["db"] P["key"] ".result-sorted.db | " Exe["head"] " -n " toprankno)

      # random shuffle line ordering in norankblock 
      parallelWrite(norankblock, P["log"] P["key"] ".temp-norankblock", 0)  
      close(P["log"] P["key"] ".temp-norankblock")
      sys2var(Exe["shuf"] " --output=" shquote(P["log"] P["key"] ".temp-norankblock-shuf") " " shquote(P["log"] P["key"] ".temp-norankblock"))
      close(P["log"] P["key"] ".temp-norankblock-shuf")
      norankblock = readfile(P["log"] P["key"] ".temp-norankblock-shuf")
      removefile2(P["log"] P["key"] ".temp-norankblock")
      removefile2(P["log"] P["key"] ".temp-norankblock-shuf")

      nc = split(norankblock, na, "\n")
      save_sorted = PROCINFO["sorted_in"]
      PROCINFO["sorted_in"] = "@val_str_asc"
      for(nu = 1; nu <= nc; nu++) {
        html = html "|-\n"
        html = html "| Top " toprankno " Random Sort\n"
        match(na[nu], /^[ ]*[0-9]+[ ]*/, d)
        re = "^" d[0]
        sub(re, "", na[nu])
        na[nu] = strip(na[nu])
        if(O[na[nu]] == 1)       # opt-out 
          html = html "| [[" T[P["key"]]["optoutpage"] "|[" T[P["key"]]["anonymous"] "]]]\n"
        else if(empty(na[nu]))   # unusual empty name maybe caused by right2left Arabic unicode
          html = html "| [[" T[P["key"]]["optoutpage"] "|[" T[P["key"]]["anonymous"] "]]]\n"
        else
          html = html "| [[" T[P["key"]]["User"] ":" na[nu] "|" na[nu] "]]\n"
        # html = html "| " gsubi(",", T[P["key"]]["thousand"], sprintf("%'d", d[0])) "\n"
        html = html "| {{safe|[count protected]}}\n"
      }      
      PROCINFO["sorted_in"] = save_sorted
    } 

    # For each name create a table entry
    c = split(userblock, a, "\n")
    userblock = ""
    for(j = 1; j <= c; j++) {
      if(! empty(a[j]) ) {
        rank++
        html = html "|-\n"
        html = html "| " rank "\n"
        match(a[j], /^[ ]*[0-9]+[ ]*/, d)
        re = "^" d[0]
        sub(re, "", a[j])
        if(O[a[j]] == 1)       # opt-out 
          html = html "| [[" T[P["key"]]["optoutpage"] "|[" T[P["key"]]["anonymous"] "]]]\n"
        else if(empty(strip(a[j])))   # unusual empty name maybe caused by right2left Arabic unicode
          html = html "| [[" T[P["key"]]["optoutpage"] "|[" T[P["key"]]["anonymous"] "]]]\n"
        else
          html = html "| [[" T[P["key"]]["User"] ":" a[j] "|" a[j] "]]\n"
        html = html "| " gsubi(",", T[P["key"]]["thousand"], sprintf("%'d", d[0])) "\n"

      }
    }
    html = html "|-\n"
    html = html "|}\n"

    removefile2(P["db"] P["key"] "." blockid ".html")
    parallelWrite(html, P["db"] P["key"] "." blockid ".html", 0)         

    blocks++

    if(j < 1001 && i != 1) {
      break
    }

  }

  Wipeout = 0          # flag error uploading, abort and notify

  for(j = 1; j <= blocks; j++) {

    sleep(5, "unix")             # slow down a little between each page upload

    if(j == 1) {
      id = 1
      blockid = "1–1000"
    }
    else {
      id = (j - 1) "000"
      blockid = (id + 1) "–" (j "000")
    }

    if(checkexists(P["db"] P["key"] "." blockid ".html")) {
      # wikipage = "User:GreenC bot/Job 19/"
      wikipage = T[P["key"]]["mainpage"] "/"
      command = Exe["wikiget"] " -l " G["hostname"] " -P " shquote(P["db"] P["key"] "." blockid ".html") " -E " shquote(wikipage blockid) " -S " shquote(T[P["key"]]["editsummary"] " " blockid)

      # Try 10 times before a Wipeout!
      for(t = 1; t <= 11; t++) {
        if(t == 11) {
          parallelWrite("Error: unable to upload (" command ") for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
          Wipeout++
          break
        }
        res = sys2var(command)
        if(res !~ /(success|no[ ]?change)/) 
          sleep(10, "unix")        
        else
          break
      }
    }
    else {
      parallelWrite("Error: unable to find (" P["db"] P["key"] "." blockid ".html" ") for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
      Wipeout++
    }
  }

}

#
# Completed run. Update master.db and reshuffle files.
#
function finished(  c,i,a) {

  parallelWrite("Ending pgcount for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)

  if( ! Wipeout ) {  # all looks good..

    # log-file removals
    sys2var(Exe["mv"] " " P["log"] P["key"] ".syslog " P["log"] P["key"] ".syslog.save"  )
    sys2var(Exe["mv"] " " P["log"] P["key"] ".allpages.done " P["log"] P["key"] ".allpages.done.save"  )
    removefile2(P["log"] P["key"] ".allpages.offset")

    # db-file removals
    removefile2(P["db"] P["key"] ".result-raw.db")
    removefile2(P["db"] P["key"] ".result-rawoffset.db")
    removefile2(P["db"] P["key"] ".result-sorted.db")
    removefile2(P["db"] P["key"] ".allpages.db")
    sys2var(Exe["rm"] " " P["db"] P["key"] ".*.html")
    if( checkexists(P["db"] P["key"] ".journal.db"))
      sys2var(Exe["mv"] " " P["db"] P["key"] ".journal.db " P["db"] P["key"] ".index.db"  )
  }

  else { # there is a problem

    email(Exe["from_email"], Exe["to_email"], "NOTIFY: " BotName "(" P["key"] "). Wipeout! Check why and delete saved files in ~/db and ~/log dirs", "")

    # Log file backups
    
    for(i = 1; i <= splitn(".allpages.done\n.allpages.offset", a, i); i++) {
      if( checkexists(P["log"] P["key"] a[i]) )
        sys2var(Exe["mv"] " " P["log"] P["key"] a[i] " " P["log"] P["key"] a[i] "." date8() )
    }

    # db file backups
    
    c = split(".allpages.db .index.db .journal.db .result-raw.db .result-rawoffset.db .result-sorted.db", a, " ")
    for(i = 1; i <= c; i++) {
      if( checkexists(P["db"] P["key"] a[i]) )
        sys2var(Exe["mv"] " " P["db"] P["key"] a[i] " " P["db"] P["key"] a[i] "." date8() )
    }
  }  

}

#
# Is another pgcount already running for this wiki?
#
#  Deliberately not a lock file. pgcount is built to be stopped and resumed, and a
#  kill -9 or a reboot leaves a lock file behind that would block the next restart.
#  The process table carries no such residue.
#
#  Matches on BotName plus "-h <hostname>", so a run for a different wiki (or
#  push_pgcount_src.sh, which has "pgcount" in its name but no -h) is not a match.
#  Skips this process and its parent - a crontab start is wrapped in a shell whose
#  command line is the same string.
#
#  Returns the pid of the other instance, or 0 if this is the only one.
#
function otherinstance(  i,a,c,line,sp,pid,args,me,parent,re) {

  me = int(PROCINFO["pid"])
  parent = int(PROCINFO["ppid"])
  re = "[-]h[ ]+" G["hostname"] "([ ]|$)"

  # Filter in awk, not in the pipeline - a "| grep pgcount" would match its own shell
  c = split(sys2var(Exe["ps"] " -eo pid=,args="), a, "\n")

  for(i = 1; i <= c; i++) {

    line = strip(a[i])
    sp = index(line, " ")
    if(sp < 2)
      continue

    pid = int(substr(line, 1, sp - 1))
    args = substr(line, sp + 1)

    if(pid == me || pid == parent)
      continue
    if(args !~ BotName)
      continue
    if(args !~ re)
      continue

    return pid

  }

  return 0

}

#
# Check if in cache (index).
#  Otherwise get API result
#  Update journal-offset.db and result-raw.db
#
function runbot(article) {

  if(P["index"] && ! empty(Inx) ) {
    if(! empty(Inx[article]) ) {
      parallelWrite(article " ---- " Inx[article], P["db"] P["key"] ".journal-offset.db", 0)
      parallelWrite(Inx[article], P["db"] P["key"] ".result-rawoffset.db", 0)
    }
    else {                        # article doesn't exist in index.db
      nfromapi(article)
      P["misscache"]++
    }
  }
  else {                          # index.db doesn't exist
    nfromapi(article)
    P["misscache"]++
  }

}

#
# Given an article name
#  Update journal-offset.db and result-rawoffset.db
#
function nfromapi(article,  url,jsonin,jsona,arr) {

        url = "https://" P["key"] "/w/api.php?action=query&prop=revisions&titles=" urlencodeawk(article, "rawphp") "&rvlimit=1&rvslots=main&rvprop=user&rvdir=newer&format=json&maxlag=5"
        jsonin = getjsonin(url, "uniconvert")

        if( query_json(jsonin, jsona) >= 0) {
          # jsona["query","pages","11298","revisions","1","user"]=MichaelTinkler
          splitja(jsona, arr, 5, "user")
          if(!empty(arr["1"])) {
            arr["1"] = u8(arr["1"]) # convert unicode \u to displayable text
            parallelWrite(article " ---- " arr["1"], P["db"] P["key"] ".journal-offset.db", 0)
            parallelWrite(arr["1"], P["db"] P["key"] ".result-rawoffset.db", 0)
            return
          }
        }
        parallelWrite("Error: unable to retrieve (" url ") API results in nfromapi() for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
}

#
# Concat .journal-offset.db to .journal.db and delete .journal-offset.db
# Concat .result-rawoffset.db to .result-raw.db and delete .result-rawoffset.db
#
function flushoffsets() {
   
    if(debug1) parallelWrite("flushoffsets start" " (" datehms() ")", "/dev/stdout", 0)

    close(P["db"] P["key"] ".journal-offset.db")
    close(P["db"] P["key"] ".result-rawoffset.db")
    close(P["log"] P["key"] ".allpages-offset")

    # journal.db
    if( checkexists(P["db"] P["key"] ".journal-offset.db") && checkexists(P["db"] P["key"] ".journal.db") ) {
      printf("%s", readfile(P["db"] P["key"] ".journal-offset.db")) >> P["db"] P["key"] ".journal.db"
      close(P["db"] P["key"] ".journal.db")
      # sys2var(Exe["cat"] " " P["db"] P["key"] ".journal.db " P["db"] P["key"] ".journal-offset.db > " P["db"] P["key"] ".o ; " Exe["mv"] " " P["db"] P["key"] ".o "  P["db"] P["key"] ".journal.db")
      removefile2(P["db"] P["key"] ".journal-offset.db")
    }
    else if( checkexists(P["db"] P["key"] ".journal-offset.db") && ! checkexists(P["db"] P["key"] ".journal.db") ) {
      sys2var(Exe["mv"] " " P["db"] P["key"] ".journal-offset.db " P["db"] P["key"] ".journal.db")
    }

    # result-raw.db
    if( checkexists(P["db"] P["key"] ".result-rawoffset.db") && checkexists(P["db"] P["key"] ".result-raw.db") ) {
      printf("%s", readfile(P["db"] P["key"] ".result-rawoffset.db")) >> P["db"] P["key"] ".result-raw.db"
      close(P["db"] P["key"] ".result-raw.db")
      # sys2var(Exe["cat"] " " P["db"] P["key"] ".result-raw.db " P["db"] P["key"] ".result-rawoffset.db > " P["db"] P["key"] ".o ; " Exe["mv"] " " P["db"] P["key"] ".o "  P["db"] P["key"] ".result-raw.db")
      removefile2(P["db"] P["key"] ".result-rawoffset.db")
    }
    else if( checkexists(P["db"] P["key"] ".result-rawoffset.db") && ! checkexists(P["db"] P["key"] ".result-raw.db") ) {
      sys2var(Exe["mv"] " " P["db"] P["key"] ".result-rawoffset.db " P["db"] P["key"] ".result-raw.db")
    }

    if(debug1) parallelWrite("flushoffsets end" " (" datehms() ")", "/dev/stdout", 0)

}

#
# Seed index.db from a Wikimedia stub-meta-history dump instead of crawling the API
#
#  A from-scratch enwiki build is ~41 days because every one of 7.2M articles is its own
#  API call. The same creator data sits in the monthly dumps and extracts in hours.
#  Full design, measurements and open questions: 0BUILDER.md
#
#  Called only when there is no cache to use: either a fresh start with no index.db, or
#  -R. Mid-run there is no index.db either - it does not exist until finished() promotes
#  journal.db - so P["freshstart"] gates this. Without that gate every restart of a run
#  in progress would launch a multi-hour download on top of a live crawl.
#
#  Never fatal. On any failure log it and return with index.db still absent, so the run
#  falls through to the API crawl. Slow is an acceptable degradation, aborting is not.
#
function buildindex(  command,res,logfile) {

  logfile = P["log"] P["key"] ".index-build.log"

  parallelWrite("Building index.db from dump for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)

  # system() not sys2var(): we want the exit status, and this runs for hours - its output
  #  belongs in a log, not accumulating in a variable
  # -H passes our own home, so the helper cannot resolve paths against a different tree
  command = Exe["pgindex"] " -H " shquote(G["home"]) " -h " shquote(G["hostname"]) " -d " shquote(G["domain"]) " >> " shquote(logfile) " 2>&1"
  res = system(command)
  system("")

  if( res != 0 ) {
    parallelWrite("Error: index build failed (exit " res ") for " P["key"] " - continuing without cache, see " logfile " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
    email(Exe["from_email"], Exe["to_email"], "NOTIFY: " BotName "(" P["key"] ") index build failed (exit " res "). Run continues against the API without a cache.", "")
    return
  }

  if( ! checkexists(P["db"] P["key"] ".index.db") ) {
    parallelWrite("Error: index build reported success but " P["key"] ".index.db is missing - continuing without cache ---- " curtime(), P["log"] P["key"] ".syslog", 0)
    return
  }

  parallelWrite("Index build complete for " P["key"] " (" linecount(P["db"] P["key"] ".index.db") " entries) ---- " curtime(), P["log"] P["key"] ".syslog", 0)

}

#
# Re-align index.db to the allpages.db just built
#
#  loadindex() reads a window of index.db by line number, assuming index line N matches
#  allpages line N. That decays as articles are created and deleted, and once the drift
#  exceeds its +/-30000 window the lookups miss and we pay the API for articles the cache
#  already holds. pgalign.sh rebuilds index.db in allpages order with a placeholder row for
#  every uncovered article, so the two files are line-for-line and drift is zero.
#
#  Never fatal. On failure the existing index.db is left untouched and the run continues
#  with whatever alignment it had.
#
function alignindex(  command,res,logfile) {

  logfile = P["log"] P["key"] ".index-align.log"

  # -H passes our own home, so the helper cannot resolve paths against a different tree
  command = Exe["pgalign"] " -H " shquote(G["home"]) " -h " shquote(G["hostname"]) " -d " shquote(G["domain"]) " >> " shquote(logfile) " 2>&1"
  res = system(command)
  system("")

  if( res != 0 ) {
    parallelWrite("Error: index alignment failed (exit " res ") for " P["key"] " - continuing with the existing index, see " logfile " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
    return
  }

  parallelWrite("Index aligned for " P["key"] " (" linecount(P["db"] P["key"] ".index.db") " entries) ---- " curtime(), P["log"] P["key"] ".syslog", 0)

}

#
# create allpages.db
#
function newallpages(  sort,fs,magic) {

  # re-start
  if( ( checkexists(P["log"] P["key"] ".allpages.offset") || checkexists(P["log"] P["key"] ".allpages.done") ) && checkexists(P["db"] P["key"] ".allpages.db") ) {
    P["freshstart"] = 0        # work in progress - index.db is *expected* to be absent. See buildindex()
    parallelWrite("Re-starting pgcount for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
    return 1
  }

  # new start
  else {

    P["freshstart"] = 1
    parallelWrite("Starting pgcount for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)

    # -1 file doesn't exist
    # September 21 2019 = 123446648 bytes
    fs = filesize(P["db"] P["key"] ".curpages.db")

    if(G["hostname"] == "tr")
      magic = 6370000
    else if(G["hostname"] == "sl")
      magic = 3000000
    else
      magic = 123446648 # Enwiki

    if( int(fs) < int(magic) )  {
      if(! allPages() ) {
        parallelWrite("Error: (1) unable to download curpages.db in newallpages() for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
        return 0
      }
      if(! sortdb("curpages.db")) {
        parallelWrite("Error: (1) unable to sort curpages.db in newallpages() for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
        return 0
      }
    }

    if( ! checkexists(P["db"] P["key"] ".curpages.db"))  {
      parallelWrite("Error: missing curpages.db in newallpages() for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
      return 0
    }

    if( int(filesize(P["db"] P["key"] ".curpages.db")) < int(magic)) {          
      parallelWrite("Error: bad-length curpages.db in newallpages() for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
      return 0
    }

    if( checkexists(P["db"] P["key"] ".curpages.db") ) 
        sys2var(Exe["mv"] " " P["db"] P["key"] ".curpages.db " P["db"] P["key"] ".allpages.db" )
    else {
      parallelWrite("Error: unable to find curpages.db in newallpages() for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
      return 0
    }
  }
  
  return 1

}

#
# Sort large file, 40MB memory 1 parallel process
#
function sortdb(dbname,   sort,tempFile,mainFile) {

  tempFile = P["db"] P["key"] ".sorted.db"
  mainFile = P["db"] P["key"] "." dbname

  if( checkexists(tempFile) )
    removefile2(tempFile)

  sort = Exe["sort"] " --temporary-directory=" G["home"] "db" " --output=" tempFile " --buffer-size=40M --parallel=1 " mainFile
  sys2var(sort)

  # Try 3 times
  if( filesize(tempFile) != filesize(mainFile) ) {
    removefile2(tempFile)
    sleep(5, "unix")
    sys2var(sort)
    if( filesize(tempFile) != filesize(mainFile) ) {
      removefile2( tempFile)
      sleep(30, "unix")
      sys2var(sort)
      if( filesize(tempFile) != filesize(mainFile) ) {
        parallelWrite("Error (1): unable to sort " mainFile " in sortdb() ---- " curtime(), P["log"] P["key"] ".syslog", 0)
        return 0
      }
    }
  }

  # Make sure it is sorted (better method?)
  if( sys2var(Exe["tail"] " -n 600000 " tempFile " | " Exe["head"] " -n 1" ) == sys2var(Exe["tail"] " -n 600000 " mainFile " | " Exe["head"] " -n 1") ) {
    parallelWrite("Error (2): unable to sort file " mainFile " in sortdb() ---- " curtime(), P["log"] P["key"] ".syslog", 0)
    return 0
  }

  sys2var(Exe["mv"] " " tempFile " " mainFile)
  if( checkexists(tempFile) ) {
    parallelWrite("Error (3): unable to move sorted file " tempFile " in sortdb() ---- " curtime(), P["log"] P["key"] ".syslog", 0)
    return 0
  }  
  if( ! checkexists(mainFile)) {
    parallelWrite("Error (4): unable to find sorted file " mainFile " in sortdb() ---- " curtime(), P["log"] P["key"] ".syslog", 0)
    return 0
  }

  return 1

}

#
# Convert user names ie. \u0410\u043b\u0435\u043a\u0441\u0430\u043d\u0434\u0440 \u041c\u043e\u0442\u0438\u043
#   See: https://en.wikipedia.org/wiki/Wikipedia_talk:List_of_Wikipedians_by_article_count#Unicode_escaping
#
function u8(s) {
  if(s ~ /\\u/) {
    # Use hard-coded path to avoid confusion with the shell version which does not work
    return gsubi("_", " ", sys2var("/usr/bin/printf -- " shquote(s)))
  }
  return s
}

#
# Return current date-eight (20120101) in UTC
#
function date8() {
  return strftime("%Y%m%d", systime(), 1)
}
#
# Return current date-eight with dash (2012-01-01) in UTC
#
function date8dash() {
  return strftime("%Y-%m-%d", systime(), 1)
}
#
# Return current date-eight reverse 2020-10-15 = "15. 10. 2020"
#
function date8revsp() {
  return strftime("%d. %m. %Y.", systime(), 1)
}

#
# Return current H:M:S
#
function datehms() {
  return strftime("%H:%M:%S", systime(), 1)
}

#
# Current time
#
function curtime() {
  return strftime("%Y%m%d-%H:%M:%S", systime(), 1)
}

#
# wc a file
#
function linecount(file,  a) {
  split(sys2var(Exe["wc"] " -l " file), a, " ")
  return strip(a[1])
}

# ___ All pages

#
# Download every ns0 article title to curpages.db
#
#  Delegates to allpages.awk, a standalone utility. It scans 5000 rows per request through
#  the OAuth account's apihighlimits instead of 500, refuses to append to an existing list
#  rather than silently corrupting it, and returns a real exit status - the code this
#  replaced returned success even after giving up part way through a crawl.
#
#  MediaWiki API: Allpages  https://www.mediawiki.org/wiki/API:Allpages
#
function allPages(  command,res,outfile,logfile) {

  outfile = P["db"] P["key"] ".curpages.db"
  logfile = P["log"] P["key"] ".allpages.log"

  # Trap: an external dependency, and the only one living outside the pgcount tree. Without
  #  this the symptom is a shell "not found" buried in a log and an empty curpages.db.
  if( ! checkexists(Exe["allpages"]) ) {
    parallelWrite("Error: " Exe["allpages"] " not found - cannot build curpages.db for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
    email(Exe["from_email"], Exe["to_email"], "NOTIFY: " BotName "(" P["key"] ") cannot find " Exe["allpages"] ". Install it, or correct Exe[\"allpages\"] in pgcount.awk.", "")
    return 0
  }

  # allpages.awk will not write over an existing list, so clear any partial one first
  removefile2(outfile)

  command = Exe["allpages"] " -l " shquote(G["hostname"]) " -z " shquote(G["domain"]) " -n 0 -o " shquote(outfile) " -g " shquote(logfile) " -c " shquote(BotName) " >> " shquote(logfile) " 2>&1"
  res = system(command)
  system("")

  if( res != 0 ) {
    parallelWrite("Error: allpages.awk exited " res " building curpages.db for " P["key"] " - see " logfile " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
    return 0
  }

  return 1

}

#
# Get jsonin with max lag/error retries
#  Option: if "uniconvert" is non-empty then add extra \ to unicode \u chars ie. \\u
#
function getjsonin(url,uniconvert,  i,jsonin,pre,res,retries) {

            retries = 10 # sometimes times out immediately. wikiget also has retries in-built

            pre = "API error: "

            for(i = 1; i <= retries; i++) {
              # Route API reads through wikiget -> Toolforge proxy + OAuth
              jsonin = sys2var(Exe["wikiget"] " -l " G["hostname"] " -U " shquote(url))
              res = apierror(jsonin, "json")
              if( res ~ "maxlag") {
                if(i == retries) {
                  parallelWrite(pre jsonin " for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)                
                  email(Exe["from_email"], Exe["to_email"], "NOTIFY: " BotName "(" P["key"] ") Maxlag timeout in getjsonin() after " retries " tries aborting script", "")
                  exit 
                }
                sleep(3, "unix")
              }
              else if( res ~ "error") {
                if(i == 5) {
                  parallelWrite(pre jsonin " for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
                  email(Exe["from_email"], Exe["to_email"], "NOTIFY: " BotName "(" P["key"] ") Error in getjsonin() after 5 tries aborting script", "")
                  exit
                }
                sleep(10, "unix")
              }
              else if( res ~ "empty") {
                if(i == 5) {
                  parallelWrite(pre " Received empty response for " P["key"] " ---- " curtime(), P["log"] P["key"] ".syslog", 0)
                  email(Exe["from_email"], Exe["to_email"], "NOTIFY: " BotName "(" P["key"] ") Empty response in getjsonin() after 5 tries aborting script", "")
                  exit
                }
                sleep(10, "unix")
              }
              else if( res ~ "OK") {
                break
              }
            }
            if(!empty(uniconvert))
              gsub("\\\\u", "\\\\u", jsonin) # Unicode convert "\u" to "\\u" because query_json() will remove 1 slash .. needed by u8()

            return jsonin

}

#
# Basic check of API results for error
#
function apierror(input, type,   pre, code) {

        if (length(input) < 5) 
            return "empty"

        if (type == "json") {
            if (match(input, /"error"[:]{"code"[:]"[^"]*","info"[:]"[^"]*"/, code) > 0) {
                if(input ~ "maxlag")
                  return "maxlag"
                else 
                  return "error"
            }
            else
              return "OK"
        }
}

#
# Create array of opt-out usernames
#
#   O[username] = 1
#
# where "username" is without the "User:" portion
#
function loadoptout(  fp,i,a,d,b,re) {

  delete O
  fp = sys2var("wikiget -l " G["hostname"] " -w " shquote(T[P["key"]]["optoutpage"]))
  for(i = 1; i <= splitn(fp, a, i); i++) {
    re = "^[#][ ]*[[]{2}[ ]*" T[P["key"]]["User"] "[:][^]]+[]]"
    if( match(a[i], re, d) ) {
      if(split(d[0], b, /[|]/) == 2) {
        sub(/[]][ ]*$/,"",b[2])
        O[strip(b[2])] = 1
      }
    }
  }

}

# Retrieve a 70,000 block of names from index.db and load Inx[][]
#  Block sequence is -30000 to 0 to 10000 to +30000
# Note: a 70k-line block is about 3-4MB memory
#
function loadindex(sp,   inxblock,alp,inxa,command,a,c,cacheW,cacheS,cacheE) {

        cacheW = 30000  # Size of cache windows on both sides of the index block
        cacheS = 0      # Startpoint minus this number is where to start loading cache
        cacheE = P["blsize"] + (int(cacheW) * 2)  # Cache end point

        P["misscache"] = 0  # running total number of missed cache hits.

        if(P["index"]) {

          delete Inx

          if( int(sp - cacheW) > 0) 
            cacheS = sp - cacheW
          else {
            cacheS = 1
          }

          command = Exe["tail"] " -n +" cacheS " " P["db"] P["key"] ".index.db | " Exe["head"] " -n " cacheE
          if(debug1) parallelWrite("loadindex command = " command " (" datehms() ")", "/dev/stdout", 0)
          inxblock = sys2var(command)
          if(debug1) parallelWrite("loadindex end command and start parse" " (" datehms() ")", "/dev/stdout", 0)
          c = split(inxblock, inxa, "\n")
          inxblock = ""
          for(alp = 1; alp <= c; alp++) {
            if(! empty(inxa[alp])) {
              split(inxa[alp], a, " ---- ")
              Inx[a[1]] = a[2]
            }
          }
          if(debug1) parallelWrite("loadindex end parse. Length of inxa = " length(inxa) " (" datehms() ")", "/dev/stdout", 0)
          delete inxa
        }

}

#
# Ping Healthcheckwatch API
#
# Git: https://github.com/greencardamom/HealthcheckWatch
# Install: acre:[/home/greenc/toolforge/healthcheckwatch]
# Library: ~/BotWikiAwk/lib/syscfg.awk
# Wrapper: ~/scripts/healthcheckwatchping.sh
#
function healthcheckwatch() {

  if (G["hostname"] == "en") {
      hcw_ping("slater-pgcount-en", 654, "NOTIFY (HCW): pgcount.awk (en)", "slater: /home/greenc/toolforge/pgcount/pgcount.awk (en) (no response)")
  }
  else if (G["hostname"] == "tr") {
      hcw_ping("slater-pgcount-tr", 654, "NOTIFY (HCW): pgcount.awk (tr)", "slater: /home/greenc/toolforge/pgcount/pgcount.awk (tr) (no response)")
  }
  else if (G["hostname"] == "sl") {
      hcw_ping("slater-pgcount-sl", 654, "NOTIFY (HCW): pgcount.awk (sl)", "slater: /home/greenc/toolforge/pgcount/pgcount.awk (sl) (no response)")
  }
  
  exit
}
