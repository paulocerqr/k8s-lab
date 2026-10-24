# 10 — Resiliência: drain dos workers

Teste de manutenção de nó (`kubectl drain`): o que acontece com o Job Radar quando cada worker sai do ar de forma planejada. Feito em 24/10/2026, com uma sonda batendo em `https://jobradar-lab.utileasy.com.br/readyz` a cada ~1 s, **de fora do cluster** (pelo caminho real: Cloudflare → túnel → Traefik → API).

## O que é um drain

```bash
kubectl drain <nó> --ignore-daemonsets --delete-emptydir-data   # marca o nó como não agendável e despeja os pods
kubectl uncordon <nó>                                           # libera o nó de novo
```

O drain respeita os **PodDisruptionBudgets**: API, Traefik e cloudflared têm `minAvailable: 1`, então nunca saem as duas réplicas ao mesmo tempo. Os DaemonSets (Cilium, node-exporter) ficam no nó.

## Resultado

| Teste | Duração do drain | Disponibilidade pública | Leitura |
|---|---|---|---|
| **A. `worker-2`** | 8 s | 17 de 18 respostas `200`; **um `502`** | A API continua no ar: a réplica do `worker-1` atende enquanto a outra renasce lá |
| **B. `worker-1`** | 15 s | **`503` por 77 s** (02:38:26 → 02:39:43) | O Postgres fica `Pending` até o `uncordon`; o serviço volta **4 s** depois dele |

Evidências: [`evidencias/semana-4`](evidencias/semana-4/README.md).

### A. Drain do `worker-2`: sem indisponibilidade da API

- Todos os pods (API, Traefik, cloudflared, CoreDNS, whoami) foram recriados no `worker-1`/`cp-1` em segundos.
- O **único `502`** veio da troca do Traefik/cloudflared: uma requisição em andamento caiu na réplica que estava saindo. Para zerar isso: `preStop` com alguns segundos de espera e `terminationGracePeriodSeconds` maior no Traefik e no cloudflared (evolução).
- **CoreDNS:** as 2 réplicas estavam no `worker-2` e não há PDB, então o drain tirou as duas juntas. Não houve efeito visível (uma nova subiu em segundos), mas é um risco real de DNS fora do ar. Evolução: PDB e espalhamento para o CoreDNS.

### B. Drain do `worker-1`: a limitação do local-path (K06)

```
0/3 nodes are available: 1 node(s) didn't match PersistentVolume's node affinity,
1 node(s) had untolerated taint(s), 1 node(s) were unschedulable.
```

O volume do Postgres está **no disco do `worker-1`**: o `postgres-0` não pode ir para outro nó.

| Componente | Comportamento sem banco |
|---|---|
| API | Fica `Running` mas `0/1`: o `/readyz` falha, o Traefik não tem para onde mandar e responde **`503`** (correto: não serve erro do app) |
| Worker | **Não reiniciou**: os jobs agendados registram erro e tentam de novo no minuto seguinte; voltaram a executar com sucesso após o banco subir |
| CronJobs | Uma coleta que caísse nessa janela falharia e só rodaria no próximo horário |

Os 77 s foram quase todos escolha do teste (60 s esperando antes do `uncordon`). Numa manutenção real (reboot, troca de máquina), a indisponibilidade dura **o tempo que o nó ficar fora**.

## Depois do `uncordon`, o Kubernetes não redistribui sozinho

Ao liberar o nó, os pods continuam onde estão (após o teste A, tudo ficou no `worker-1`). Para voltar a ter uma réplica por nó:

```bash
kubectl -n traefik     rollout restart deploy/traefik
kubectl -n cloudflared rollout restart deploy/cloudflared
kubectl -n job-radar   rollout restart deploy/api
```

Sem isso, o drain seguinte derruba todas as réplicas de uma vez (respeitando o PDB, mas com mais pods se movendo). Alternativa automática: o **Descheduler** (evolução).

## Como evitar a indisponibilidade do teste B

| Opção | Custo |
|---|---|
| **GCE PD CSI**: disco gerenciado, que se desanexa do nó e anexa em outro | Instalar o driver e a conta de serviço; o Postgres renasce em outro nó em ~1 min |
| Postgres replicado (ex.: CloudNativePG, 2 instâncias) | Mais memória e complexidade |
| Banco gerenciado (Cloud SQL) | Custo mensal, sai do escopo do lab |

Para o lab, a limitação fica **aceita e medida**: manutenção no `worker-1` = Job Radar fora durante a janela.
