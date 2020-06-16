Pgcount
===================
by User:GreenC (en.wikipedia.org)

June 2020

MIT License

Info
========
Pgcount generates [Wikipedia:List of Wikipedians by article count](https://en.wikipedia.org/wiki/Wikipedia:List_of_Wikipedians_by_article_count)

* Designed for unlimited scalability, Wikipedia database size does not matter.
* Low memory and CPU use.
* Designed to fail and recover, state information is preserved.
* No SQL or queries, API driven.
* Caches between runs.
* Flexible for use with multiple languages.

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

3. Edit ~/BotWikiAwk/lib/botwiki.awk

	A. Set local URLs in section #1 and #2 

	B. Create a new 'case' entry in section #3, adjust the Home bot path created in step 2:

		case "pgcount":                                             # Custom bot paths
			Home = "/data/project/projectname/pgcount/"         # path ends in "/"
			Agent = UserPage " (ask me about " BotName ")"
			Engine = 3
			break

	C. In section #10, replace the two lines starting with "delete Config" with the following:

		if(BotName !~ /pgcount/) {
			delete Config
			readprojectcfg()
		}

4. Set ~/Pgcount/pgcount.awk to mode 750, and change the first shebang line to the location of awk on your system

5. Edit pgcount.awk in the "BEGIN{}" section is a place for you email address to send error reports to, and a few harded coded paths for common unix utilities.

Running
========

1. See the file toolforge.txt for how to run on Toolforge. Adjust to your local system if not on Toolforge.

