
#!/usr/bin/env make

.PHONY: install_infra create-reflct-api-secrets


create-reflct-api-secrets:
	kubectl create secret generic reflct-api-secrets \
		--namespace prod \
		--from-env-file=../reflct-api/.env.dev \
		--dry-run=client -o yaml | kubectl apply -f -

install_infra:
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.1.1/deploy/static/provider/do/deploy.yaml
	kubectl get svc --namespace=ingress-nginx
	kubectl apply -f echo_ingress.yaml
	kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.7.1/cert-manager.yaml
	kubectl apply -f ingress_nginx_svc.yaml
	kubectl apply -f echo_ingress.yaml
	kubectl create -f prod_issuer.yaml
