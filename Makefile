# Makefile pro automatizaci build, push a deploy procesů
# Proměnné
IMAGE_NAME = trading-bot
IMAGE_TAG = latest
REGISTRY = localhost:5000
FULL_IMAGE_NAME = $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

# Cíle
.PHONY: all build push deploy clean logs

all: build push deploy

build:
	@echo "--- Sestavuji Docker image: $(FULL_IMAGE_NAME) ---"
	@docker build -t $(FULL_IMAGE_NAME) .

push:
	@echo "--- Nahrávám image do lokálního registru: $(FULL_IMAGE_NAME) ---"
	@docker push $(FULL_IMAGE_NAME)

deploy:
	@echo "--- Nasazuji/aktualizuji aplikaci v Kubernetes ---"
	@kubectl apply -f k8s/
	@echo "--- Provádím rollout restart deploymentu pro okamžité projevení změn ---"
	@kubectl rollout restart deployment/trading-bot-deployment

clean:
	@echo "--- Uklízím Kubernetes zdroje ---"
	@sudo kubectl delete -f k8s/ --ignore-not-found=true

logs:
	@echo "--- Zobrazuji logy podu (pro ukončení stiskněte Ctrl+C) ---"
	@kubectl logs -f -l app=trading-bot

