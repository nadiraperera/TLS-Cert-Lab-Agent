.PHONY: setup seed issue renew force-renew verify logs down purge

setup:
	./scripts/setup.sh

seed:
	./scripts/seed-openbao.sh

issue:
	./scripts/issue.sh

renew:
	./scripts/renew.sh

force-renew:
	./scripts/renew.sh --force

verify:
	./scripts/verify.sh

logs:
	docker compose logs -f

down:
	./scripts/teardown.sh

purge:
	./scripts/teardown.sh --purge
