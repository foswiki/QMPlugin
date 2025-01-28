FOSWIKI_ROOT?=~/foswiki/core
TARGET=build/qmplugin.css build/qmplugin.js 

-include $(FOSWIKI_ROOT)/pub/System/JQueryPlugin/Makefile.include

.PHONY: clean

build/%.css: src/%.css
	@echo generating $@; $(CAT) $^ | $(CSSMIN) $(CSSMIN_ARGS) > $@

build/%.js: src/%.js
	@echo generating $@; $(JSMIN) $^ > $@
