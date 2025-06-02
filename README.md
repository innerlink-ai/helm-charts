# InnerLink Helm Chart
This Helm chart deploys InnerLink and its components in a Kubernetes cluster.

## Prerequisites
- Kubernetes 1.19+
- Helm 3.0+
- PV provisioner support in the underlying infrastructure
- Nginx Ingress Controller
- Access to GitHub Container Registry (GHCR)



# Remove K3s
```bash
sudo systemctl stop k3s
sudo systemctl disable k3s        # leave the service installed but off
sudo rm -rf /var/lib/rancher/k3s/*  /etc/rancher/k3s/*  ~/.kube
```

# Istio
```bash
#Local
sudo curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.25.2 sh -
cd istio-1.25.2
export PATH=$PWD/bin:$PATH
```

# Install k3s and
```bash

sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<'EOF'
write-kubeconfig-mode: "644"     # world‑readable kube‑config
cluster-init: true               # this node becomes a fresh control plane
EOF
sudo systemctl restart k3s
#sudo systemctl enable k3s 
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' | sudo tee -a /etc/profile.d/k3s.sh
kubectl get nodes
sudo kubectl get namespaces
```


# Install remote
```bash
sudo systemctl start k3s                  # fresh cluster‑init
sleep 10
sudo kubectl get nodes 
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

cd /app
kubectl apply -f helm-chart/files/namespace.yaml
sudo kubectl label nodes $(sudo kubectl get nodes -o jsonpath='{.items[0].metadata.name}') role=storage
sudo kubectl label namespace innerlink istio-injection=enabled --overwrite
SECRET=$(sudo openssl rand -base64 32)
sudo kubectl create secret generic jwt-secret -n innerlink --from-literal=JWT_SECRET="$SECRET" --dry-run=client -o yaml | sudo kubectl apply -f -
sudo helm install innerlink ./helm-chart -n innerlink -f helm-chart/values-remote-24g.yaml \
 --kubeconfig /etc/rancher/k3s/k3s.yaml


sudo helm upgrade innerlink ./helm-chart -n innerlink -f  helm-chart/values-remote-24g.yaml  --kubeconfig /etc/rancher/k3s/k3s.yaml

```

2. Install the chart:
```bash
wait_for_tgi_ready() {
    echo "Waiting for TGI to be ready (looking for 'Connected' message)..."
    local max_attempts=120  # 30 minutes max (120 * 10 seconds)
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # Check if TGI pod exists and is running
        if sudo kubectl get pods -n innerlink -l app=tgi --no-headers 2>/dev/null | grep -q "Running"; then
            # Check logs for Connected message
            if sudo kubectl logs -n innerlink -l app=tgi --tail=100 2>/dev/null | grep -q "Connected"; then
                echo "✅ TGI is ready and connected!"
                return 0
            fi
            echo "⏳ Pod in RUNNING state but not ready yet..."
        fi
        
        echo "⏳ TGI not ready yet...waiting (attempt $attempt/$max_attempts)"
        sleep 10
        ((attempt++))
    done
    
    echo "❌ Timeout waiting for TGI to be ready"
    return 1
}



cd /app
curl -X GET http://localhost:5000/v2/_catalog
if ! sudo -u ubuntu docker ps | grep -q registry; then
   sudo -u ubuntu docker run -d -p 5000:5000 --restart=always --name registry registry:2
fi
sudo systemctl stop  k3s
#sudo rm -rf /var/lib/rancher/k3s/server
sudo systemctl start k3s
sleep 20
sudo kubectl get nodes 
sleep 5
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml


kubectl apply -f helm-chart/files/namespace.yaml

sudo kubectl label nodes $(sudo kubectl get nodes -o jsonpath='{.items[0].metadata.name}') role=storage
sudo kubectl label namespace innerlink istio-injection=enabled --overwrite
SECRET=$(sudo openssl rand -base64 32)
sudo kubectl create secret generic jwt-secret -n innerlink --from-literal=JWT_SECRET="$SECRET" --dry-run=client -o yaml | sudo kubectl apply -f -

#sudo helm install innerlink ./helm-chart -n innerlink -f helm-chart/values-llama2-7b.yaml \
#  --set global.imageRegistry=localhost:5000 \
#  --kubeconfig /etc/rancher/k3s/k3s.yaml

echo "🚀 Deploying TGI..."
sudo helm install innerlink ./helm-chart -n innerlink -f helm-chart/values-llama2-7b.yaml \
  --set global.imageRegistry=localhost:5000 \
  --kubeconfig /etc/rancher/k3s/k3s.yaml
  --set backend.enabled=false \
  --set frontend.enabled=false \
  --kubeconfig /etc/rancher/k3s/k3s.yaml

# Wait for TGI to be ready
wait_for_tgi_ready

# Now deploy backend and frontend
echo "🚀 Deploying backend and frontend..."
sudo helm upgrade innerlink ./helm-chart -n innerlink -f helm-chart/values-llama2-7b.yaml \
  --set global.imageRegistry=localhost:5000 \
  --kubeconfig /etc/rancher/k3s/k3s.yaml


sudo cp istio-1.25.2/bin/istioctl /usr/local/bin/
sudo chmod +x /usr/local/bin/istioctl

istioctl install -f istio/local-istio.yaml  -y
kubectl apply -f istio/istio-gateway.yaml -n istio-system
kubectl apply -f istio/istio-virtualservice.yaml
kubectl apply -f istio/istio-gateway-service.yaml




sudo helm upgrade innerlink ./helm-chart -n innerlink -f  helm-chart/values-llama2-7b.yaml  --kubeconfig /etc/rancher/k3s/k3s.yaml

```



