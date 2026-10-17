.PHONY: check build test web-test export serve
check:
	forge build
	forge test
	forge fmt --check
	node --test test/web/*.test.mjs
build:
	forge build
test:
	forge test
web-test:
	node --test test/web/*.test.mjs
export:
	forge build
	node tools/export-artifacts.mjs
serve:
	python3 -m http.server 8080 --directory site
