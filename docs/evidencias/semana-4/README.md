# Evidências — semana 4: resiliência (drain, rollout e rollback)

Saídas reais de 24/10/2026. Explicação e conclusões: [10-resiliencia.md](../../10-resiliencia.md).

| Arquivo | Mostra |
|---|---|
| [`saidas/01-drain-worker-2.txt`](saidas/01-drain-worker-2.txt) | Drain do `worker-2` (8 s), pods recriados no `worker-1`, `uncordon` e redistribuição |
| [`saidas/02-sonda-drain-worker-2.txt`](saidas/02-sonda-drain-worker-2.txt) | Sonda pública: um único `502`, resto `200` |
| [`saidas/03-drain-worker-1.txt`](saidas/03-drain-worker-1.txt) | Drain do `worker-1`: Postgres `Pending` (volume preso ao nó), `uncordon`, recuperação e worker voltando a executar |
| [`saidas/04-sonda-drain-worker-1.txt`](saidas/04-sonda-drain-worker-1.txt) | Sonda pública: `503` de 02:38:26 a 02:39:43 (77 s) |
| [`saidas/05-rollout-eb22792.txt`](saidas/05-rollout-eb22792.txt) | Troca do `newTag` e playbook: rollout em 38 s, imagens antes e depois |
| [`saidas/06-rollback.txt`](saidas/06-rollback.txt) | `rollout undo` (27 s, CronJobs ficam na versão nova) e reaplicação do Git |
| [`saidas/07-sonda-rollout-rollback.txt`](saidas/07-sonda-rollout-rollback.txt) | Sonda pública nas 3 trocas de versão |
