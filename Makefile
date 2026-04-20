#
# Makefile
#

LATEXMK=latexmk -bibtex

MAIN=RFC-HDFG-2026-001
# Require latexdiff >= 1.1.0 to run properly
REVDIFF=6254

TEXFILES=$(wildcard *.tex)

all: $(TEXFILES)
	@$(LATEXMK) -e '$$pdflatex=q/pdflatex %O -shell-escape %S/' -pdf $(MAIN)

# Produce a Markdown document (AI-friendly) from the current LaTeX source.
# Requires: latexpand (texlive-extra-utils) and pandoc.
markdown: $(TEXFILES)
	@which latexpand > /dev/null 2>&1 || { echo "latexpand not found. Install: sudo apt install texlive-extra-utils"; exit 1; }
	@which pandoc    > /dev/null 2>&1 || { echo "pandoc not found. Install: sudo apt install pandoc"; exit 1; }
	latexpand $(MAIN).tex \
	  | sed -e '/\\renewcommand{\\texttt}/d' \
	        -e '/\\let\\oldtextunderscore/d' \
	        -e '/\\renewcommand{\\_}/d' \
	        -e 's/\\verysubsection{/\\subsubsection{/g' \
	        -e 's/\\SectionRef{[^}]*}/(§)/g' \
	  | pandoc -f latex -t markdown --wrap=none -o $(MAIN).md
	@echo "Written $(MAIN).md"

# Produce a plain-text document (minimal markup, maximally AI-friendly).
plaintext: $(TEXFILES)
	@which latexpand > /dev/null 2>&1 || { echo "latexpand not found. Install: sudo apt install texlive-extra-utils"; exit 1; }
	@which pandoc    > /dev/null 2>&1 || { echo "pandoc not found. Install: sudo apt install pandoc"; exit 1; }
	latexpand $(MAIN).tex \
	  | sed -e '/\\renewcommand{\\texttt}/d' \
	        -e '/\\let\\oldtextunderscore/d' \
	        -e '/\\renewcommand{\\_}/d' \
	        -e 's/\\verysubsection{/\\subsubsection{/g' \
	        -e 's/\\SectionRef{[^}]*}/(§)/g' \
	  | pandoc -f latex -t plain --wrap=none -o $(MAIN).txt
	@echo "Written $(MAIN).txt"

diff:	$(TEXFILES)
	latexdiff-vc --config="\"PICTUREENV=(?:picture|DIFnomarkup|figure|lstlisting)[\w\d*@]*\"" -t CCHANGEBAR --driver=pdftex --flatten=keep-intermediate --force --svn -r $(REVDIFF) $(MAIN).tex
	@$(LATEXMK) -pdf $(MAIN)-diff$(REVDIFF)

luatex: $(TEXFILES)
	@$(LATEXMK) -pdflatex=lualatex -pdf $(MAIN)

force:
	@$(LATEXMK) -f -pdf $(MAIN)

clean:
	@$(LATEXMK) -c

distclean: clean
	@$(LATEXMK) -C
	@rm -f $(MAIN).md $(MAIN).txt

help:
	@echo -e "Usage : make [target]\n\
	all		produce the PDF (default)\n\
	markdown	produce $(MAIN).md  (requires latexpand + pandoc)\n\
	plaintext	produce $(MAIN).txt (requires latexpand + pandoc)\n\
	force		force compilation if possilbe\n\
	clean		clean  unnecessary files\n\
	distclean	clean deeper (also removes .md and .txt)\n\
	help		display this help"

