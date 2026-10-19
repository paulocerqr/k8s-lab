# Etapa 3: kubectl no seu PC, pela tailnet

Objetivo: controlar o cluster do seu PC, sem entrar por SSH no control-plane.

O kubeconfig admin.conf tem o endereço do API server (https://10.10.0.3:6443) e as credenciais de administrador, que são um certificado de cliente. O seu PC não alcança o 10.10.0.3, porque esse é um IP privado da VPC. Por isso trocamos o endereço pelo nome do control-plane na tailnet. O certificado aceita esse nome graças aos certSANs da etapa 2.1.

No seu PC (não no control-plane):

## 1. copiar o kubeconfig do control-plane (o scp também passa pelo Tailscale SSH)

```bash
ssh usuario@control-plane 'cat ~/.kube/config' > ~/.kube/k8s-lab.conf
chmod 600 ~/.kube/k8s-lab.conf          # tem a credencial de administrador do cluster
```

## 2. trocar o endereço da VPC pelo da tailnet

```bash
sed -i 's#server: https://10.10.0.3:6443#server: https://control-plane.tailnet-exemplo.ts.net:6443#' ~/.kube/k8s-lab.conf
grep 'server:' ~/.kube/k8s-lab.conf
```

## 3. usar esse arquivo nesta sessão do terminal

```bash
export KUBECONFIG=~/.kube/k8s-lab.conf
kubectl get nodes
```

Se a etapa 1 der erro de "No such file or directory", crie a pasta antes com mkdir -p ~/.kube.

O export KUBECONFIG vale só para o terminal atual. Isso é proposital: você não aponta para o cluster do lab por engano em outro contexto. Para não precisar repetir, dá para colocar essa linha no ~/.bashrc ou ~/.zshrc.

Esperado: control-plane   NotReady   control-plane ..., igual ao que aparecia no próprio nó.

Se der timeout: a política da sua tailnet pode estar bloqueando a porta 6443.

[Índice das etapas](../kubeadm-manual.md)
