# 09 — Job Radar no cluster

O [Job Radar](https://github.com/paulocerqr/job-radar) roda no lab com a mesma imagem publicada pelo CI, configurado 100% por variáveis de ambiente (plano §5.3).

## Como fica no cluster

```
                  CronJobs (08-20h, Brasília)
                  coletar-gupy (1/h) · coletar-github · coletar-solides (2/2h)
                              │ grava vagas
                              ▼
https://jobradar-lab ──► Traefik ──► api (2 réplicas: Web UI + API JSON) ──► Postgres (StatefulSet, 10 GB pd-balanced)
                                                             ▲
            Telegram ◄── worker (1 réplica, Recreate) ───────┘
                         alimenta a fila, audita com IA (Groq → NVIDIA → Gemini),
                         notifica e recebe os botões (polling)
```

| Recurso | Tipo | Detalhes |
|---|---|---|
| `postgres` | StatefulSet + Service | `postgres:16-alpine`, disco gerenciado de 10 GB que muda de nó ([11](11-discos-gerenciados.md)); só aceita conexões do próprio Job Radar (NetworkPolicy); backup diário no GCS ([12](12-backup.md)) |
| `migrar` | Job (hook do Argo CD) | `job-radar migrar` (init) + `job-radar seed`; recriado a cada sincronização, depois do Postgres e antes de API/worker |
| `api` | Deployment (2) + Service + PDB + HTTPRoute | Web UI na raiz e API JSON em `/api` ([Web UI](#web-ui)); `/healthz` (liveness) e `/readyz` (readiness: banco acessível); `jobradar-lab.utileasy.com.br` |
| `worker` | Deployment (1, `Recreate`) | Scheduler + polling do Telegram: nunca 2 ao mesmo tempo (D16); liveness pelo heartbeat |
| `coletar-gupy`, `coletar-github`, `coletar-solides` | CronJob | `timeZone: America/Sao_Paulo`, `concurrencyPolicy: Forbid`, `COLETA_NO_WORKER=false` |

Todos os pods: sem root, sem privilégios, sistema de arquivos somente leitura (só `/tmp` gravável).

## Arquivos

| Arquivo | Conteúdo |
|---|---|
| `apps/job-radar/kustomization.yaml` | Lista os recursos e fixa **a versão da imagem num único lugar** (`newTag` = commit da `main`) |
| `apps/job-radar/sealedsecret.yaml` | `DATABASE_URL`, senha do Postgres, `FERNET_KEY`, admin, token do bot e chaves de IA, cifrados |
| `apps/job-radar/configmap.yaml` | Configuração não sensível (fuso, logs, coleta por CronJob, cookie da sessão só por HTTPS) |
| `apps/job-radar/migrar-job.yaml` | Job de migração, hook do Argo CD na onda 0 |
| `argocd/apps/job-radar.yaml` | Application do Argo CD: aplica esta pasta e mantém o cluster igual ao Git ([13-argocd.md](13-argocd.md)) |

Segredos: a `FERNET_KEY`, a senha do Postgres e a do admin são **próprias do lab** (K13); token do bot e chaves de IA são os mesmos do ambiente local. Cópia em texto puro só em `~/.config/k8s-lab/job-radar.env` (`600`).

## Atualizar para uma versão nova

1. CI do `job-radar` publica `ghcr.io/paulocerqr/job-radar:<sha>`.
2. Trocar o `newTag` no `apps/job-radar/kustomization.yaml`.
3. Commit e push. O Argo CD percebe a mudança (até 3 min), roda a migração com a imagem nova e faz o rollout de API, worker e CronJobs. Até 24/10/2026 isso era o playbook `11-job-radar.yml`, removido com a chegada do Argo CD.

## Preparação dos dados (uma vez, depois do primeiro deploy)

O banco do lab nasce vazio. A partir de um pod da API, que já tem as chaves no ambiente:

```bash
export KUBECONFIG=~/.kube/k8s-lab.conf
P=$(kubectl -n job-radar get pods -l app=api -o name | head -1)
jr() { kubectl -n job-radar exec $P -- job-radar "$@"; }

# providers de IA (o Codex CLI não roda em container: D18)
jr provider adicionar groq   --preset groq   --api-key-env GROQ_API_KEY
jr provider adicionar nvidia --preset nvidia --api-key-env NVIDIA_API_KEY
jr provider adicionar gemini --preset gemini --api-key-env GEMINI_API_KEY
jr provider testar groq

# currículo (fica fora dos repositórios, em ~/.config/job-radar/)
kubectl -n job-radar cp ~/.config/job-radar/curriculo.md ${P#pod/}:/tmp/curriculo.md
jr perfil curriculo /tmp/curriculo.md && kubectl -n job-radar exec $P -- rm /tmp/curriculo.md

# Telegram: gera o link de vínculo (uso único) para o chat
jr telegram vincular
```

> O bot do Telegram é o mesmo do ambiente local. **Só um processo pode fazer polling por bot**: com o worker do cluster ligado, o `job-radar worker` do PC fica parado.

## Problemas encontrados no primeiro deploy

| Problema | Sintoma | Correção |
|---|---|---|
| Variáveis automáticas dos Services | Tudo em `CrashLoopBackOff` com `ValidationError: api_port ... 'tcp://10.107.181.231:80'`: o Service `api` gera `API_PORT=tcp://...`, que colide com a configuração `API_PORT` do app | `enableServiceLinks: false` em todos os pods (os Services são achados pelo DNS) |
| Espalhamento contando o `cp-1` | Pod novo da API `Pending` na atualização: a regra queria uma réplica no `cp-1`, que tem taint | `nodeTaintsPolicy: Honor` (também no Traefik e no cloudflared, onde estava latente) |
| Espalhamento contando pods antigos | Após atualizar, as 2 réplicas do cloudflared ficaram no mesmo nó | `matchLabelKeys: [pod-template-hash]`: cada versão é espalhada por si só |
| Modelo da NVIDIA | `404 Function ... Not found`: o `nemotron-3-super-120b` aparece na lista de modelos mas não atende mais | Trocado para `nvidia/nemotron-3.5-lightning-30b-a3b` (testado: 1,2 s) |

## Web UI

Desde 25/10/2026 o Job Radar tem interface web, no mesmo endereço: login, Visão geral, Vagas (com o parecer da IA e os botões confirmar/ignorar, os mesmos do Telegram), Meu perfil, Providers de IA e Fontes e coleta.

| Decisão | Por quê |
|---|---|
| Next.js com **exportação estática**, servida pela própria API | Nenhum Deployment novo: o Node só existe num estágio do Dockerfile, e a imagem cresceu 720 KB. A mesma imagem, a mesma `newTag` e o mesmo GitOps |
| Mesma origem (UI e `/api` no mesmo domínio) | Sem CORS; a sessão é um cookie `HttpOnly`, `Secure`, `SameSite=Lax` |
| Chave da sessão derivada da `FERNET_KEY` | Nenhum segredo novo no SealedSecret; as 2 réplicas da API validam o mesmo cookie |
| `SESSAO_COOKIE_SEGURO: "true"` no ConfigMap | O cookie só trafega por HTTPS (a Cloudflare termina o TLS) |
| "Coletar agora" roda na API, em segundo plano | Mesmo código dos CronJobs; uma coleta da mesma fonte em andamento bloqueia outra. Fonte desativada na UI faz o CronJob sair sem coletar |

### Exposição pública

A tela de login fica aberta na internet (pelo Cloudflare Tunnel, sem porta aberta no cluster). Proteções:

- senha com argon2 e bloqueio de 5 minutos após 5 falhas (por IP e por e-mail);
- toda escrita exige corpo JSON **e** o cabeçalho `X-CSRF-Token` da sessão: um formulário de outro site não consegue mandar nenhum dos dois;
- **CSP com hash dos scripts**: o Next coloca scripts inline no HTML; em vez de liberar `'unsafe-inline'`, a API calcula na inicialização o SHA-256 de cada um e só esses rodam. As respostas da API têm `default-src 'none'`;
- chaves dos providers nunca vão ao navegador (só os 4 últimos caracteres); cadastro e troca de chave seguem pelo CLI.

Evolução possível: Cloudflare Access na frente (login da Cloudflare antes de chegar ao cluster).

### Problema: redirect para `http://` atrás do túnel

`/login` (sem barra) redirecionava para **`http://`**`jobradar-lab.../login/`. O tráfego chega ao pod como HTTP (Cloudflare → túnel → Traefik → pod) e o servidor de arquivos estáticos montava a URL absoluta com esse esquema. Correção no app: redirect só com o caminho (`Location: /login/`), e o navegador mantém o `https`. Lição: atrás de proxy, URL absoluta gerada pelo app é suspeita; caminho relativo não depende de cabeçalhos `X-Forwarded-*`.

## Conferindo

```bash
kubectl -n job-radar get pods -o wide
kubectl -n job-radar get cronjobs
kubectl -n job-radar logs deploy/worker | grep -E "auditoria|notifica|polling"
# coleta manual, fora do horário
kubectl -n job-radar create job --from=cronjob/coletar-gupy coletar-gupy-manual   # ou "Coletar agora" na Web UI
# Web UI: sem sessão, a API responde 401 e a raiz carrega a tela de login
curl -s -o /dev/null -w '%{http_code}\n' https://jobradar-lab.utileasy.com.br/api/vagas   # 401
curl -sI https://jobradar-lab.utileasy.com.br/login | grep -i location                     # /login/ (sem esquema)
```

Primeira coleta (21/10/2026): Gupy 92 vagas (4 no pool), GitHub 30 vagas (14 no pool).

Evidências (coleta, auditoria e notificações): [`evidencias/semana-3`](evidencias/semana-3/README.md).
