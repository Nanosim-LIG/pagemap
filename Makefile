
pagemap.1: pagemap Makefile
	help2man --name="analyze and print the physical memory layout of a Linux process" --no-info ./pagemap > $@

.PHONY: clean
clean:
	$(RM) pagemap.1
