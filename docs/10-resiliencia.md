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
- **CoreDNS:** as 2 réplicas estavam no `worker-2` e não havia PDB, então o drain tirou as duas juntas. Não houve efeito visível (uma nova subiu em segundos), mas é um risco real de DNS fora do ar. **Corrigido:** `cluster/coredns/pdb.yaml` (`minAvailable: 1`), aplicado pelo `08-plataforma.yml`. A anti-afinidade do kubeadm continua só "preferida"; o PDB é que garante que o drain espere uma réplica nova antes de tirar a segunda.

### A, de novo, depois das correções

Drain do `worker-2` repetido com `preStop` (API e Traefik) e PDB do CoreDNS, sonda a cada ~0,2 s: **216 de 216 respostas `200`** (antes: um `502`). Evidência: [`10-drain-worker-2-depois.txt`](evidencias/semana-4/saidas/10-drain-worker-2-depois.txt).

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

---

# Rollout e rollback de versão

Atualização do Job Radar de `ddd3b92` para `eb22792` (preset da NVIDIA corrigido), em 24/10/2026, com a mesma sonda pública.

## Rollout pelo Git (o caminho normal)

```bash
# apps/job-radar/kustomization.yaml: newTag ddd3b92... → eb22792...
cd ansible && ansible-playbook playbooks/11-job-radar.yml
```

| Etapa | Resultado |
|---|---|
| Duração total do playbook | **38 s** (manifestos → migração com a imagem nova → espera API e worker) |
| API | `RollingUpdate`: com 2 réplicas, `maxSurge` 1 e `maxUnavailable` 0 → sempre 2 prontas |
| Worker | `Recreate` (D16): o antigo para antes de o novo subir, nunca 2 fazendo polling do Telegram |
| CronJobs | Imagem nova a partir da próxima execução |
| Conferência | `presets.py` dentro do pod novo: `nvidia/nemotron-3.5-lightning-30b-a3b` |

## Rollback de emergência: `kubectl rollout undo`

```bash
kubectl -n job-radar rollout undo deploy/api
kubectl -n job-radar rollout undo deploy/worker
```

Volta para a versão anterior em **27 s**, sem esperar CI nem Git. Mas mostrou duas armadilhas:

1. **Só vale para Deployments.** Os CronJobs **continuaram na versão nova**: coleta numa versão, API e worker em outra.
2. **Drift:** o cluster passa a divergir do Git (o próprio kubectl avisa que a anotação `last-applied-configuration` ficou desatualizada). O próximo `apply` desfaz o rollback sem aviso.

Por isso o `undo` é só para estancar um problema. **O rollback de verdade é no Git**: `git revert` do commit que trocou o `newTag` e rodar o playbook de novo. Aqui, como a versão desejada era a nova, reaplicar o Git (28 s) devolveu tudo à `eb22792`, de forma coerente.

## O que a sonda mostrou: o `502` da troca de pods

Em 3 trocas de versão, **3 respostas `502`** e **2 sem resposta** em 121 requisições. No log do Traefik:

```
"GET /readyz HTTP/1.1" 502 ... "http://10.244.2.96:8000"   ← IP da réplica ANTIGA, já encerrando
```

É uma corrida conhecida do Kubernetes: ao encerrar um pod, o `SIGTERM` para o processo e a remoção do pod da lista de endpoints acontecem **em paralelo**. Por alguns instantes, o Traefik ainda manda requisições para um pod que já está parando. É a mesma causa do `502` no drain do `worker-2`.

## Correção: `preStop` (antes e depois)

Na API (`apps/job-radar/api.yaml`) e no Traefik (`cluster/traefik/values.yaml`):

```yaml
lifecycle:
  preStop:
    sleep: {seconds: 5}   # ação nativa do Kubernetes: não precisa de `sleep` na imagem
```

```
sem preStop:  SIGTERM → app para na hora ─┐
              remoção da lista do Traefik ─┴→ corrida: requisição num pod parado → 502
com preStop:  espera 5 s (app ainda atende) → já saiu da lista → SIGTERM → app para
```

O cloudflared não precisa: não fica atrás de um Service; no SIGTERM ele mesmo avisa a Cloudflare e para de receber conexões.

Para provar, não basta aplicar: o primeiro rollout encerra os pods **antigos** (sem `preStop`). O teste é recriar de novo os pods que já têm a espera:

| | Trocas de pods | Requisições | Erros |
|---|---|---|---|
| **Antes** (rollout + undo + reaplicar) | 3 rollouts | 121 (1/s) | **3 × `502`, 2 sem resposta** |
| **Depois** (3 rodadas de `rollout restart` da API e do Traefik) | 6 rollouts, 12 pods encerrados | 378 (5/s) | **0** |

Custo: cada pod leva 5 s a mais para encerrar (rollouts e drains um pouco mais lentos).

---

# Kill de pods

`kubectl delete pod` em cada componente do Job Radar, com a sonda a cada ~0,2 s (24/10/2026). Evidência: [`09-kill-de-pods.txt`](evidencias/semana-4/saidas/09-kill-de-pods.txt).

| Pod | Como | Recuperação | Efeito público |
|---|---|---|---|
| Réplica da API | `delete` normal (passa pelo `preStop`) | Nova pronta em ~12 s | **Nenhum** |
| Réplica da API | `delete --grace-period=0 --force` (queda abrupta) | Nova pronta em ~12 s | **Nenhum**: a outra réplica atende |
| `postgres-0` | `delete` | Volta **no mesmo nó** (volume local-path) em ~13 s | **`503` por ~10 s** (03:09:06 → 03:09:16) |
| Worker | `delete` | Novo com polling ativo em ~3 s | Nenhum (não atende HTTP) |

## Achado: o `Recreate` não vale quando o pod é apagado

A estratégia `Recreate` do worker (D16: nunca 2 fazendo polling do Telegram ao mesmo tempo) só é respeitada em **rollouts**. Num `kubectl delete pod`, numa eviction ou numa queda de nó, o ReplicaSet cria o substituto **na hora**, sem esperar o antigo terminar:

```
worker-544fcdd959-fhsbv   1/1   Terminating   ← antigo: termina o long polling (até ~25 s)
worker-544fcdd959-zl7h5   1/1   Running       ← novo: já fazendo polling
```

Nessa janela existem 2 workers: dois pollings do mesmo bot (o Telegram responde `409 Conflict` a um deles) e dois schedulers (auditoria/notificação podem rodar em dobro). Desta vez não houve efeito visível, mas a garantia do D16 **não é dada pelo Kubernetes**.

Correção certa (no Job Radar, não no cluster): **trava no Postgres** (`pg_try_advisory_lock`) para o worker só começar a agendar e fazer polling quando for o único dono da trava. É o mesmo padrão de *leader election* que os controladores do Kubernetes usam.
