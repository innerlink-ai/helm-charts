


sudo systemctl stop k3s
sudo rm -rf /var/lib/rancher/k3s/server/db/etcd


helm uninstall innerlink
kubectl delete namespace innerlink
kubectl delete pvc -n innerlink --all
#Note: This will not delete the PersistentVolumes. To delete them, you need to manually delete them:
kubectl delete pv data-pv model-weights-pv redis-pv postgres-pv
kubectl delete pv data-pv -n innerlink --grace-period=0 --force
kubectl delete pv model-weights-pv -n innerlink --grace-period=0 --force
kubectl delete pv  redis-pv  -n innerlink --grace-period=0 --force
kubectl delete pv postgres-pv -n innerlink --grace-period=0 --force
sudo rm -rf /app/data/postgres
sudo pkill -f "python3 -m http.server 30080"
sudo istioctl uninstall --purge -y
kubectl delete namespace istio-system
kubectl delete -f istio/istio-gateway.yaml 2>/dev/null || true
kubectl delete -f istio/istio-virtualservice.yaml 2>/dev/null || true
kubectl delete -f istio/istio-gateway-service.yaml 2>/dev/null || true
kubectl get crd | grep istio | cut -d' ' -f1 | xargs kubectl delete crd
kubectl delete validatingwebhookconfigurations istio-validator-istio-system 2>/dev/null || true
kubectl delete mutatingwebhookconfigurations istio-sidecar-injector 2>/dev/null || true
kubectl delete configmap -n kube-system istio-ca-root-cert 2>/dev/null || true


sudo pkill -f "python3 -m http.server 30080"
sudo lsof -ti:30080 | xargs sudo kill -9