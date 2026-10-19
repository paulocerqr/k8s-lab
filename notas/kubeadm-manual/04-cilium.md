# Etapa 4: Cilium (a rede dos pods), via Helm

Objetivo: instalar o CNI (Container Network Interface), o plugin que dá IP a cada pod e faz pods de nós diferentes se comunicarem. É ele que faltava para o control-plane ficar Ready e o CoreDNS subir.

As escolhas estão comentadas no cluster/cilium/values.yaml. Em resumo:

- ipam.mode: kubernetes: os IPs dos pods saem do podSubnet do kubeadm (10.244.0.0/16). O padrão do Cilium (10.0.0.0/8) colidiria com a VPC.
- routingMode: tunnel (VXLAN): o tráfego entre nós vai encapsulado, sem precisar criar rotas na GCP.
- Hubble: mostra o tráfego entre pods. Vai render boas imagens para a documentação.

No seu PC, no mesmo terminal com o KUBECONFIG:

```bash
cd ~/repositorios/k8s-lab
```

## 1. registrar o repositório de charts do Cilium no Helm

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
```

## 2. instalar (ou atualizar, se rodar de novo) com a versão fixa e os nossos values

```bash
helm upgrade --install cilium cilium/cilium \
  --version 1.20.3 \
  --namespace kube-system \
  -f cluster/cilium/values.yaml
```

## 3. acompanhar até tudo ficar Running (Ctrl+C para sair)

```bash
kubectl get pods -n kube-system -w
```

Esperado, em 1 a 3 minutos:

- pods cilium-…, cilium-envoy-… e cilium-operator-… em Running;
- hubble-relay-… e hubble-ui-… podem ficar Pending até os workers entrarem, pois o control plane tem o taint NoSchedule;
- os dois coredns-… saem de Pending para Running;
- kubectl get nodes mostra control-plane   Ready.

Execute para verificação:

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

Depois disso vem a etapa 5, o kubeadm join dos workers.

[Índice das etapas](../kubeadm-manual.md)
