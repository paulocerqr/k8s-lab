# k8s-lab — Plano

> Objetivo: demonstrar Cloud (GCP) e Kubernetes autogerenciado rodando aplicações reais, integrado à infraestrutura híbrida existente (Tailscale, Cloudflare, Beszel).
> Status: **em execução** (semana 1). Atualizado: 2026-10-17.
> Projetos relacionados: `beszel-infra` (observabilidade de hosts), `job-radar` (aplicação), UtilityDev (aplicação).

---

## 1. Restrições

| Restrição | Valor | Consequência |
|---|---|---|
| Créditos GCP (Free Trial) | R$ 1.738,20 restantes | Cobrem ~3 VMs ligadas por 1 mês com folga. **Custo não é o gargalo.** |
| **Expiração dos créditos** | **16/11/2026** | **Prazo é o gargalo.** Teardown completo até **15/11/2026**. |
| Cotas GCP (verificadas em 17/10) | 32 vCPUs (todas as regiões), 24 VMs, 8 IPv4 externos e 500 GB de disco SSD em us-central1 | **Cota não limita.** Topologia 4 + 2 + 2 usa 8/32 vCPUs. O limite real é o **saldo** (~US$ 310). |
| Produção existente | Servidor doméstico (UtilityDev, n8n) | O lab **não depende** da produção e **não altera** a produção. |
| Job Radar | Ainda não implementado; MVP estimado em ~1–1,5 semana | **App principal do lab**, desenvolvido em trilha paralela ao cluster (§7, §8). |
| VMs existentes (`serverk3s`, worker) | Paradas; só com Beszel agent | **Serão excluídas** e recriadas pelo Terraform (K12). |
| UtilityDev | Sem imagens publicadas | Staging vira **bônus** (semana 4), só se sobrar tempo. |
| Tempo disponível | 3–4 h/dia (~25 h/semana) | Duas trilhas: ~60% infra / ~40% Job Radar nas semanas 1–2. |
| Créditos AWS | ~US$ 115, validade ~80 dias (~05/01/2027) | Ponte pós-GCP para o Job Radar (§9). |

Estimativa (preços on-demand aproximados, us-central1, sem desconto):

| Recurso | US$/mês |
|---|---|
| `cp-1` e2-standard-4 | ~100 |
| `worker-1` e2-standard-2 | ~50 |
| `worker-2` e2-standard-2 | ~50 |
| Discos (3 × 30 GB pd-balanced) + IPs efêmeros | ~15 |
| **Total** | **~215 (~R$ 1.200)** |

Mesmo assim: **budget alert** em 50%, 80% e 100% do saldo.

---

## 2. Objetivos

| # | Objetivo | Evidência para o portfólio |
|---|---|---|
| O1 | Infraestrutura como código, do zero | Terraform cria VMs, firewall e budget; `terraform destroy` reproduzível |
| O2 | Cluster Kubernetes montado do zero | kubeadm + Cilium em Debian 13 |
| O3 | Acesso administrativo privado | kubectl e SSH somente via Tailscale; 6443 fechado na internet |
| O4 | Publicação sem portas abertas | Cloudflare Tunnel → Traefik (Gateway API) → apps, TLS na borda |
| O5 | Aplicação real com estado | Job Radar (API, worker singleton, CronJobs de coleta, Postgres, n8n) |
| O6 | Resiliência | `kubectl drain` de um worker sem indisponibilidade |
| O7 | Observabilidade em duas camadas | Beszel (hosts) + kube-prometheus-stack (cluster) |
| O8 | Entrega contínua | GitHub Actions → GHCR → ArgoCD |
| O9 | Encerramento documentado | Backup, evidências, `terraform destroy` |

Escopo mínimo: **O1–O7**. **O8** e o staging do **UtilityDev** são diferenciais.

---

## 3. Topologia