## Uninstallation
To uninstall the chart:
```bash

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



sudo rm -rf /app/data
```


## Upgrading/Reinstalling
To upgrade or reinstall the chart (this will recreate all resources while maintaining PVs):
```bash
kubectl apply -f helm-chart/files/namespace.yaml
helm upgrade --install innerlink ./helm-chart -n innerlink
```













```
#in case above doesn't work, do this: 
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia \
   && helm repo update
# install the operator
helm install --wait nvidiagpu \
     -n gpu-operator --create-namespace \
    --set toolkit.env[0].name=CONTAINERD_CONFIG \
    --set toolkit.env[0].value=/var/lib/rancher/k3s/agent/etc/containerd/config.toml \
    --set toolkit.env[1].name=CONTAINERD_SOCKET \
    --set toolkit.env[1].value=/run/k3s/containerd/containerd.sock \
    --set toolkit.env[2].name=CONTAINERD_RUNTIME_CLASS \
    --set toolkit.env[2].value=nvidia \
    --set toolkit.env[3].name=CONTAINERD_SET_AS_DEFAULT \
    --set-string toolkit.env[3].value=true \
     nvidia/gpu-operator


kubectl delete namespace innerlink
kubectl create namespace innerlink
kubectl label namespace innerlink app.kubernetes.io/managed-by=Helm
kubectl annotate namespace innerlink meta.helm.sh/release-name=innerlink
kubectl annotate namespace innerlink meta.helm.sh/release-namespace=innerlink
helm install innerlink ./innerlink-chart -n innerlink
```







































```bash
helm install innerlink ./innerlink-chart -n innerlink    --create-namespace 

#in case above doesn't work, do this: 

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia \
   && helm repo update
# install the operator
helm install --wait nvidiagpu \
     -n gpu-operator --create-namespace \
    --set toolkit.env[0].name=CONTAINERD_CONFIG \
    --set toolkit.env[0].value=/var/lib/rancher/k3s/agent/etc/containerd/config.toml \
    --set toolkit.env[1].name=CONTAINERD_SOCKET \
    --set toolkit.env[1].value=/run/k3s/containerd/containerd.sock \
    --set toolkit.env[2].name=CONTAINERD_RUNTIME_CLASS \
    --set toolkit.env[2].value=nvidia \
    --set toolkit.env[3].name=CONTAINERD_SET_AS_DEFAULT \
    --set-string toolkit.env[3].value=true \
     nvidia/gpu-operator


kubectl delete namespace innerlink
kubectl create namespace innerlink
kubectl label namespace innerlink app.kubernetes.io/managed-by=Helm
kubectl annotate namespace innerlink meta.helm.sh/release-name=innerlink
kubectl annotate namespace innerlink meta.helm.sh/release-namespace=innerlink
helm install innerlink ./innerlink-chart -n innerlink
```



## Configuration
The following table lists the configurable parameters of the InnerLink chart and their default values.

### Global Settings
| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace` | Namespace to deploy the application | `innerlink` |

### Image Registry Credentials

| Parameter | Description | Default |
|-----------|-------------|---------|
| `imageCredentials.dockerconfig` | Base64 encoded Docker config for GHCR authentication | See values.yaml |

The chart includes a pre-configured GHCR secret for pulling private images. This secret is automatically used by the frontend, backend, and embedding-worker deployments.

### Storage Settings

| Parameter | Description | Default |
|-----------|-------------|---------|
| `storage.data.size` | Size of data PV | `10Gi` |
| `storage.modelWeights.size` | Size of model weights PV | `50Gi` |
| `storage.redis.size` | Size of Redis PV | `10Gi` |
| `storage.postgres.size` | Size of Postgres PV | `10Gi` |

### Component Settings
Each component (frontend, backend, redis, postgres, tgi, embeddingWorker, pgadmin) has the following configurable parameters:
| Parameter | Description | Default |
|-----------|-------------|---------|
| `{component}.image` | Docker image | Varies by component |
| `{component}.replicas` | Number of replicas | `1` |
| `{component}.resources` | Resource requests and limits | Varies by component |

### Ingress Settings
| Parameter | Description | Default |
|-----------|-------------|---------|
| `ingress.enabled` | Enable ingress | `true` |
| `ingress.className` | Ingress class name | `nginx` |
| `ingress.hosts` | List of ingress hosts | See values.yaml |




