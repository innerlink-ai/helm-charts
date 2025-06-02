# Run with nohup, background, and detailed logging
#nohup sudo rsync -avHAX --progress --inplace --no-whole-file --numeric-ids \#
 # --compress-level=0 /app/data/model_weights/ /opt/dlami/nvme/model_weights/ \
 # > /tmp/rsync_progress.log 2>&1 &


#sudo rsync -avHAX --progress --inplace --no-whole-file --numeric-ids  --compress-level=0 /app/data/model_weights/ /opt/dlami/nvme/model_weights

# Unmount the filesystem
#sudo umount /opt/dlami/nvme
## Now remove the logical volume
#sudo lvremove -f /dev/vg.01/lv_ephemeral
# Remove the volume group
#sudo vgremove -f vg.01
# Remove physical volume
#sudo pvremove -f /dev/nvme1n1
# Clear any remaining signatures
#sudo wipefs -a /dev/nvme1n1
# Create new filesystem
#sudo mkfs.ext4 -F -q /dev/nvme1n1
#sudo mkdir -p /opt/dlami/nvme
#sudo mount /dev/nvme1n1 /opt/dlami/nvme
#sudo rsync -av --progress /app/data/model_weights/ /opt/dlami/nvme/
#sudo rsync -av  --progress --inplace --whole-file --bwlimit=0 /app/data/model_weights/ /opt/dlami/nvme/


#sudo dmsetup remove_all
# Try the nuclear option - overwrite directly
#sudo dd if=/dev/zero of=/dev/nvme1n1 bs=512 count=1
# Format and mount
#sudo mkfs.ext4 -q -F /dev/nvme1n1
#sudo mkdir -p /opt/dlami/nvme
#sudo mount /dev/nvme1n1 /opt/dlami/nvme
#sudo chmod 777 /opt/dlami/nvme 
#sudo rsync -av --progress /app/data/model_weights/ /opt/dlami/nvme/
  
#sudo chown -R 1000:1000 /opt/dlami/nvme/model_weights/ &

# Then monitor the progress with:
#tail -f /tmp/rsync_progress.log




#sudo rsync -av --progress /app/data/model_weights/ /opt/dlami/nvme/
#sudo chown -R 1000:1000 /opt/dlami/nvme/model_weights


sudo systemctl stop k3s
sudo rm -rf /var/lib/rancher/k3s/server/db/etcd


if ! sudo -u ubuntu docker ps | grep -q registry; then
   sudo -u ubuntu docker run -d -p 5000:5000 --restart=always --name registry registry:2
fi

curl -X GET http://localhost:5000/v2/_catalog

sudo systemctl start k3s

echo "⏳ Waiting for k3s to be ready..."
for i in {1..30}; do
    if sudo kubectl get nodes | grep -q "Ready"; then
        break
    fi
    sleep 10
done


sudo kubectl get nodes 
sleep 5
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml





kubectl apply -f helm-chart/files/namespace.yaml
sudo kubectl label nodes $(sudo kubectl get nodes -o jsonpath='{.items[0].metadata.name}') role=storage
sudo kubectl label namespace innerlink istio-injection=enabled --overwrite
SECRET=$(sudo openssl rand -base64 32)
sudo kubectl create secret generic jwt-secret -n innerlink --from-literal=JWT_SECRET="$SECRET" --dry-run=client -o yaml | sudo kubectl apply -f -

sudo helm install innerlink ./helm-chart -n innerlink -f helm-chart/values-llama2-7b.yaml \
  --set global.imageRegistry=localhost:5000 \
  --kubeconfig /etc/rancher/k3s/k3s.yaml

sudo cp istio-1.25.2/bin/istioctl /usr/local/bin/
sudo chmod +x /usr/local/bin/istioctl

istioctl install -f istio/local-istio.yaml  -y
kubectl apply -f istio/istio-gateway.yaml -n istio-system
kubectl apply -f istio/istio-virtualservice.yaml
kubectl apply -f istio/istio-gateway-service.yaml


#sudo helm upgrade innerlink ./helm-chart -n innerlink -f  helm-chart/values-llama2-7b.yaml  --kubeconfig /etc/rancher/k3s/k3s.yaml