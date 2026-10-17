# k8s-lab

Cluster Kubernetes autogerenciado (kubeadm) em 3 VMs na Google Cloud, montado do zero com Terraform e Ansible, acessado só pela tailnet (Tailscale) e publicado sem portas abertas (Cloudflare Tunnel). A aplicação principal é o [Job Radar](https://github.com/paulocerqr/job-radar).

**Status:** semana 1 de 4 — infraestrutura e cluster. Plano completo, decisões e cronograma: [`docs/plano.md`](docs/plano.md).

## Arquitetura (resumo)

| Nó | Máquina | Papel |
|---|---|---|
| `cp-1` | e2-standard-4 (4 vCPU / 16 GB) | control plane + monitoring |
| `worker-1` | e2-standard-2 (2 vCPU / 8 GB) | aplicações |
| `worker-2` | e2-standard-2 (2 vCPU / 8 GB) | aplicações |

- **Rede:** VPC própria; nenhuma porta de entrada aberta para a internet. Entre os nós, só a subnet do lab.
- **Acesso:** Tailscale SSH e `kubectl` pela tailnet; IAP como emergência.
- **Publicação:** Cloudflare Tunnel → ingress-nginx → serviços.
- **Observabilidade:** Beszel nos hosts + kube-prometheus-stack no cluster.

## Pré-requisitos

- `gcloud`, `terraform`, `ansible`, `kubectl`, `helm`
- Projeto GCP com faturamento (créditos) e a Compute Engine API habilitada
- Tailscale na máquina de administração, com `tag:k8s-lab` configurada nas ACLs

## Subindo a infraestrutura

```bash
gcloud auth application-default login
cd terraform
cp terraform.tfvars.example terraform.tfvars   # preencha projeto e auth key
terraform init
terraform plan
terraform apply
```

Nada sensível vai para o Git: `terraform.tfvars`, state, kubeconfig e `.env` estão no `.gitignore`.

## Créditos e encerramento

O lab roda com créditos temporários que expiram em **16/11/2026**. O encerramento (backup, evidências e `terraform destroy`) está no plano, seção 7.
