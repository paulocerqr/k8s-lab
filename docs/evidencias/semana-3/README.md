# Evidências — semana 3: Job Radar no cluster

Saídas reais capturadas em 21/10/2026, com o Job Radar rodando no lab (imagem `ddd3b92`). Dados sensíveis conferidos: nenhum token, chave, e-mail ou IP da tailnet.

| Arquivo | Mostra |
|---|---|
| [`saidas/01-job-radar-pods.txt`](saidas/01-job-radar-pods.txt) | Postgres, 2 réplicas da API (uma por worker), worker único, Job de migração concluído, CronJobs no fuso de Brasília |
| [`saidas/02-api-publica.txt`](saidas/02-api-publica.txt) | `https://jobradar-lab.utileasy.com.br/healthz` e `/readyz` respondendo pela internet (Cloudflare Tunnel → Traefik → API) |
| [`saidas/03-coleta.txt`](saidas/03-coleta.txt) | Primeira coleta pelos CronJobs: Gupy 92 vagas, GitHub 30 vagas |
| [`saidas/04-auditoria-e-telegram.txt`](saidas/04-auditoria-e-telegram.txt) | Auditoria com o Groq (5,6 s por lote de até 5 vagas) e as recomendadas enviadas ao Telegram às 18:59 |

## Fluxo demonstrado

```
CronJob coletar-gupy / coletar-github ─► pool ─► alimentador (10 min) ─► fila
    ─► auditor (1 min, Groq) ─► recomendada ─► notificação (1 min) ─► Telegram
```

Tudo dentro do cluster: o worker do PC de administração ficou parado (só um processo pode fazer polling do bot do Telegram).
