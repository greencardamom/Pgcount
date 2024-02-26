Pgcount
===================
by User:GreenC (en.wikipedia.org)

June 2020-2024

MIT License

Info
========
Pgcount generates [Wikipedia:List of Wikipedians by article count](https://en.wikipedia.org/wiki/Wikipedia:List_of_Wikipedians_by_article_count)

* Designed for unlimited scalability, Wikipedia database size does not matter.
* Low memory and CPU use.
* Designed to fail and recover mid-process, state information is preserved.
* No SQL or queries, API driven.
* Caches between runs.
* Flexible for use with multiple wiki languages.

Dependencies 
========
* GNU Awk 4.1+
* [BotWikiAwk](https://github.com/greencardamom/BotWikiAwk) (version Jan 2019 +)
* A bot User account with bot permissions for your target wiki.

Installation
========

1. Install BotWikiAwk following setup instructions. Add OAuth credentials to wikiget, see the [EDITSETUP](https://github.com/greencardamom/Wikiget/blob/master/EDITSETUP) instructions.

2. Clone Pgcount. For example:
	git clone https://github.com/greencardamom/Pgcount

4. Set ~/Pgcount/pgcount.awk to mode 750, and change the first shebang line to the location of awk on your system

5. Edit pgcount.awk in the "BEGIN{}" section is a place for you email address to send error reports to, and a few harded coded paths for common unix utilities.

Running
========

Example crontab entry

	4 3 1 * * /home/greenc/toolforge/pgcount/pgcount.awk -h en -d wikipedia.org
