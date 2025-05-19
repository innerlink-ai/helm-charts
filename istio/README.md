cd /app
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.25.2 sh -
cd istio-1.25.2
export PATH=$PWD/bin:$PATH

istioctl install -f local-istio.yaml
kubectl apply -f istio-gateway.yaml
kubectl apply -f istio-virtualservice.yaml
kubectl apply -f istio-gateway-service.yaml
kubectl apply -f istio/istio-gateway.yaml -n istio-system