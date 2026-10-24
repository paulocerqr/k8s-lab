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
| [`saidas/08-prestop-rollouts.txt`](saidas/08-prestop-rollouts.txt) | Depois do `preStop`: 6 rollouts, 378 requisições, 0 erros |
| [`saidas/09-kill-de-pods.txt`](saidas/09-kill-de-pods.txt) | Kill de API (normal e forçado), Postgres e worker; 2 workers ao mesmo tempo |
| [`saidas/10-drain-worker-2-depois.txt`](saidas/10-drain-worker-2-depois.txt) | Drain do `worker-2` repetido após `preStop` e PDB do CoreDNS: 216 de 216 `200` |
| [`saidas/11-trava-do-worker.txt`](saidas/11-trava-do-worker.txt) | Com a trava no Postgres: o worker novo espera o antigo soltar antes de trabalhar |
| [`saidas/12-pd-teste-troca-de-no.txt`](saidas/12-pd-teste-troca-de-no.txt) | Disco do PD CSI criado (21 s) e levado do `worker-1` ao `worker-2` (20 s) com os dados |
| [`saidas/13-migracao-postgres.txt`](saidas/13-migracao-postgres.txt) | Migração do Postgres para o `pd-balanced`: dump, troca do volume, restore, contagens iguais |
| [`saidas/14-drain-worker-1-depois.txt`](saidas/14-drain-worker-1-depois.txt) | Drain do `worker-1` com o PD CSI: Postgres vai para o `worker-2`, `503` por 36 s |
| [`saidas/15-backup-postgres.txt`](saidas/15-backup-postgres.txt) | Backup manual para o GCS, restauração num banco temporário e 403 ao tentar apagar/sobrescrever/ler de dentro do cluster |