```
  CachyOS (admin)                                     Usuários
      │ kubectl / ssh                                     │ HTTPS
      │ (tailnet)                                         ▼
      │                                          ┌──────────────────┐
      │                                          │ Cloudflare (DNS, │
      │                                          │ TLS, Tunnel)     │
      │                                          └────────┬─────────┘
      │                                                   │ conexão de SAÍDA
┌─────┼────────── GCP · us-central1-a · VPC lab ──────────┼──────────────────────────────┐
│     ▼                                                   │                              │
│  ┌──────────────────────────┐  ┌────────────────────────┴─┐  ┌──────────────────────┐ │
│  │ cp-1       e2-standard-4 │  │ worker-1  e2-standard-2  │  │ worker-2 e2-standard-2│ │
│  │ 4 vCPU / 16 GB           │  │ (Terraform)              │  │ (Terraform)           │ │
│  │                          │  │                          │  │                       │ │
│  │ control plane (kubeadm)  │  │ apps (Job Radar, ...)    │  │ apps (réplicas)       │ │
│  │ + monitoring (toleration)│  │ cloudflared (réplica)    │  │ cloudflared (réplica) │ │
│  │   Prometheus, Grafana    │  │ Traefik (Gateway API)    │  │ Traefik (Gateway API) │ │
│  │ Tailscale · Beszel agent │  │ Tailscale · Beszel agent │  │ Tailscale · Beszel ag.│ │
│  └──────────────────────────┘  └──────────────────────────┘  └───────────────────────┘ │
│              CNI Cilium · Pod CIDR 10.244.0.0/16 · Service CIDR 10.96.0.0/12            │
└──────────────────────────────────────────────────────────────────────────────────────────┘
         │ métricas de host (WebSocket via Tailscale)
         ▼
  Beszel Hub (ServerLow2 · Oracle)
```

> Distribuição dos pods é ilustrativa; o scheduler decide. Restrições explícitas apenas onde justificado (monitoring no `cp-1`, Postgres com volume local).

### 3.1 Nós

| Nó | Tipo | SO | Estado | Papel |
|---|---|---|---|---|
| `cp-1` | e2-standard-4 (4 vCPU / 16 GB / 30 GB) | Debian 13 | A criar (Terraform) | Control plane + monitoring |
| `worker-1` | e2-standard-2 (2 vCPU / 8 GB / 30 GB) | Debian 13 | A criar (Terraform) | Worker |
| `worker-2` | e2-standard-2 (2 vCPU / 8 GB / 30 GB) | Debian 13 | A criar (Terraform) | Worker |

- Todos na **mesma zona** (`us-central1-a`): tráfego interno sem custo, latência mínima.
- As VMs antigas (`serverk3s` e o worker criado pelo console) são **excluídas** antes do `terraform apply` (ver checklist da semana 1).
- O control plane mantém o taint padrão; apenas o stack de monitoring recebe `toleration` + `nodeSelector` para usar a RAM ociosa.

### 3.2 Rede e firewall (GCP)

| Regra | Origem | Destino | Portas | Motivo |
|---|---|---|---|---|
| Interno do cluster | `10.10.0.0/24` (subnet do lab) | nós do lab | todas | kubelet, etcd, Cilium (VXLAN/health) |
| Tailscale | `0.0.0.0/0` | nós | UDP 41641 | Conexão direta (sem relay DERP); opcional |
| SSH via IAP | `35.235.240.0/20` (faixa do IAP) | nós | TCP 22 | Acesso de emergência se o Tailscale falhar |
| SSH público | — | — | **fechado** | SSH normal via Tailscale SSH (K20) |
| API 6443 pública | — | — | **fechado** | kubectl via Tailscale |
| HTTP/HTTPS público | — | — | **fechado** | Entrada via Cloudflare Tunnel (saída) |

- VPC própria do lab (K19): a VPC `default` traz regras que liberam SSH/RDP/ICMP para a internet.
- IPs externos efêmeros só para **saída** (pacotes, imagens, Tailscale); nenhuma porta de entrada aberta. Cloud NAT fica como evolução (custo extra sem ganho no lab).

### 3.3 Integrações com a infraestrutura existente

