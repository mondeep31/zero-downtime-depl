TAG ?= v2
SCENARIOS := good-deploy bad-deploy scale ratelimit kill-container naive-deploy

.PHONY: help build up deploy down logs test $(addprefix test-,$(SCENARIOS))

help:
	@echo "make up                 build v1 and start the stack (proxy on :$${PROXY_PORT:-8080})"
	@echo "make deploy TAG=v2      build TAG and roll it out with zero downtime"
	@echo "make test               run every scenario"
	@echo "make test-<scenario>    one of: $(SCENARIOS)"
	@echo "make logs               follow logs"
	@echo "make down               stop everything and delete the data"

build:
	docker build -t zdd-app:$(TAG) --build-arg VERSION=$(TAG) app

up:
	$(MAKE) build TAG=v1
	cd deploy && APP_TAG=v1 docker compose up -d --wait

deploy: build
	APP_TAG=$(TAG) ./deploy/rollout.sh

down:
	cd deploy && docker compose down -v --remove-orphans

logs:
	cd deploy && docker compose logs -f --tail 20

test: $(addprefix test-,$(SCENARIOS))
	@echo
	@echo "All scenarios passed."

$(addprefix test-,$(SCENARIOS)): test-%:
	./scenarios/$*.sh
