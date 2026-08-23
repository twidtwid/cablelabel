.PHONY: check test

PYTHON := uv run --with-requirements requirements.txt python

test:
	$(PYTHON) -m unittest discover -s tests -v

check: test
	zsh -n scripts/build-mac-app.sh scripts/install-macos-service.sh scripts/verify-macos-app.sh
	plutil -lint macos/io.github.twidtwid.cablelabel.plist
