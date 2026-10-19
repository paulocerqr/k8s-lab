# Etapa 5: kubeadm join dos workers

Objetivo: colocar worker-1 e worker-2 no cluster. O join faz três coisas:

1. Descoberta: o worker busca no API server a CA do cluster e confere o --discovery-token-ca-cert-hash. Assim ele tem certeza de que está falando com o seu control plane, e não com um impostor.
2. TLS bootstrap: com o token, o kubelet do worker pede um certificado próprio, e o control plane assina.
3. Registro: o kubelet se registra como nó, e o DaemonSet do Cilium cria um agente nele.

O token do init vale 24h por padrão. Se tiver expirado, gere um novo no control-plane:

```bash
ssh lab@control-plane
sudo kubeadm token create --print-join-command
```

O comando impresso tem o mesmo formato do anterior (kubeadm join 10.10.0.3:6443 --token ... --discovery-token-ca-cert-hash sha256:...). Rode-o com sudo em cada worker:

```bash
ssh lab@worker-1
sudo kubeadm join 10.10.0.3:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
exit
```

```bash
ssh lab@worker-2
sudo kubeadm join 10.10.0.3:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

O mesmo token serve para os dois workers durante 24h. Ao final de cada join deve aparecer "This node has joined the cluster".

Conferência (no seu PC)

```bash
export KUBECONFIG=~/.kube/k8s-lab.conf     # se for um terminal novo
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide
```

Esperado, em 1 a 2 minutos:

- control-plane, worker-1 e worker-2 todos Ready, cada um com o seu IP 10.10.0.x;
- um pod cilium-… e um cilium-envoy-… por nó (3 de cada);
- hubble-relay e hubble-ui saem de Pending e ficam Running em um dos workers.

Com os 3 nós Ready, o marco de 20/10 está cumprido. O teste de rede entre pods em nós diferentes está documentado em [docs/03-kubeadm.md](../../docs/03-kubeadm.md).

[Índice das etapas](../kubeadm-manual.md)
