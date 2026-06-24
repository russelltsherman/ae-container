# Makefile — host-side helpers for the ae-container devcontainer base image.
#
# The devcontainer builds in two layers (see README "Image build"):
#   base.Dockerfile  — slow toolchain: apt deps, Node, the agent CLIs incl. Claude
#   local.Dockerfile — FROM ae-container-base:local, small security/config layers
#
# scripts/initialize.sh (the host-side initializeCommand) builds the base ON
# DEMAND, tagged with a content hash of base.Dockerfile, so it rebuilds only when
# that file changes. The Claude CLI in base.Dockerfile pins to "latest" at build
# time, so that same content-hash cache also pins Claude's version. `rebuild-base`
# forces a fresh, no-cache build to re-pull "latest" and refresh apt packages
# WITHOUT editing base.Dockerfile — the manual refresh the README documents.
#
# Tag scheme mirrors scripts/initialize.sh exactly: ae-container-base:<hash12> is
# the immutable build, and ae-container-base:local is the stable alias that
# local.Dockerfile's FROM references. AEC_BASE_DOCKERFILE overrides the Dockerfile
# path (same testing seam as initialize.sh); production uses the repo-root file.

BASE_DOCKERFILE  := $(or $(AEC_BASE_DOCKERFILE),base.Dockerfile)
BASE_IMAGE_REPO  := ae-container-base
BASE_IMAGE_LOCAL := $(BASE_IMAGE_REPO):local

.DEFAULT_GOAL := help

.PHONY: help rebuild-base clean-base

help: ## List available targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN{FS=":.*## "}{printf "  %-14s %s\n", $$1, $$2}'

base: ## Force a fresh, no-cache rebuild of the toolchain base image
	@set -eu; \
	dockerfile="$(BASE_DOCKERFILE)"; \
	[ -f "$$dockerfile" ] || { echo "error: base Dockerfile not found at $$dockerfile" >&2; exit 1; }; \
	if command -v sha256sum >/dev/null 2>&1; then \
	  hash="$$(sha256sum < "$$dockerfile" | cut -c1-12)"; \
	elif command -v shasum >/dev/null 2>&1; then \
	  hash="$$(shasum -a 256 < "$$dockerfile" | cut -c1-12)"; \
	else \
	  echo "error: no sha256 tool (need sha256sum or shasum)" >&2; exit 1; \
	fi; \
	hashed="$(BASE_IMAGE_REPO):$$hash"; \
	context="$$(dirname "$$dockerfile")"; \
	echo "rebuilding base image (no cache): $$hashed"; \
	docker build --no-cache -f "$$dockerfile" -t "$$hashed" "$$context"; \
	docker tag "$$hashed" "$(BASE_IMAGE_LOCAL)"; \
	echo "tagged $(BASE_IMAGE_LOCAL) -> $$hashed"

