#!/bin/bash

NAMESPACES=(
    powerdns
    external-dns
    metallb
    nginx-ingress
    $SHARINGIO_PAIR_INSTANCE_SETUP_USERLOWERCASE
)

# use kubeconfig
mkdir -p /root/.kube
cp -i /etc/kubernetes/admin.conf /root/.kube/config
export KUBECONFIG=/root/.kube/config

# ensure correct directory
pwd
cd $(dirname $0)

# ensure interfaces are configured
cat <<EOF >> /etc/network/interfaces
auto lo:0
iface lo:0 inet static
  address $KUBERNETES_CONTROLPLANE_ENDPOINT
  netmask 255.255.255.255
EOF

# ensure ii user has sufficient capabilities and access
mkdir -p /etc/sudoers.d
echo "%sudo    ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/sudo
cp -a /root/.ssh /etc/skel/.ssh
useradd -m -G users,sudo -u 1000 -s /bin/bash ii
cp -a /root/.kube /home/ii/.kube
chown ii:ii -R /home/ii/.kube

# add SSH keys
sudo -iu ii ssh-import-id "gh:$SHARINGIO_PAIR_INSTANCE_SETUP_USER"
for GUEST in $SHARINGIO_PAIR_INSTANCE_SETUP_GUESTS; do
    sudo -iu ii ssh-import-id "gh:$GUEST"
done

# exit if Kubernetes resources are already set up
kubectl -n default get configmap sharingio-pair-init-complete && exit 0

# create namespaces
for NAMESPACE in $NAMESPACES; do
    kubectl create namespace $NAMESPACE
done
# allow scheduling
kubectl taint node --all node-role.kubernetes.io/master-

# ensure the cluster will be ready
kubectl create secret generic -n kube-system packet-cloud-config --from-literal=cloud-sa.json="{\"apiKey\": \"$EQUINIX_METAL_APIKEY\",\"projectID\": \"$EQUINIX_METAL_PROJECT\"}"
kubectl apply -f ./manifests/packet-ccm.yaml

# setup host path storage
kubectl apply -f ./manifests/local-path-storage.yaml
kubectl patch storageclasses.storage.k8s.io local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# handy things
kubectl apply -f ./manifests/cert-manager.yaml
kubectl apply -f ./manifests/weavenet.yaml
kubectl apply -f ./manifests/helm-operator-crds.yaml
kubectl apply -f ./manifests/helm-operator.yaml
kubectl apply -f ./manifests/registry-creds.yaml
kubectl get configmap kube-proxy -n kube-system -o yaml | sed -e "s/strictARP: false/strictARP: true/" | kubectl apply -f - -n kube-system
kubectl apply -f ./manifests/metallb-namespace.yaml
kubectl apply -f ./manifests/metallb.yaml
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"
envsubst < ./manifests/metallb-system-config.yaml | kubectl apply -f -
envsubst < ./manifests/nginx-ingress.yaml | kubectl apply -f -
until kubectl -n nginx-ingress get deployment nginx-ingress-ingress-nginx-controller; do
  echo "waiting for nginx-ingress deployment"
  sleep 5s
done
kubectl wait -n nginx-ingress --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s

envsubst < ./manifests/metrics-server.yaml | kubectl apply -f -
envsubst < ./manifests/kubed.yaml | kubectl apply -f -

# Humacs
kubectl label ns "$SHARINGIO_PAIR_INSTANCE_SETUP_USERLOWERCASE" cert-manager-tls=sync
envsubst < ./manifests/humacs-pvc.yaml | kubectl apply -f -
envsubst < ./manifests/humacs.yaml | kubectl apply -f -

# www
envsubst < ./manifests/go-http-server.yaml | kubectl apply -f -

# DNS
kubectl apply -f ./manifests/external-dns-crd.yaml
kubectl -n external-dns create secret generic external-dns-pdns \
    --from-literal=domain-filter="$SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME" \
    --from-literal=txt-owner-id="$SHARINGIO_PAIR_INSTANCE_SETUP_USER" \
    --from-literal=pdns-server=http://powerdns-service-api.powerdns:8081 \
    --from-literal=pdns-api-key=pairingissharing
envsubst < ./manifests/external-dns.yaml | kubectl apply -f -
envsubst < ./manifests/powerdns.yaml | kubectl apply -f -
until kubectl -n powerdns get svc powerdns-service-dns-udp; do
  echo "waiting for deployed PowerDNS Chart"
  sleep 5s
done
kubectl -n powerdns patch svc powerdns-service-dns-udp -p "{\"spec\":{\"externalIPs\":[\"${KUBERNETES_CONTROLPLANE_ENDPOINT}\"]}}"
kubectl -n powerdns patch svc powerdns-service-dns-tcp -p "{\"spec\":{\"externalIPs\":[\"${KUBERNETES_CONTROLPLANE_ENDPOINT}\"]}}"
envsubst < ./manifests/dnsendpoint.yaml | kubectl apply -f -

kubectl -n powerdns wait pod --for=condition=Ready --selector=app.kubernetes.io/name=powerdns --timeout=200s
until [ "$(dig A ${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME} +short)" = "${KUBERNETES_CONTROLPLANE_ENDPOINT}" ]; do
  echo "BaseDNSName does not resolve to Instance IP yet"
  sleep 1
done
kubectl -n powerdns exec deployment/powerdns -- pdnsutil generate-tsig-key pair hmac-md5
kubectl -n powerdns exec deployment/powerdns -- pdnsutil activate-tsig-key ${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME} pair master
kubectl -n powerdns exec deployment/powerdns -- pdnsutil set-meta ${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME} TSIG-ALLOW-DNSUPDATE pair
kubectl -n powerdns exec deployment/powerdns -- pdnsutil set-meta ${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME} NOTIFY-DNSUPDATE 1
kubectl -n powerdns exec deployment/powerdns -- pdnsutil set-meta ${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME} SOA-EDIT-DNSUPDATE EPOCH
export POWERDNS_TSIG_SECRET="$(kubectl -n powerdns exec deployment/powerdns -- pdnsutil list-tsig-keys | grep pair | awk '{print $3}')"
nsupdate <<EOF
server ${KUBERNETES_CONTROLPLANE_ENDPOINT} 53
zone ${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME}
update add ${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME} 60 NS ns1.${SHARINGIO_PAIR_INSTANCE_SETUP_BASEDNSNAME}
key pair ${POWERDNS_TSIG_SECRET}
send
EOF

kubectl -n cert-manager create secret generic tsig-powerdns --from-literal=powerdns="$POWERDNS_TSIG_SECRET"
kubectl -n powerdns create secret generic tsig-powerdns --from-literal=powerdns="$POWERDNS_TSIG_SECRET"

envsubst < ./manifests/certs.yaml | kubectl apply -f -
kubectl -n default create configmap sharingio-pair-init-complete

while true; do
    conditions=$(kubectl -n powerdns get cert letsencrypt-prod -o=jsonpath='{.status.conditions[0]}')
    if [ "$(echo $conditions | jq -r .type)" = "Ready" ] && [ "$(echo $conditions | jq -r .status)" = "True" ]; then
        break
    fi
    echo "Waiting for valid TLS cert"
    sleep 1
done
kubectl -n powerdns annotate secret letsencrypt-prod kubed.appscode.com/sync=cert-manager-tls --overwrite

