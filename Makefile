#
# Makefile
#

LATEXMK=latexmk -bibtex

MAIN=RFC-HDFG-2026-001
COMMUNITY=RFC-HDFG-2026-001-community
MEETING=MEETING-opaque-filter-dev
# Require latexdiff >= 1.1.0 to run properly
REVDIFF=6254

TEXFILES=$(wildcard *.tex)

all: $(TEXFILES)
	@$(LATEXMK) -e '$$pdflatex=q/pdflatex %O -shell-escape %S/' -pdf $(MAIN)
	@$(LATEXMK) -e '$$pdflatex=q/pdflatex %O -shell-escape %S/' -pdf $(COMMUNITY)
	@$(LATEXMK) -e '$$pdflatex=q/pdflatex %O -shell-escape %S/' -pdf $(MEETING)

meeting: $(MEETING).tex
	@$(LATEXMK) -e '$$pdflatex=q/pdflatex %O -shell-escape %S/' -pdf $(MEETING)

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
	@rm -f $(MAIN)-ai.md

markdown: $(TEXFILES)
	@latexpand $(MAIN).tex | \
	  sed '/\\renewcommand{\\texttt}/d; /\\let\\oldtextunderscore/d; /\\renewcommand{\\_}/d' | \
	  pandoc -f latex -t gfm --wrap=none -o $(MAIN)-ai.md
	@echo "AI-friendly Markdown written to $(MAIN)-ai.md"

community: $(COMMUNITY).tex
	@$(LATEXMK) -e '$$pdflatex=q/pdflatex %O -shell-escape %S/' -pdf $(COMMUNITY)

help:
	@echo -e "Usage : make [target]\n\
	all		produce all PDFs (default)\n\
	community	produce community edition PDF only\n\
	meeting		produce filter-developer meeting brief PDF only\n\
	markdown	produce AI-friendly Markdown ($(MAIN)-ai.md)\n\
	force		force compilation if possible\n\
	clean		clean  unnecessary files\n\
	distclean	clean deeper\n\
	help		display this help"

