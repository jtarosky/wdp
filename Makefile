.DELETE_ON_ERROR:
.PHONY: all test clean

SUBDIRS:=cs7260-project cs4803dgc-project cs8803dc-project cs8803ss-project \
		cse6230-proj2 cs8803mca-proj3

all:
	for i in $(SUBDIRS) ; do cd $$i && make all && cd - ; done

test:
	for i in $(SUBDIRS) ; do cd $$i && make test && cd - ; done

clean:
	for i in $(SUBDIRS) ; do cd $$i && make clean && cd - ; done
