# SDR++ for PortMaster / R36S
#
#   make            build + smoke test + package
#   make image      build the aarch64 builder container
#   make build      compile SDR++ and stage the port tree
#   make smoke      launch the staged build under Xvfb to prove it starts
#   make package    produce dist/sdrpp.zip
#   make source     produce the PortMaster source manifests for self-hosting
#   make shell      interactive shell in the builder (for poking at things)
#   make clean      remove build output (keeps the SDR++ checkout)
#   make distclean  remove everything including the checkout

IMAGE       ?= sdrpp-portmaster-builder
PLATFORM    ?= linux/arm64
SDRPP_REF   ?= master
PORTER      ?= Unknown
JOBS        ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

# --privileged is not needed; we only need the workspace bind-mounted.
DOCKER_RUN = docker run --rm -t \
	--platform=$(PLATFORM) \
	-v "$(CURDIR)":/workspace \
	-e SDRPP_REF="$(SDRPP_REF)" \
	-e SDRPP_CMAKE_EXTRA="$(SDRPP_CMAKE_EXTRA)" \
	-e JOBS="$(JOBS)" \
	-e SMOKE_SECONDS="$(SMOKE_SECONDS)" \
	$(IMAGE)

GH_USER     ?= jasiek
GH_REPO     ?= r36s-sdrplusplus

.PHONY: all image build smoke package source shell clean distclean binfmt

all: build smoke package source

image:
	docker build --platform=$(PLATFORM) -t $(IMAGE) docker/

build: image
	$(DOCKER_RUN) ./scripts/build.sh

smoke: image
	$(DOCKER_RUN) ./scripts/smoke-test.sh

package:
	PORTER="$(PORTER)" ./scripts/package.sh

source: package
	GH_USER="$(GH_USER)" GH_REPO="$(GH_REPO)" TAG="$(TAG)" ./scripts/make-source.sh

shell: image
	docker run --rm -it --platform=$(PLATFORM) -v "$(CURDIR)":/workspace $(IMAGE) bash

# Only needed on x86_64 hosts. Apple Silicon and ARM Linux run the aarch64
# container natively, which is roughly an order of magnitude faster.
binfmt:
	docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

clean:
	rm -rf build dist work/build work/install

distclean:
	rm -rf build dist work
