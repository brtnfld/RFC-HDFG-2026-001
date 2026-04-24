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

help:
	@echo -e "Usage : make [target]\n\
	all		produce the PDF (default)\n\
	markdown	produce AI-friendly Markdown ($(MAIN)-ai.md)\n\
	force		force compilation if possilbe\n\
	clean		clean  unnecessary files\n\
	distclean	clean deeper\n\
	help		display this help"

