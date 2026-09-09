CALAMARES_BUILD_DIR ?= $(CURDIR)/build/calamares
CALAMARES_JOBS ?= 8

.PHONY: check iso clean live-profile calamares-configure calamares-build calamares-run

check:
	./scripts/check-profile.sh

iso: check
	./scripts/build-iso.sh

live-profile: check
	./scripts/prepare-live-profile.sh

clean:
	./scripts/clean-work.sh

calamares-configure:
	cmake -S components/calamares -B "$(CALAMARES_BUILD_DIR)" -G Ninja \
		-DWITH_QT6=ON \
		-DINSTALL_CONFIG=ON \
		-DBUILD_TESTING=OFF \
		-DBUILD_SCHEMA_TESTING=OFF \
		-DCMAKE_BUILD_TYPE=Release

calamares-build: calamares-configure
	cmake --build "$(CALAMARES_BUILD_DIR)" --parallel "$(CALAMARES_JOBS)"

calamares-run: calamares-build
	cd "$(CALAMARES_BUILD_DIR)" && ./calamares -d
