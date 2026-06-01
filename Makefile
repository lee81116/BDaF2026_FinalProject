.PHONY: build test snap snap-check gas-report

build:
	forge build

test:
	forge test -vvv

snap:
	forge snapshot --snap snapshots/current.snap

snap-check:
	forge snapshot --diff snapshots/current.snap

gas-report:
	forge test --gas-report > docs/gas-results.md