| Integração | Como | Cuidado |
|---|---|---|
| **Tailscale** | Instalado em todos os nós; tag `tag:k8s-lab` nas ACLs | Restringir quem alcança 6443/22 nas ACLs da tailnet |
| **kubectl remoto** | `kubeadm init --apiserver-cert-extra-sans=<ip-tailscale>,<nome>.ts.net` | Sem o SAN, o certificado rejeita o acesso pelo IP da tailnet |
| **Cloudflare** | Tunnel (`cloudflared`) como Deployment, 2 réplicas; DNS `*.lab.<dominio>` | Token do tunnel em SealedSecret |
| **Beszel** | Agent em cada nó via `beszel-infra/deploy/agent/compose.yml` (ou binário/systemd) | Usar `dns: 100.100.100.100` (Incidente 001) |
| **DNS da tailnet dentro do cluster** | Somente se algum pod precisar de `*.ts.net` | Resolvedor da GCP não resolve `*.ts.net` (Incidente 001); exigiria `forward` no CoreDNS para `100.100.100.100` |

> **Containerd vs Docker:** o modelo de Beszel agent usa Docker Compose. Nos nós do cluster **não instalar Docker** só para o agent (decisão já registrada no `beszel-infra`): usar o agent **binário + systemd**. Métricas de containers ficam com o Prometheus.

---

## 4. Decisões

