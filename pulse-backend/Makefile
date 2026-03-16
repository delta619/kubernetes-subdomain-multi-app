APP     = pulse-backend
CHART   = ./chart

# Deploy locally (assumes kubectl is pointed at the right cluster)
install:
	helm upgrade --install $(APP) $(CHART) --atomic

install-dev:
	helm upgrade --install $(APP) $(CHART) --set environment=dev --atomic

uninstall:
	helm uninstall $(APP)

status:
	kubectl get pods,svc -l app=$(APP)

logs:
	kubectl logs -l app=$(APP) -f
