# 11 — Discos gerenciados: GCE PD CSI driver

O Postgres do Job Radar usava um volume **local-path**: uma pasta no disco do `worker-1`. No teste de drain ([10-resiliencia.md](10-resiliencia.md)), o banco ficou fora do ar até o nó voltar (77 s de `503`, e seria mais numa manutenção real). Agora o volume é um **disco persistente da GCP**, que se desanexa de uma VM e se anexa em outra: o pod do banco renasce em outro worker com os mesmos dados.

## Como funciona

```
PVC (pd-balanced) ──► csi-gce-pd-controller ──► API da GCP: cria o disco (10 GB, us-central1-a)
                                              └► anexa o disco à VM onde o pod foi agendado
pod no worker-1 ──► csi-gce-pd-node (DaemonSet) formata e monta o disco no nó
drain do worker-1 ─► desanexa do worker-1 ─► anexa no worker-2 ─► pod sobe lá, mesmos dados
```

| Peça | Onde | Para quê |
|---|---|---|
| Permissões da conta dos nós | `terraform/main.tf` | O driver chama a API da GCP com a conta da própria VM |
| Driver v1.27.5 (overlay `noauth`) | `cluster/pd-csi/kustomization.yaml` | Controlador (cria/anexa discos) + plugin em cada worker (monta) |
| StorageClass `pd-balanced` | `cluster/pd-csi/storageclass.yaml` | SSD de custo médio; `WaitForFirstConsumer`; `Retain` |
| Playbook | `ansible/playbooks/12-discos.yml` | Aplica tudo (idempotente via `kubectl diff`); no `site.yml` antes do Job Radar |

O overlay `noauth` faz o driver usar as credenciais da VM (servidor de metadados) em vez de uma chave JSON da conta de serviço guardada no cluster: **nenhuma chave para vazar ou rotacionar**.

### Permissões (Terraform)

| Permissão | Por quê |
|---|---|
| `roles/compute.storageAdmin` | Criar, apagar e redimensionar discos |
| Papel customizado `k8sLabPdCsi` | `compute.instances.get`, `attachDisk`, `detachDisk`, `compute.disks.get` |
| `iam.serviceAccountUser` da conta **nela mesma** | Anexar disco numa VM exige poder "agir como" a conta dela; escopo só nessa conta |

O script oficial do driver também dá `roles/editor` ao projeto; aqui não. **Risco aceito:** qualquer pod pode ler o servidor de metadados da VM e usar essas permissões de disco. Em produção: Workload Identity (GKE) ou bloquear `169.254.169.254` para os pods com NetworkPolicy, deixando só o driver.

> O `terraform apply` foi feito pelo dono do projeto: mudanças de IAM ficam fora do que o assistente executa sozinho.

### Escolhas da StorageClass

- **`WaitForFirstConsumer`**: o disco só é criado quando o pod é agendado, na zona do nó. Disco de zona só anexa em VM da mesma zona.
- **`reclaimPolicy: Retain`**: apagar o PVC **não** apaga o disco (proteção dos dados do banco). Para descartar de verdade: mudar o PV para `Delete` antes, ou apagar o disco na GCP.
- **10 GiB**: tamanho mínimo do `pd-balanced`. Custo: ~US$ 1/mês.

## Teste com disco descartável

Pod grava um arquivo no `worker-1`, é apagado, outro pod sobe no `worker-2` com o mesmo PVC ([`12-pd-teste-troca-de-no.txt`](evidencias/semana-4/saidas/12-pd-teste-troca-de-no.txt)):

| Etapa | Tempo |
|---|---|
| Criar o disco e anexar no `worker-1` | 21 s |
| Desanexar do `worker-1` e anexar no `worker-2` | 20 s |
| Conteúdo lido no `worker-2` | `gravado-no-worker-1 em Sat Oct 24 06:34:52 UTC 2026` |

## Migração do Postgres (24/10/2026)

[`13-migracao-postgres.txt`](evidencias/semana-4/saidas/13-migracao-postgres.txt)

| # | Passo | Por quê |
|---|---|---|
| 1 | Worker com 0 réplicas, CronJobs com `suspend: true` | Ninguém grava durante a cópia |
| 2 | Contagem de linhas de cada tabela | Comparar depois |
| 3 | `pg_dump -Fc` para `~/.config/k8s-lab/` (`600`) e `pg_restore -l` para conferir | Backup e conteúdo da migração |
| 4 | PV antigo do local-path com `Retain` | Plano de volta: o volume antigo não é apagado |
| 5 | Apagar o StatefulSet e recriar com o volume `dados-pd` (`pd-balanced`, 10 GiB) | O template de volume de um StatefulSet não pode ser alterado; com o mesmo nome, o novo reaproveitaria o PVC antigo |
| 6 | `pg_restore` e contagem de novo | **13 tabelas, contagens idênticas** |
| 7 | Playbook `11-job-radar.yml` | Volta tudo ao estado do Git |

Banco fora do ar das 03:37:48 às 03:38:24 (troca do volume + restore); worker parado ~1,5 min.

**Achado:** o playbook não tirou os CronJobs do `suspend`. O `kubectl apply` só corrige campos que o manifesto **declara**, e o `cronjobs.yaml` não declarava `suspend`. Agora declara `suspend: false`: uma suspensão manual é desfeita pelo próximo apply.

### Volta (se precisar)

O PVC `dados-postgres-0` (local-path, `worker-1`) continua lá, com `Retain`. Para voltar: reverter o `postgres.yaml` no Git, apagar o StatefulSet e rodar o playbook (o volume `dados` volta a ser usado). Depois de alguns dias estável, apagar o PVC antigo e a pasta no `worker-1`.

## Drain do `worker-1`, de novo

[`14-drain-worker-1-depois.txt`](evidencias/semana-4/saidas/14-drain-worker-1-depois.txt)

```
Warning  FailedAttachVolume      Waiting for detach ... Volume is already exclusively attached   ← ainda no worker-1
Normal   Scheduled               Successfully assigned job-radar/postgres-0 to worker-2
Normal   SuccessfulAttachVolume  AttachVolume.Attach succeeded
```

| | local-path | pd-balanced |
|---|---|---|
| Para onde vai o Postgres | Fica `Pending` | **`worker-2`** |
| Volta depende do nó? | Sim: só depois do `uncordon` | **Não** |
| `503` no teste | 77 s (60 s escolhidos pelo teste; numa manutenção real, o tempo do nó fora) | **36 s** (desanexar + anexar + Postgres subir) |

Os 36 s que sobram são de ter **uma** instância do banco: zerar exigiria Postgres replicado (ex.: CloudNativePG com 2 instâncias), fora do escopo do lab.
