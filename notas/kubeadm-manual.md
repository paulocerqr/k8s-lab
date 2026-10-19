# kubeadm manual — anotações (K18)

Registro da primeira instalação feita à mão. Serve de fonte para os playbooks do Ansible.
Para cada etapa: comando, em qual nó, saída relevante e o que deu errado.

## Ambiente

| Item | Valor |
|---|---|
| Data | 18/9/2026 |
| SO | Debian 13 |
| Kubernetes | |
| containerd | |
| CNI | Cilium |

## Etapas

Os nomes e endereços da tailnet abaixo são exemplos. Substitua `control-plane`, `usuario`, `tailnet-exemplo` e `100.64.0.10` pelos valores do seu ambiente antes de executar. As faixas privadas da VPC, dos pods e dos Services foram mantidas como configuração do lab.

1. [Etapa 1: preparar os nós](kubeadm-manual/01-preparar-nos.md)
2. [Etapa 2: kubeadm init no control-plane](kubeadm-manual/02-kubeadm-init.md)
3. [Etapa 3: kubectl no seu PC, pela tailnet](kubeadm-manual/03-kubectl-tailnet.md)
4. [Etapa 4: Cilium (a rede dos pods), via Helm](kubeadm-manual/04-cilium.md)
5. [Etapa 5: kubeadm join dos workers](kubeadm-manual/05-join-workers.md)
