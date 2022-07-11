#!/bin/bash
# 
# Variables
# KUBERNETES_CONTROLPLANE_ENDPOINT
# KUBERNETES_VERSION
# MACHINE_IP
# SHARINGIO_PAIR_INSTANCE_CONTAINER_REGISTRY_MIRRORS

HASH_CRI_DOCKERD="dfd90922a9025e02b483a60849e59906d13a975df527775dba5f0e9fceffcceb"
PACKAGES=(
  ca-certificates 
  socat 
  jq
  yq
  ebtables 
  apt-transport-https 
  cloud-utils 
  prips 
  docker-ce 
  docker-ce-cli 
  containerd.io 
  ssh-import-id 
  dnsutils 
  kitty-terminfo 
  git
  gettext-base
  apache2-utils
)

pwd
cd $(dirname $0)

export MACHINE_IP=$(ip a s bond0 | grep -E -o 'inet [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d' ' -f2 | head -n 1)
cat <<EOF >> /root/.sharing-io-pair-init.env
export MACHINE_IP=$MACHINE_IP
EOF

# APIServer Audit rules, good for use with APISnoop suite for Kubernetes test writing
mkdir -p /etc/kubernetes/pki
cp ./manifests/audit-policy.yaml /etc/kubernetes/pki/audit-policy.yaml
cp ./manifests/audit-sink.yaml /etc/kubernetes/pki/audit-sink.yaml

# add host overlay
(
  cd ../host
  cp -v -r . /
)

# ensure mounts
sed -ri '/\\sswap\\s/s/^#?/#/' /etc/fstab
swapoff -a
mount -a

# disable unused services
systemctl disable --now snapd.service snapd.socket

if [ -n "$KUBERNETES_CONTROLPLANE_ENDPOINT" ]; then
  # ensure interfaces are configured
  cat <<EOF >> /etc/network/interfaces
auto lo:0
iface lo:0 inet static
  address $KUBERNETES_CONTROLPLANE_ENDPOINT
  netmask 255.255.255.255
EOF
  systemctl restart networking

  ping -c 3 -q "$KUBERNETES_CONTROLPLANE_ENDPOINT" && echo OK || ifup lo:0
fi

# install required packages
apt-get -y update
DEBIAN_FRONTEND=noninteractive apt-get install -y apt-transport-https curl
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
apt-key fingerprint 0EBFCD88
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys CC86BB64
add-apt-repository ppa:rmescandon/yq --yes
apt-get update -y
TRIMMED_KUBERNETES_VERSION=$(echo $KUBERNETES_VERSION | sed 's/\./\\./g' | sed 's/^v//')
RESOLVED_KUBERNETES_VERSION=$(apt-cache policy kubelet | awk -v VERSION=${TRIMMED_KUBERNETES_VERSION} '$1~ VERSION { print $1 }' | head -n1)
apt-get install -y ${PACKAGES[*]} \
  kubelet=${RESOLVED_KUBERNETES_VERSION} \
  kubeadm=${RESOLVED_KUBERNETES_VERSION} \
  kubectl=${RESOLVED_KUBERNETES_VERSION} 

curl -o /tmp/cri-dockerd.deb -L https://github.com/Mirantis/cri-dockerd/releases/download/v0.2.3/cri-dockerd_0.2.3.3-0.ubuntu-jammy_amd64.deb
if [ "$(sha256sum /tmp/cri-dockerd.deb | cut -d ' ' -f1)" = "${HASH_CRI_DOCKERD:-}" ]; then
  apt install -y /tmp/cri-dockerd.deb
  # hacky for now but should swap out the socket
  mkdir -p /etc/systemd/system/cri-docker.service.d/
  cat <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/cri-dockerd --cri-dockerd-root-directory=/var/lib/dockershim --cni-conf-dir=/etc/cni/net.d --cni-bin-dir=/opt/cni/bin --container-runtime-endpoint unix:///var/run/cri-dockerd.sock
EOF
  systemctl daemon-reload
  systemctl restart cri-docker.service
  yq e --inplace 'select(has("nodeRegistration")).nodeRegistration.criSocket = "unix:///var/run/cri-dockerd.sock"' /var/run/kubeadm/kubeadm.yaml
else
  echo "Failed to download and install the correct cri-dockerd, the hash doesn't match"
fi

# configure container runtime
cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
mkdir -p /etc/containerd
rm /etc/containerd/config.toml
systemctl restart containerd
export CONTAINER_RUNTIME_ENDPOINT=/var/run/containerd/containerd.sock
echo $HOME
export HOME=$(getent passwd $(id -u) | cut -d ':' -f6)
cat <<EOF > /etc/docker/daemon.json
{
  "storage-driver": "overlay2",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "containerd-namespace": "k8s.io",
  "containerd-plugins-namespace": "k8s.io",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "500m",
    "max-file": "3"
  }
}
EOF

# add the registry-mirrors field to the Docker configuration
if [ -n "${SHARINGIO_PAIR_INSTANCE_CONTAINER_REGISTRY_MIRRORS:-}" ]; then
  echo "$(jq --arg mirrorhosts "${SHARINGIO_PAIR_INSTANCE_CONTAINER_REGISTRY_MIRRORS:-}" '.["registry-mirrors"] |= ($mirrorhosts | rtrimstr(" ") | split(" ") | del(.[] | select(. == "")))' < /etc/docker/daemon.json)" > /etc/docker/daemon.json
fi

systemctl daemon-reload
systemctl enable --now docker
until systemctl status docker; do
  echo "Docker not ready"
  sleep 1s
done
systemctl reload docker
chgrp users /var/run/docker.sock

# configure sysctls for Kubernetes
cat <<EOF | tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system
