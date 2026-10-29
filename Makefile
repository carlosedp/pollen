# pollen: common tasks. `make` lists them.

PORT  ?= 8800
NORNS ?= we@norns.local
DEST  ?= /home/we/dust/code/pollen
NORNS_WEB ?= https://github.com/carlosedp/norns-web

.DEFAULT_GOAL := help
.PHONY: help web stop test test-sc build clean deploy norns-web-pull norns-web-push

help: ## list the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{ printf "  make %-15s %s\n", $$1, $$2 }'

# "[s]erve.mjs" can't match pkill's own shell, which "serve.mjs" would (and kill it)
web: stop ## run the script in the browser, reloading on save (http://localhost:8800/, or PORT=...)
	node tools/norns-web/serve.mjs . $(PORT)

stop: ## stop a running norns-web server
	-@pkill -f "[s]erve.mjs" || true

test: ## the Lua smoke test and the browser engine rendered offline
	lua test/smoke.lua
	node test/engine.mjs

test-sc: ## the SuperCollider engine on a real scsynth, in a container (podman or docker)
	test/sc/run.sh

build: ## static copy of norns-web in tools/norns-web/dist (to publish)
	node tools/norns-web/build.mjs --cdn

clean: ## remove the static copy
	rm -rf tools/norns-web/dist

# copies the script to the norns over ssh (NORNS=we@<ip> if norns.local doesn't resolve);
# then load it from the norns menu or maiden
deploy: test ## copy the script to the norns (needs ssh access)
	rsync -av --delete --exclude '.*' --exclude tools --exclude test --exclude docs --exclude '*.js' \
		--exclude Makefile --exclude 'Engine_Pollen/' ./ $(NORNS):$(DEST)/

# tools/norns-web is a git subtree of github.com/carlosedp/norns-web (NORNS_WEB=... for another
# copy). git subtree needs GNU dirname: uutils' (Ubuntu 25.10+) turns tools/norns-web into tools,
# so these put the GNU one first on the PATH when there is one.
SUBTREE = d=$$(mktemp -d); g=$$(command -v gnudirname || command -v gdirname); \
	[ -n "$$g" ] && ln -s "$$g" $$d/dirname; PATH=$$d:$$PATH git subtree
norns-web-pull: ## update tools/norns-web from the norns-web repo (NORNS_WEB=..., BRANCH=main)
	$(SUBTREE) pull --prefix=tools/norns-web $(NORNS_WEB) $(or $(BRANCH),main) --squash
norns-web-push: ## send commits to tools/norns-web back to the norns-web repo, as BRANCH
	@[ -n "$(BRANCH)" ] || { echo "BRANCH=... please (a branch in norns-web to open a PR from)"; exit 1; }
	$(SUBTREE) push --prefix=tools/norns-web $(NORNS_WEB) $(BRANCH)