| # | Decisão | Alternativas | Motivo |
|---|---|---|---|
| K01 | **kubeadm**, com *timebox* de 2 dias; fallback **k3s** | k3s direto, GKE | Domínio dos componentes (etcd, certificados, upgrade); base da CKA. Se o cluster não estiver `Ready` em 2 dias, trocar para k3s para não comprometer o prazo. |
| K02 | **Cilium** como CNI | Calico, Flannel | NetworkPolicy + Hubble para documentação visual. |
| K03 | **Cloudflare Tunnel** para entrada pública | hostPort + IP estático; CCM + LB da GCP | Sem portas abertas, sem IP fixo, TLS na borda, DNS já na Cloudflare. Resolve a ausência de LoadBalancer fora do GKE. |
| K04 | ~~ingress-nginx~~ → substituída pela K23 | — | O projeto ingress-nginx foi aposentado (sem manutenção, inclusive de segurança, desde mar/2026). |
| K05 | **Tailscale** para administração | IP público + firewall por IP; IAP | Já é o padrão da infraestrutura; 6443 e 22 fora da internet. |
| K06 | Armazenamento: **local-path-provisioner**; evolução para **GCE PD CSI** se houver tempo | Só PD CSI | Rapidez. Limitação (volume preso ao nó) documentada. |
| K07 | **Kustomize** para apps; **Helm** para componentes de terceiros | Helm para tudo | Legibilidade dos manifests próprios. |
| K08 | **Sealed Secrets** | SOPS, External Secrets | Commitável no Git, sem dependências externas. |
| K09 | **Beszel nos hosts + kube-prometheus-stack no cluster** | Só um dos dois | Beszel já existe e cobre hosts; Prometheus cobre pods, control plane e apps. |
| K10 | Monitoring no `cp-1` via toleration | Monitoring nos workers | Aproveita 14 GB ociosos do control plane; workers ficam livres para apps. |
| K11 | **App principal: Job Radar**; staging do UtilityDev como bônus | UtilityDev primeiro | Job Radar nasce pronto para Kubernetes (12-factor, health, migrations separadas, CronJob) e não toca produção; UtilityDev exige containerizar um sistema em produção. MVP cabe em ~1–1,5 semana. |
| K12 | **Excluir as VMs do console e recriar tudo via Terraform** | `terraform import` das existentes | Não há estado a preservar (só o Beszel agent); nomes e config ficam padronizados; um único caminho reproduzível. |
| K13 | Lab **isolado da produção**: n8n próprio, banco próprio, bot/chat de Telegram próprios | Reaproveitar serviços de casa | Falha no lab não afeta produção e vice-versa. |
| K14 | Imagens no **GHCR** | Artifact Registry | Sobrevive ao fim dos créditos. Pacotes privados exigem `imagePullSecret` (SealedSecret) no cluster. |
| K16 | (Bônus) Containerizar o UtilityDev **num branch/PR do próprio repo**, sem mudar a produção | Dockerfiles só no k8s-lab | Imagem pertence ao app; produção segue no compose atual. |
| K17 | **startup-script** (via Terraform) para bootstrap mínimo + **Ansible** para configuração dos nós | Só Ansible; cloud-init; configuração manual | O startup-script coloca a VM na tailnet no boot (as imagens Debian da GCP não têm cloud-init; ver incidente 001) (resolve o acesso SSH sem porta pública); Ansible orquestra a ordem `init` → `join` e é idempotente. VMs serão recriadas várias vezes (erro, fallback k3s, ponte AWS); playbooks do Beszel/Tailscale reaproveitáveis em outros hosts. |
| K18 | **Manual primeiro, automatizar depois**: kubeadm feito à mão uma vez com anotações, depois convertido em playbooks | Escrever playbooks antes de entender os passos | Aprendizado (CKA) e cumprimento do marco de 20/10 sem depender da automação pronta. |
| K19 | **VPC própria** (`lab`, subnet `10.10.0.0/24`) | VPC `default` | A `default` libera SSH/RDP/ICMP para `0.0.0.0/0`; uma VPC dedicada começa fechada e é destruída junto com o lab. |
| K20 | **Tailscale SSH** para acessar os nós | Chaves SSH gerenciadas (metadata/OS Login) | Sem chaves para distribuir/rotacionar; acesso controlado pelas ACLs da tailnet; o Ansible usa o mesmo caminho. IAP fica como emergência. |
| K21 | Auth key do Tailscale **reutilizável, pré-autorizada, com tag e validade curta** (não efêmera) | Key efêmera | Nós efêmeros são removidos da tailnet ao ficarem offline (VM parada). Com tag, os nós não expiram; a validade curta só limita novos registros com a key. |
| K22 | **State do Terraform local**, fora do Git | Backend em bucket GCS | Operador único; o bucket seria mais um recurso a criar e sumiria com os créditos. O state contém dados sensíveis (ex.: auth key no user-data). |
| K23 | **Gateway API com o Traefik** como proxy reverso do cluster (Service ClusterIP, 2 réplicas) | ingress-nginx (aposentado); **Gateway API do Cilium** (tentada e abandonada) | Gateway API é o sucessor oficial do Ingress. A do Cilium não alcança backends no mesmo nó do Envoy (bug aberto [cilium#47940](https://github.com/cilium/cilium/issues/47940); [incidente 002](incidentes/002-gateway-cilium-backend-mesmo-no.md)); o Traefik roda como pod comum e não usa esse caminho. |
| K24 | **Cilium com kube-proxy replacement** (kube-proxy removido) | Manter o kube-proxy | Services em eBPF, sem milhares de regras de iptables. Mantido mesmo sem a Gateway do Cilium: funciona e é independente dela. Clusters novos já nascem sem kube-proxy (`skipPhases`); o cluster atual foi migrado no lugar (`migracao-kube-proxy.yml`). |
| K25 | Endereços **`<app>-lab.utileasy.com.br`** | `*.lab.utileasy.com.br`; caminhos em `lab.utileasy.com.br` | Um nível de subdomínio é coberto pelo certificado grátis da Cloudflare (Universal SSL); dois níveis exigiriam o Advanced Certificate Manager (pago). Cada app fica na raiz do próprio domínio. |
| K15 | Teardown até **15/11/2026** | Deixar expirar | Evita cobrança caso a conta seja convertida para paga; garante backup antes. |

---

## 5. Workloads

### 5.1 Namespaces

| Namespace | Conteúdo | Nó preferencial |
|---|---|---|
| `kube-system` | Cilium, CoreDNS, sealed-secrets, local-path | — |
| `traefik` | Traefik (Gateway `lab`) | workers |
| `cloudflared` | túnel da Cloudflare | workers |
| `monitoring` | kube-prometheus-stack (Prometheus, Grafana, Alertmanager) | `cp-1` |
| `utilitydev-stg` | frontend, backend, redis, postgres | workers |
| `job-radar` | api, worker, cronjobs, postgres, n8n (bônus) | workers |
| `argocd` | ArgoCD (diferencial) | workers |

### 5.2 Entrada

```
Usuário → Cloudflare (TLS) → Tunnel → cloudflared (pod) → Traefik (Gateway API, ClusterIP) → Service → Pods
```

- `cloudflared`: Deployment 2 réplicas com `topologySpreadConstraints` (uma por worker) — o drain de um worker não derruba a entrada.
- Hostnames: `utilitydev-stg.lab.<dominio>`, `grafana.lab.<dominio>` (protegido por Cloudflare Access), `jobradar.lab.<dominio>` (bônus).
- Grafana e ArgoCD: preferir acesso só pela tailnet (`kubectl port-forward` ou Service exposto via Tailscale) se não houver Cloudflare Access configurado.

### 5.3 Job Radar (app principal)

Conforme `docs/PLANO.md` §3.3 do repo `job-radar`:

| Recurso | Tipo | Detalhes |
|---|---|---|
| `jobradar-migrar` | Job | `job-radar migrar` |
| `jobradar-api` | Deployment 2 réplicas | `/healthz`, `/readyz`; PDB |
| `jobradar-worker` | Deployment 1 réplica, `strategy: Recreate` | sem schedulers duplicados |
| `jobradar-coletar-<fonte>` | CronJob | `timeZone: America/Sao_Paulo`, `concurrencyPolicy: Forbid`, `COLETA_NO_WORKER=false` |
| postgres | StatefulSet + PVC | |
| n8n | Deployment + PVC | **instância própria do lab** (K13) |

| Ingress | host `jobradar.lab.<dominio>` | |
| NetworkPolicy | — | Postgres só aceita tráfego de pods `part-of=job-radar` |

Somente providers de IA via API (Groq/NVIDIA/Gemini) no cluster. Bot/chat de Telegram próprios do lab (K13).

### 5.4 UtilityDev staging (bônus)

| Recurso | Tipo | Detalhes |
|---|---|---|
| frontend (Next.js) | Deployment, 2 réplicas + Service | probes HTTP; PDB `minAvailable: 1` |
| backend (Django) | Deployment, 2 réplicas + Service | `migrate` como Job; `collectstatic` na imagem |
| redis | Deployment 1 réplica (sem persistência) ou StatefulSet | cache/staging |
| postgres | StatefulSet + PVC (local-path) | dados **sintéticos/anonimizados**, nunca cópia da produção |
| Ingress | host `utilitydev-stg.lab.<dominio>` | |
| NetworkPolicy | — | Postgres/Redis só aceitam tráfego do backend |

> Pré-requisito (**não existe ainda**): Dockerfiles de produção (multi-stage, não-root) para frontend e backend, configuração 100% por variáveis de ambiente e workflow do GitHub Actions publicando no GHCR com tag `sha`. Ver K16 e semana 2.

### 5.5 Recursos iniciais (ajustar após medir no Grafana)

| Pod | requests | limits |
|---|---|---|
| frontend / api | 100m / 192Mi | 500m / 384Mi |
| backend Django | 150m / 256Mi | 750m / 512Mi |
| worker / cronjobs | 50–100m / 128–192Mi | 300–500m / 256–384Mi |
| postgres | 100m / 256Mi | 500m / 512Mi |
| redis | 50m / 64Mi | 200m / 128Mi |
| cloudflared | 25m / 32Mi | 200m / 128Mi |
| Prometheus | 300m / 1.5Gi | 1 / 3Gi |

---

## 6. Estrutura do repositório

```
k8s-lab/
├── README.md                     # visão geral, diagrama, como reproduzir, custos reais, limitações
├── Makefile                      # infra | cluster | plataforma | apps | backup | destruir
├── docs/
│   ├── 00-arquitetura.md
│   ├── 01-terraform.md           # VMs, firewall, budget
│   ├── 02-tailscale.md           # ACLs, SANs do apiserver, kubectl remoto
│   ├── 03-kubeadm.md             # passo a passo + problemas encontrados
│   ├── 04-cilium.md
│   ├── 05-storage.md
│   ├── 06-cloudflare-tunnel.md
│   ├── 07-observabilidade.md     # Beszel (hosts) + Prometheus/Grafana (cluster)
│   ├── 08-job-radar.md
│   ├── 09-resiliencia.md         # drain, kill de pod, PDB — com evidências
│   ├── 10-gitops.md              # diferencial
│   ├── 11-utilitydev-staging.md  # bônus
│   ├── 12-encerramento.md        # backup, custos finais, destroy, lições
│   ├── decisoes/                 # ADRs K01..K15
│   ├── incidentes/               # mesmo formato do beszel-infra
│   └── img/
├── terraform/
│   ├── versions.tf               # provider google fixado
│   ├── main.tf                   # VMs, firewall, (opcional) Cloud NAT
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example  # sem IDs reais no Git
│   └── bootstrap.sh.tftpl        # startup-script: usuário admin + Tailscale (tag:k8s-lab, SSH)
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.example.ini     # hosts por nome MagicDNS do Tailscale; grupos control_plane / workers
│   ├── group_vars/
│   │   ├── all.yml               # versões fixadas (kubernetes, containerd, cilium, beszel)
│   │   └── all.vault.yml         # ansible-vault: tokens Beszel (não versionar sem cifrar)
│   ├── site.yml                  # importa os playbooks na ordem
│   └── playbooks/
│       ├── 00-base.yml           # pacotes, swap off, sysctl, módulos, containerd (SystemdCgroup)
│       ├── 01-beszel-agent.yml   # binário + systemd; reutilizável fora do lab
│       ├── 02-kubeadm-pacotes.yml# repo pkgs.k8s.io, kubeadm/kubelet/kubectl com hold
│       ├── 03-kubeadm-init.yml   # init no control_plane (SANs da tailnet) + Cilium + busca join command
│       ├── 04-kubeadm-join.yml   # join dos workers usando o comando capturado
│       └── 05-kubeconfig.yml     # copia admin.conf para o CachyOS, apontando ao nome da tailnet
├── notas/
│   └── kubeadm-manual.md         # registro da instalação manual (K18) — fonte dos playbooks
├── cluster/                      # plataforma (Helm values + Kustomize)
│   ├── cilium/
│   ├── local-path/
│   ├── sealed-secrets/
│   ├── traefik/
│   ├── cloudflared/
│   ├── monitoring/               # kube-prometheus-stack values (toleration p/ cp-1)
│   └── argocd/                   # diferencial
├── apps/
│   ├── job-radar/
│   │   ├── base/
│   │   └── overlays/
│   │       ├── gcp/
│   │       └── aws/              # ponte pós-créditos em k3s (ver §9)
│   └── utilitydev-stg/           # bônus
│       ├── base/
│       └── overlays/gcp/
└── scripts/
    ├── kubeconfig.sh             # obtém admin.conf via Tailscale
    ├── demo-drain.sh             # roteiro da demonstração de resiliência
    └── backup.sh                 # pg_dump dos bancos do lab
```

**Higiene de publicação** (lições do `beszel-infra`): nenhum IP real, ID de projeto, e-mail de service account, usuário SSH ou caminho de chave no Git — usar `*.example` e variáveis. Revisar histórico antes de tornar público.

---

## 7. Cronograma (17/10 → 16/11/2026)

Duas trilhas paralelas com 3–4 h/dia. A trilha **Infra** tem prioridade quando houver conflito (tem prazo duro); a trilha **App** só precisa entregar a imagem até o início da semana 3.

```
             Sem 1 (17–23/10)         Sem 2 (24–30/10)          Sem 3 (31/10–06/11)        Sem 4 (07–13/11)
Infra (60%): Terraform + kubeadm  →  plataforma + tunnel   →   deploy Job Radar + demos →  GitOps + docs
App   (40%): Job Radar Fase 0     →  Job Radar Fase 1 (MVP) →  calibração com vagas reais → (bônus) UtilityDev
```

### Semana 1 — 17/10 a 23/10

**Infra**
- [x] Cotas verificadas (32 vCPUs, 8 IPs, 500 GB SSD). 
- [ ] Criar budget alerts.
- [ ] Remover o sistema `serverk3s` do Beszel Hub e aproveitar para **rotacionar o token** pendente do `beszel-infra`.
- [x] Remover as VMs antigas; **excluir VMs, discos, snapshots e política de snapshot** criados pelo console.
- [x] ACL `tag:k8s-lab` no Tailscale (tagOwners + regra de SSH); gerar auth key **reutilizável, pré-autorizada, com a tag e validade de 1 dia** (K21).
- [x] Terraform: criar `cp-1`, `worker-1`, `worker-2`, firewall (§3.2) e `startup-script` com o Tailscale (K17).
- [x] Conferir os 3 nós na tailnet e SSH funcionando pelo nome MagicDNS.
- [x] **Manual (K18):** preparar nós, `kubeadm init` com SANs da tailnet, Cilium, `join` dos workers — registrando cada comando em `notas/kubeadm-manual.md`.
- [x] kubectl do CachyOS via Tailscale.
- **Marco (20/10):** `kubectl get nodes` → 3 `Ready`. ✅ **cumprido em 19/10** ([03-kubeadm.md](03-kubeadm.md)).
- [x] **Automação:** notas convertidas em playbooks (`00`–`06`; Beszel opcional no `06`). Ver [04-ansible.md](04-ansible.md).
- [x] **Teste de recriação:** `destroy` → `apply` → `site.yml`, 3 nós `Ready` sem passo manual: **≈ 6 min** (apply 123 s + tailnet 20 s + Ansible 217 s).
- **Marco (23/10):** cluster reproduzível do zero; tempo de recriação registrado no README. ✅ **cumprido em 19/10**.

**App (Job Radar — Fase 0 do `PLANO.md`)**
- [ ] Projeto, ruff/pytest, config, logs JSON, CLI Typer.
- [ ] Models + migration inicial; `seed`.
- [ ] `/healthz`, `/readyz`; Dockerfile; docker-compose local.
- [ ] GitHub Actions publicando no GHCR.
- **Marco (23/10):** `docker compose up` local sobe api + worker + postgres; imagem `ghcr.io/<user>/job-radar:<sha>` publicada.

### Semana 2 — 24/10 a 30/10

**Infra**
- [x] local-path-provisioner (StorageClass padrão). Ver [06-plataforma.md](06-plataforma.md).
- [x] Sealed Secrets, com cópia da chave no PC para as recriações.
- [x] Proxy reverso: Gateway API com o Traefik (K23); kube-proxy substituído pelo Cilium (K24). Ver [05-entrada.md](05-entrada.md).
- [x] cloudflared (2 réplicas) + rota/DNS `<app>-lab.utileasy.com.br` na Cloudflare (K25). Ver [07-cloudflare-tunnel.md](07-cloudflare-tunnel.md).
- [x] App de teste (`whoami`) publicado em https://teste-lab.utileasy.com.br (21/10).
- [x] kube-prometheus-stack no `cp-1`; dashboards de nós e pods. Ver [08-observabilidade.md](08-observabilidade.md).
- **Marco (30/10):** app de teste acessível via HTTPS sem portas abertas; Grafana com métricas. ✅ **cumprido em 21/10**.

**App (Job Radar — Fase 1 do `PLANO.md`)**
- [ ] Coletores Gupy e GitHub; normalizador; dedupe; pré-filtro (Brasília-DF).
- [ ] Máquina de estados; alimentador; expirador.
- [ ] Auditor com provider `openai_compatible` (Groq/NVIDIA/Gemini) + `cli` (só local).
- [ ] Webhook n8n → Telegram com confirmar/ignorar.
- **Marco (30/10):** no ambiente local, uma recomendada real chega no Telegram.

### Semana 3 — 31/10 a 06/11 · Job Radar no cluster e resiliência

**Infra**
- [ ] Manifests `apps/job-radar` (§5.3): Job de migração, api, worker, CronJobs, Postgres, n8n do lab, Ingress, NetworkPolicy, PDB.
- [ ] `imagePullSecret` (se o pacote GHCR for privado).
- [ ] Demonstrações: `kubectl drain worker-1`, kill de pod, rollout e rollback, CronJob executando — gravar evidências.
- [ ] Backup do Postgres (CronJob → bucket GCS ou cópia via Tailscale).
- [ ] Se o MVP atrasar: publicar só `api` + `migrar` + Postgres (já demonstra o essencial) ou usar `podinfo` + Postgres como substituto.
- **Marco (06/11):** Job Radar no cluster, recomendações chegando no Telegram do lab, sobrevivendo ao drain de um worker.

**App**
- [ ] Calibração do prompt/score com vagas reais; ajustes de pré-filtro.
- [ ] Correções que surgirem no deploy (probes, sinais, recursos).

### Semana 4 — 07/11 a 13/11 · Diferenciais e documentação
- [ ] ArgoCD (app-of-apps) com CI do Job Radar atualizando a tag da imagem.
- [ ] Ajuste de requests/limits a partir do Grafana.
- [ ] (Bônus) UtilityDev staging (§5.4, K16).
- [ ] Documentação `docs/00..12`, prints revisados, custo real consumido.

### Encerramento — 14/11 a 15/11
- [ ] Backup final do Postgres do Job Radar exportado para fora da GCP (vai para a ponte AWS, §9).
- [ ] Prints/gravações finais; custo total registrado.
- [ ] Remover agents do lab do Beszel Hub; remover nós da tailnet; apagar registros DNS e o tunnel.
- [ ] `terraform destroy`; conferir no console que não restaram discos, IPs ou snapshots.
- **Prazo duro:** créditos expiram em **16/11/2026**.

---

## 8. Relação com o Job Radar

O Job Radar é o app principal do lab e é desenvolvido em paralelo. Pontos de contato:

| Data | O lab precisa de | Se não estiver pronto |
|---|---|---|
| 23/10 | Imagem no GHCR com health e `migrar` | Semana 2 de infra não depende disso; recuperar na semana 2 |
| 30/10 | MVP funcional (coleta → auditoria → Telegram) | Semana 3 publica o que existir (api + Postgres); demos de resiliência não dependem do MVP completo |
| 06/11 | Job Radar estável no cluster | Usar `podinfo` como substituto nas evidências; Job Radar vai direto para a ponte AWS |

---

## 9. Pós-créditos

O servidor doméstico (i5, 6 GB RAM) roda produção (UtilityDev, n8n) e **não deve receber k3s** competindo por memória.

| Opção | Onde | Prós | Contras |
|---|---|---|---|
| **A (recomendada)** | docker-compose no servidor doméstico | Leve; reaproveita o n8n existente; CLI Claude/Codex disponível | Sai do Kubernetes |
| B | k3s single-node na EC2 t3.small (~US$ 115 em créditos, até ~05/01/2027) | Mantém Kubernetes por ~2 meses a mais; reaproveita `overlays/aws`; custo ~US$ 20/mês (VM + EBS) cabe nos créditos | 2 GB RAM apertados (Postgres + api + worker, sem n8n); também temporário |
| C | k3s em ServerLow1 (Oracle Micro, 1 GB) | Gratuito | Inviável para Postgres + app |

**Caminho sugerido:** B como ponte (16/11 → ~05/01/2027), se o Job Radar estiver pronto; A como destino permanente. Decisão final na semana 4.

Se B for adotada: a EC2 entra na tailnet e no Beszel; imagens vêm do mesmo GHCR; budget alert na AWS; teardown antes de os créditos AWS expirarem.

---

## 10. Riscos

| Risco | Mitigação |
|---|---|
| kubeadm consome tempo demais | Timebox de 2 dias + fallback k3s (K01) |
| Automação Ansible atrasa a semana 1 | Cluster manual já cumpre o marco de 20/10; playbooks podem deslizar para a semana 2 sem bloquear a plataforma |
| Auth key do Tailscale vazada no state do Terraform ou no metadata da VM | Key com tag e validade de 1 dia (inútil depois); variável sensível; `terraform.tfstate` fora do Git; revogar a key após o `apply` |
| Gasto acima do previsto (ex.: VMs maiores, discos esquecidos) | Budget alerts; manter 4 + 2 + 2; excluir as VMs antigas logo (discos e IPs parados também cobram) |
| Nó com local-path cai e leva o Postgres | Backup diário; staging com dados sintéticos |
| Tailscale fora do ar impede administração | IAP/console serial da GCP como acesso de emergência documentado |
| Pods precisando de `*.ts.net` | Evitar; se necessário, `forward` no CoreDNS (Incidente 001) |
| Vazamento de dados reais no repo público | `*.example`, revisão de histórico, nada de produção no staging |
| Lab interferindo na produção | Isolamento total (K13) |
| Esquecer recursos ligados após 16/11 | Checklist de encerramento + conferência no console |
