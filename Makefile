
pagemap.1: pagemap Makefile
	help2man --no-info ./pagemap > $@

.PHONY: clean
clean:
	$(RM) pagemap.1
