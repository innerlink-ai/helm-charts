
wait_for_tgi_ready() {
    echo "Waiting for TGI to be ready (looking for 'Connected' message)..."
    local max_attempts=120  # 30 minutes max (120 * 10 seconds)
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # Check if TGI pod exists and is running
        if sudo kubectl get pods -n innerlink -l app=tgi --no-headers 2>/dev/null | grep -q "1/1.*Running"; then
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



MODEL_ID=$1

sudo systemctl stop k3s
sudo rm -rf /var/lib/rancher/k3s/server/db/etcd


if ! sudo -u ubuntu docker ps | grep -q registry; then
   sudo -u ubuntu docker run -d -p 5000:5000 --restart=always --name registry registry:2
fi

curl -X GET http://localhost:5000/v2/_catalog



echo "Starting k3s"
sudo systemctl start k3s
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml


# Wait for k3s to be ready
echo "⏳ Waiting for k3s to be ready..."
for i in {1..30}; do
    if sudo kubectl get nodes | grep -q "Ready"; then
        break
    fi
    sleep 10
done


sudo touch /var/log/http-server.log
sudo chown ubuntu:ubuntu /var/log/http-server.log
nohup python3 -m http.server 30080 --bind 0.0.0.0 > ~/http-server.log 2>&1 &

# Check if images are already pulled
if sudo k3s crictl images | grep -q "innerlink-backend"; then
    echo "✅ Backend image already present"
else
    echo "📦 Pulling backend image..."
    sudo k3s crictl pull localhost:5000/ghcr.io/innerlink-ai/innerlink-backend:latest &
fi

if sudo k3s crictl images | grep -q "innerlink-frontend"; then
    echo "✅ Frontend image already present"  
else
    echo "📦 Pulling frontend image..."
    sudo k3s crictl pull localhost:5000/ghcr.io/innerlink-ai/innerlink-frontend:latest &
fi





kubectl apply -f helm-chart/files/namespace.yaml

sudo cp istio-1.25.2/bin/istioctl /usr/local/bin/
sudo chmod +x /usr/local/bin/istioctl

sudo kubectl label nodes $(sudo kubectl get nodes -o jsonpath='{.items[0].metadata.name}') role=storage
sudo kubectl label namespace innerlink istio-injection=enabled --overwrite
SECRET=$(sudo openssl rand -base64 32)
sudo kubectl create secret generic jwt-secret -n innerlink --from-literal=JWT_SECRET="$SECRET" --dry-run=client -o yaml | sudo kubectl apply -f -

#sudo helm install innerlink ./helm-chart -n innerlink -f helm-chart/values-${MODEL_ID}.yaml \
#  --set global.imageRegistry=localhost:5000 \
#  --kubeconfig /etc/rancher/k3s/k3s.yaml

echo "🚀 Deploying TGI..."
sudo helm install innerlink ./helm-chart -n innerlink -f helm-chart/values-${MODEL_ID}.yaml \
  --set global.imageRegistry=localhost:5000 \
  --set backend.enabled=false \
  --set frontend.enabled=false \
  --kubeconfig /etc/rancher/k3s/k3s.yaml

# Wait for TGI to be ready
wait_for_tgi_ready

# Now deploy backend and frontend
echo "🚀 Deploying backend and frontend..."
sudo helm upgrade innerlink ./helm-chart -n innerlink -f helm-chart/values-${MODEL_ID}.yaml \
  --set global.imageRegistry=localhost:5000 \
  --kubeconfig /etc/rancher/k3s/k3s.yaml

echo "⏳ Waiting for backend/frontend pods..."
kubectl wait --for=condition=ready pod -l app=backend -n innerlink --timeout=600s
kubectl wait --for=condition=ready pod -l app=frontend -n innerlink --timeout=600s
sleep 30

# … wait_for_tgi_ready
echo "🔄 Switching from loading page to application..."
#sudo pkill -f "python3 -m http.server 30080"   # stop splash



echo "🌐 Configuring Istio gateway for external access..."
istioctl install -f istio/local-istio.yaml  -y
kubectl apply -f istio/istio-gateway.yaml
kubectl apply -f istio/istio-virtualservice.yaml
kubectl apply -f istio/istio-gateway-service.yaml


echo "🔄 Switching from loading page to application..."
sudo pkill -f "python3 -m http.server 30080"
echo "🛑 Loading page stopped"