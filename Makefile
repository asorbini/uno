VERSION :=  2.3.0
TARBALL := uno_$(VERSION).orig.tar.xz

.PHONY: \
  build \
  tarball \
  clean

build: \
  build/default

build/%: ../$(TARBALL)
	rm -rf $@
	mkdir -p $@/src
	tar -xvaf $< -C $@/src
	scripts/bundle/pyinstaller.sh $(@:build/%=%)

clean:
	rm -rf build dist

tarball: ../$(TARBALL)

../$(TARBALL):
	git ls-files --recurse-submodules | tar -cvaf $@ -T-
