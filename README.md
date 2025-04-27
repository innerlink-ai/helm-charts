# InnerLink Helm Chart
This Helm chart deploys InnerLink and its components in a Kubernetes cluster.

## Prerequisites
- Kubernetes 1.19+
- Helm 3.0+
- PV provisioner support in the underlying infrastructure
- Nginx Ingress Controller
- Access to GitHub Container Registry (GHCR)

## Installation
1. Create the required directories on your host machine:
```bash
sudo mkdir -p /mnt/data /mnt/model-weights /mnt/redis /mnt/postgres
sudo chmod 777 /mnt/data /mnt/model-weights /mnt/redis /mnt/postgres
```

2. Install the chart:
```bash
cd /app
kubectl apply -f helm-chart/files/namespace.yaml
helm install innerlink ./helm-chart -n innerlink




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

## Upgrading/Reinstalling

To upgrade or reinstall the chart (this will recreate all resources while maintaining PVs):
```bash
kubectl apply -f helm-chart/files/namespace.yaml
helm upgrade --install innerlink ./helm-chart -n innerlink
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




