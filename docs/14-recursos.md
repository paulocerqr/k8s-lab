# 14 — Requests e limites pelo uso medido

Os `requests`/`limits` do Job Radar foram chutados no primeiro deploy. Depois de 4 dias rodando, os números vieram do Prometheus (24/10/2026).

## Conceitos

| | Para que serve | Se errar para cima | Se errar para baixo |
|---|---|---|---|
| **request** | Reserva usada pelo scheduler para escolher o nó | Desperdiça capacidade: o nó "enche" sem estar usado | O nó fica sobrecarregado de verdade |
| **limit de memória** | Teto: passou, o processo é morto (OOMKilled) | Pouco risco | Pod morto em pico normal |
| **limit de CPU** | Teto de CPU (throttling) | — | Lentidão em pico. **Não usado** aqui: CPU sobrando no nó é melhor aproveitada sem teto |

Pod **sem request** é *BestEffort*: o primeiro a ser despejado quando o nó fica sem memória.

## Como foi medido

Pelo Prometheus, via API do Kubernetes (sem expor nada), nos 4 dias de histórico:

```promql
max by (namespace,container)(max_over_time(container_memory_working_set_bytes{...}[4d]))                     # memória máxima
max by (namespace,container)(quantile_over_time(0.95, rate(container_cpu_usage_seconds_total{...}[5m])[4d:1m]))  # CPU p95
```

Tabela completa (com Argo CD e PD CSI) em [`18-recursos.txt`](evidencias/semana-4/saidas/18-recursos.txt).

## Achado: a liveness do worker "vazava" ~115 Mi por dia

A memória do worker crescia sem parar: **135 Mi → 380 Mi em 2,5 dias**, a 4 Mi do limite (384 Mi). Parecia vazamento do Python, mas:

| Pod `worker-695f55bc-nxtrh` | Máximo |
|---|---|
| `working_set` (o que o Kubernetes olha) | 380 Mi |
| `rss` (memória do processo Python) | **136 Mi** |
| cache de arquivos | 4 Mi |

Os ~240 Mi que sobravam eram **memória do kernel** contada no cgroup do container (`slab_reclaimable`). Suspeito: a liveness era `exec: job-radar worker-saude`, que a cada 60 s **sobe um Python novo** dentro do container. Na inicialização, o Python procura centenas de arquivos que não existem (caminhos de import); o kernel guarda cada "não existe" em cache (*dentries negativas*), cobrado do container.

Teste dentro do pod, 100 execuções de cada (equivale a 100 min de probes):

| Liveness | `slab_reclaimable` | `anon` (Python) | Tempo |
|---|---|---|---|
| `job-radar worker-saude` (Python) | **+8 Mi** | +0,1 Mi | 225 s (~2,2 s de CPU cada) |
| `test` em shell com `stat` + `date` | **0** | 0 | 3 s |

8 Mi por 100 execuções × 1.440 probes/dia ≈ **115 Mi/dia**, igual ao crescimento observado. E cada probe gastava ~2,2 s de CPU por minuto, inflando também a CPU medida do worker.

Correção em `apps/job-radar/worker.yaml` (mesma regra: heartbeat com até 120 s):

```yaml
livenessProbe:
  exec:
    command: [sh, -c, 'test $(( $(date +%s) - $(stat -c %Y "$WORKER_HEARTBEAT_PATH" 2>/dev/null || echo 0) )) -le 120']
```

Essa memória é "recuperável": o kernel a liberaria perto do limite, então talvez nunca houvesse OOM. Mas ela distorce o `working_set`, que é a métrica usada para despejo por falta de memória no nó **e** para dimensionar — exatamente o que este documento faz. O `worker-saude` continua no Job Radar para o healthcheck do docker-compose.

## O que mudou

| Container | Uso medido | Antes (request → limite) | Depois |
|---|---|---|---|
| `api` | 108 Mi; CPU p95 21m | 100m/192Mi → 384Mi | **50m/128Mi → 256Mi** |
| `worker` | ~75 Mi típico, 136 Mi máx (RSS) | 100m/192Mi → 384Mi | **50m/128Mi → 256Mi** |
| `postgres` | 61 Mi; CPU p95 13m | 100m/256Mi → 512Mi | **50m/128Mi → 512Mi** (limite mantido: o cache do banco cresce com os dados) |
| `coletar-*` | Não medível: o job dura ~10 s e o Prometheus coleta a cada 30 s | 50m/128Mi → 256Mi | Mantido |
| Argo CD `application-controller` | **439 Mi**; CPU p95 64m | **nenhum** (BestEffort) | 100m/512Mi → 1Gi |
| Argo CD `repo-server` / `server` / `redis` | 41 / 51 / 10 Mi | nenhum | 25m/64Mi → 256Mi; 25m/64Mi → 256Mi; 10m/32Mi → 128Mi |
| Traefik, cloudflared | 35 Mi, 27 Mi | 50m/64Mi, 25m/32Mi | Mantidos |

Requests do Job Radar nos workers: de **300m de CPU / 832 Mi** (2 APIs + worker + Postgres) para **200m / 512 Mi**.

## Aplicação (pelo Argo CD)

Push no Git → Argo CD sincronizou em ~1 min. API e worker trocaram sem erro; o **Postgres reiniciou** (mudou o template do StatefulSet) e o Job Radar ficou com `503` por ~20 s — custo de ter uma única instância do banco ([11-discos-gerenciados.md](11-discos-gerenciados.md)).

## A conferir

- **24 h depois:** o `working_set` do worker deve ficar estável (antes: +4 Mi/h).
- **Em uma semana:** repetir as consultas; com mais histórico, rever os requests.
