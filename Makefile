.PHONY: all
all: verify lint

.PHONY: verify
verify:
	./hack/verify-render-templates.sh
	./hack/verify-dockerfile-versions.sh

.PHONY: lint
lint: lint-pipelines

.PHONY: lint-pipelines
lint-pipelines: .tekton
	@echo ">> running yamllint on all pipeline files"
ifeq (, $(shell command -v yamllint 2> /dev/null))
	@echo "yamllint not installed so skipping" && exit 1
else
	yamllint .tekton
endif
