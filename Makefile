.PHONY: check check-common check-linux check-macos test

PYTHON := uv run --with-requirements requirements.txt python
UNAME_S := $(shell uname -s)

test:
	$(PYTHON) -m unittest discover -s tests -v

check-common: test
	bash -n scripts/build-linux-app.sh scripts/install-linux-service.sh scripts/release-notes.sh scripts/verify-linux-app.sh scripts/verify-linux-release.sh scripts/verify-linux-service.sh scripts/lib/common.sh tests/test_install_common.sh tests/test_install_linux_service.sh tests/test_release_notes.sh tests/test_verify_linux_service.sh
	bash tests/test_install_common.sh
	bash tests/test_install_linux_service.sh
	bash tests/test_release_notes.sh
	bash tests/test_verify_linux_service.sh

check-macos: check-common
	zsh -n scripts/build-mac-app.sh scripts/install-macos-service.sh scripts/verify-macos-app.sh scripts/verify-macos-release.sh
	zsh tests/test_install_common.sh
	plutil -lint macos/io.github.twidtwid.cablelabel.plist

check-linux: check-common
	shellcheck scripts/build-linux-app.sh scripts/install-linux-service.sh scripts/release-notes.sh scripts/verify-linux-app.sh scripts/verify-linux-release.sh scripts/verify-linux-service.sh scripts/lib/common.sh tests/test_install_common.sh tests/test_install_linux_service.sh tests/test_release_notes.sh tests/test_verify_linux_service.sh
	scripts/verify-linux-service.sh

ifeq ($(UNAME_S),Darwin)
check: check-macos
else
check: check-linux
endif
