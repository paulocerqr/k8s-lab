# k8s-lab

Cluster Kubernetes autogerenciado (kubeadm) em 3 VMs na Google Cloud, montado do zero com Terraform e Ansible, acessado só pela tailnet (Tailscale) e publicado sem portas abertas (Cloudflare Tunnel). A aplicação principal é o [Job Radar](https://github.com/paulocerqr/job-radar).

**Status:** semana 3 de 4 concluída. Cluster de 3 nós (Kubernetes 1.37.1, Cilium 1.20.3 sem kube-proxy), **recriável do zero em ≈ 6 min** com Terraform + Ansible. O Job Radar roda no cluster e está público em https://jobradar-lab.utileasy.com.br (Cloudflare Tunnel → Traefik), com coleta por CronJob, auditoria por IA e notificações no Telegram. Próximo: demonstrações de resiliência (drain, rollout e rollback).

| Do zero ao cluster pronto | Tempo |
|---|---|
| `terraform apply` (rede, firewall, 3 VMs) | 123 s |
| Nós na tailnet | 20 s |
| `ansible-playbook site.yml` | 217 s |

![kubectl get nodes](docs/evidencias/semana-1/img/07-kubectl-nodes.png)

Mais evidências (saídas reais de cada etapa): [semana 1](docs/evidencias/semana-1/README.md), [semana 2](docs/evidencias/semana-2/saidas), [semana 3](docs/evidencias/semana-3/README.md). Plano completo, decisões e cronograma: [`docs/plano.md`](docs/plano.md).

## Documentação

| Documento | Conteúdo |
|---|---|
| [00 — Ferramentas](docs/00-ferramentas.md) | O que é cada ferramenta (gcloud, Terraform, Ansible, kubectl, Helm, Tailscale) e como foi instalada |
| [01 — Terraform](docs/01-terraform.md) | Cada arquivo do Terraform, o que cria as VMs e a rede, comandos executados |
| [02 — Acesso pelo Tailscale](docs/02-acesso-tailscale.md) | Tag, auth key, registro automático dos nós e SSH |
| [03 — Cluster com kubeadm](docs/03-kubeadm.md) | Preparação dos nós, `init`, `kubectl` pela tailnet, Cilium, `join`, teste de rede e problemas encontrados |
| [04 — Ansible](docs/04-ansible.md) | Playbooks, idempotência e o teste de recriação do zero (tempos) |
| [05 — Entrada do cluster](docs/05-entrada.md) | Cilium no lugar do kube-proxy; Traefik pela Gateway API |
| [06 — Plataforma](docs/06-plataforma.md) | Volumes persistentes (local-path) e segredos cifrados no Git (Sealed Secrets) |
| [07 — Cloudflare Tunnel](docs/07-cloudflare-tunnel.md) | Publicação em HTTPS sem portas abertas; token como Sealed Secret; rotas |
| [08 — Observabilidade](docs/08-observabilidade.md) | Prometheus, Alertmanager e Grafana no `cp-1`; o que é coletado |
| [09 — Job Radar](docs/09-job-radar.md) | O app no cluster: Postgres, API, worker, CronJobs; problemas do primeiro deploy |
| [10 — Resiliência](docs/10-resiliencia.md) | Drain de cada worker medido de fora: API sem queda num, banco preso ao nó no outro |
| [11 — Discos gerenciados](docs/11-discos-gerenciados.md) | GCE PD CSI: o Postgres muda de nó com os dados; migração sem perda |
| [12 — Backup](docs/12-backup.md) | `pg_dump` diário para o GCS, sem chave e sem poder apagar; restauração testada |
| [Incidente 001](docs/incidentes/001-cloud-init-debian-gcp.md) | Nós fora da tailnet: Debian da GCP sem cloud-init |
| [Incidente 002](docs/incidentes/002-gateway-cilium-backend-mesmo-no.md) | Gateway API do Cilium falha para backends no mesmo nó (bug [cilium#47940](https://github.com/cilium/cilium/issues/47940)) |
| [Evidências — semana 1](docs/evidencias/semana-1/README.md) | Saídas reais dos comandos (com imagens): Terraform, firewall, tailnet, nós, pods, Cilium, teste de rede e Ansible |
| [Evidências — semana 2](docs/evidencias/semana-2/saidas) | Entrada, plataforma, Cloudflare Tunnel e observabilidade |
| [Evidências — semana 3](docs/evidencias/semana-3/README.md) | Job Radar no cluster: pods, API pública, coleta, auditoria e Telegram |
| [Evidências — semana 4](docs/evidencias/semana-4/README.md) | Drain dos workers com sonda pública |

## Arquitetura (resumo)

| Nó | Máquina | Papel |
|---|---|---|
| `cp-1` | e2-standard-4 (4 vCPU / 16 GB) | control plane + Prometheus/Grafana |
| `worker-1` | e2-standard-2 (2 vCPU / 8 GB) | aplicações |
| `worker-2` | e2-standard-2 (2 vCPU / 8 GB) | aplicações |

- **Rede:** VPC própria; nenhuma porta de entrada aberta para a internet. Entre os nós, só a subnet do lab.
- **Acesso:** Tailscale SSH e `kubectl` pela tailnet; IAP como emergência.
- **Publicação:** Cloudflare Tunnel → Traefik (Gateway API) → serviços; segredos cifrados no Git (Sealed Secrets).
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
