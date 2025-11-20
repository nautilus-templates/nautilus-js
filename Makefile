REGISTRY := local
-include .env
SRC_FILES := $(shell git ls-files src)
ENCLAVE_MEMORY ?= 768M

.DEFAULT_GOAL := default
.PHONY: default
default: out/nitro.eif

out:
	mkdir -p out

out/nitro.eif: $(SRC_FILES) | out
	@DOCKER_CMD="docker build \
		--tag $(REGISTRY)/enclaveos \
		--platform linux/amd64 \
		--output type=local,rewrite-timestamp=true,dest=out\
		-f Containerfile \
		."; \
		$$DOCKER_CMD;

.PHONY: run
run: out/nitro.eif
	test -f out/nitro.eif || (echo "EIF file not found, please run make first" && exit 1)
	sudo nitro-cli \
		run-enclave \
		--cpu-count 2 \
		--memory $(ENCLAVE_MEMORY) \
		--eif-path $(PWD)/out/nitro.eif

.PHONY: run-debug
run-debug: out/nitro.eif
	test -f out/nitro.eif || (echo "EIF file not found, please run make first" && exit 1)
	sudo nitro-cli \
		run-enclave \
		--cpu-count 2 \
		--memory $(ENCLAVE_MEMORY) \
		--eif-path $(PWD)/out/nitro.eif \
		--debug-mode \
		--attach-console

.PHONY: update
update:
	./update.sh

.PHONY: stop
stop:
	chmod +x ./reset_enclave.sh
	./reset_enclave.sh

