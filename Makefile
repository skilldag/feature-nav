.PHONY: install sync status test clean

install:
	@echo "Installing feature-nav CLI..."
	npm install && npm link

sync:
	@node feature-tool.js sync

status:
	@node feature-tool.js status

test:
	@npm test

clean:
	@rm -rf node_modules package-lock.json