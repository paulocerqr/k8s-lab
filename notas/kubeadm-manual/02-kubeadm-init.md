# Etapa 2: kubeadm init no control-plane

Objetivo: transformar o control-plane no control plane, o "cérebro" do cluster:

| Componente | Função |
|---|---|
| `etcd` | Banco de dados chave-valor que guarda todo o estado do cluster. |
| `kube-apiserver` | A porta de entrada (6443). Tudo, inclusive o kubectl, fala com o cluster por ele. |
| `kube-scheduler` | Decide em qual nó cada pod vai rodar. |
| `kube-controller-manager` | Laços de controle que mantêm o estado desejado (ex.: "quero 2 réplicas"). |

O kubeadm sobe esses quatro como static pods: o kubelet lê os arquivos em /etc/kubernetes/manifests/ e os mantém rodando, sem depender do próprio cluster.

```bash
ssh usuario@control-plane
```

## 2.1 Arquivo de configuração

Em vez de passar tudo como flags, usamos um arquivo. Assim fica legível, versionável e vira o template do Ansible depois.

```bash
cat <<'EOF' > ~/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.10.0.3          # IP do control-plane na VPC: os workers chegam no API server por aqui
  bindPort: 6443
nodeRegistration:
  name: control-plane
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.37.1
clusterName: k8s-lab
networking:
  podSubnet: 10.244.0.0/16             # IPs dos pods (não pode colidir com a VPC 10.10.0.0/24)
  serviceSubnet: 10.96.0.0/12          # IPs virtuais dos Services
apiServer:
  certSANs:                            # nomes/IPs aceitos no certificado do API server
    - control-plane
    - control-plane.tailnet-exemplo.ts.net
    - 100.64.0.10                     # IP do control-plane na tailnet: kubectl do seu PC
    - 10.10.0.3
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
```

O que importa nesse arquivo:

- certSANs: o API server só aceita conexões TLS pelos nomes e IPs que constam no certificado dele. Sem o IP e o nome da tailnet, o kubectl do seu PC daria erro de certificado. Isso foi previsto no plano, na seção 3.3.
- podSubnet: a faixa de onde o Cilium vai tirar os IPs dos pods. Ela é escolhida para não colidir com a rede da VPC.
- cgroupDriver: systemd: tem que bater com o SystemdCgroup = true do containerd, configurado na etapa 1.4.

## 2.2 Baixar as imagens antes (opcional, mas didático)

Mostra exatamente quais imagens formam o control plane, e o init fica mais rápido:

```bash
sudo kubeadm config images list --config ~/kubeadm-config.yaml
sudo kubeadm config images pull --config ~/kubeadm-config.yaml
```

## 2.3 O init

O kubeadm init passa por várias fases, e todas aparecem na saída: preflight (checa os pré-requisitos da etapa 1), certs (cria uma CA e os certificados), kubeconfig, etcd, control-plane, upload-config, bootstrap-token e addons (CoreDNS e kube-proxy). O tee salva a saída num arquivo para consulta.

```bash
sudo kubeadm init --config ~/kubeadm-config.yaml | tee ~/kubeadm-init.log
```

No final ele imprime um comando kubeadm join ... --token ... --discovery-token-ca-cert-hash sha256:.... É com ele que os workers vão entrar na etapa 5.

O token é uma credencial: quem tiver o comando pode colocar uma máquina no seu cluster enquanto ele valer (24h). Ele fica salvo em ~/kubeadm-init.log no control-plane, e dá para gerar outro a qualquer momento com kubeadm token create --print-join-command.

## 2.4 kubectl no próprio control-plane

O init gera /etc/kubernetes/admin.conf, o kubeconfig de administrador. Copiamos para o usuário lab:

```bash
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
```

## 2.5 Conferência

```bash
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide
```

O que é esperado neste momento:

- control-plane aparece como NotReady;
- os pods coredns-… ficam Pending;
- etcd, apiserver, scheduler, controller-manager e kube-proxy ficam Running.

Isso é normal. Ainda não há rede de pods (CNI), e sem ela o nó não fica pronto e o CoreDNS não tem onde rodar. O CNI é a etapa 4, com o Cilium.

[Índice das etapas](../kubeadm-manual.md)
