.PHONY: up down test

#So that I never forget

decrypt:
	@bash decrypt-secrets.sh

up: decrypt
	docker compose up -d

down:
	docker compose down

test: decrypt
	docker compose exec backup backup
