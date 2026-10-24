# 13 — GitOps com Argo CD

Até aqui, publicar uma versão era: editar o `newTag`, rodar o playbook e torcer para ninguém ter mudado algo à mão no cluster. Com o **Argo CD**, o Git passa a ser a única fonte da verdade: um controlador dentro do cluster compara o que está no Git com o que está rodando e corrige a diferença sozinho.

```
git push (k8s-lab, main) ──► Argo CD (cp-1) lê o Git a cada 3 min
                                │ diferença?
                                ▼
                     aplica no cluster, na ordem das ondas
                     e desfaz mudança manual (self-heal)
```

## As peças

| Peça | Onde | Para quê |
|---|---|---|
| Argo CD (chart 10.11.1, v3.5.6) | `cluster/argocd/values.yaml` | Tudo no `cp-1`; sem SSO, sem notificações, sem ApplicationSet |
| Playbook | `ansible/playbooks/13-argocd.yml` | Instala o chart e aplica **só** a Application raiz; no `site.yml` no lugar do antigo `11-job-radar.yml` |
| Application raiz | `argocd/raiz.yaml` | **App-of-apps**: lê `argocd/apps/` e cria uma Application por arquivo |
| Apps | `argocd/apps/job-radar.yaml`, `argocd/apps/teste.yaml` | Job Radar (`apps/job-radar`) e o whoami (`cluster/teste`) |

Publicar um app novo = um arquivo em `argocd/apps/` + `git push`. O repositório é público: o Argo CD lê sem credencial.

O que **não** está no Argo CD (fica no Ansible): Cilium, Traefik, Sealed Secrets, local-path, PD CSI, cloudflared, monitoramento e o próprio Argo CD. São a base de que ele depende; colocá-los sob o Argo CD é uma evolução possível.

## Política de sincronização

| Opção | Efeito |
|---|---|
| `automated` | Mudou no Git, aplica sem clique |
| `prune: true` | O que sai do Git sai do cluster |
| `selfHeal: true` | Mudança feita à mão no cluster é desfeita |
| `ServerSideApply` | Aplica pelo servidor da API (melhor com campos preenchidos por outros controladores) |
| `ServerSideDiff` (anotação) | Compara pelo servidor da API, que conhece os valores padrão |

A Application **não** tem o finalizer de cascata: apagar a Application (ou o arquivo dela) **não apaga** o Job Radar e o banco. Proteção contra um engano no Git.

### Consequência para manutenção manual

Com `selfHeal`, um `kubectl scale`, `kubectl patch` ou `suspend` manual é desfeito em segundos. Para uma manutenção como a migração do Postgres ([11-discos-gerenciados.md](11-discos-gerenciados.md)), primeiro desligar o automático:

```bash
kubectl -n argocd patch application job-radar --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
# ... manutenção ...
kubectl -n argocd patch application job-radar --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

Como a raiz também tem `selfHeal`, ela restaura a Application ao estado do Git em até 3 min; para manutenções longas, suspender a raiz da mesma forma.

## Ordem: ondas e o hook de migração

O Argo CD aplica por **ondas** (`argocd.argoproj.io/sync-wave`) e espera cada uma ficar saudável antes da próxima:

| Onda | Recursos | Por quê |
|---|---|---|
| -1 | Namespace, SealedSecret, ConfigMap, NetworkPolicy, Postgres | Base: o banco precisa estar pronto |
| 0 | Job `migrar` (**hook** de `Sync`) | Migrations + seed com a imagem nova, antes do app |
| 1 | API, worker, CronJobs, backup | Só sobem com o banco migrado |

O Job de migração antes era aplicado pelo playbook 11 com um `sed` trocando `IMAGEM` pela tag. Agora ele está no kustomization: o `newTag` vale para ele também, e o hook (`hook-delete-policy: BeforeHookCreation`) recria o Job a cada sincronização completa. Self-heal e ajustes pontuais **não** rodam hooks.

## Primeira sincronização (24/10/2026)

Evidência: [`16-argocd.txt`](evidencias/semana-4/saidas/16-argocd.txt).

| | |
|---|---|
| Playbook `13-argocd.yml` | 71 s (chart + Application raiz) |
| Adoção dos recursos existentes | O Argo CD assumiu o que o Ansible tinha criado, sem recriar pods |
| Self-heal (`kubectl scale deploy/api --replicas=1`) | **De volta a 2 réplicas em 1,2 s** |
| Sync completo forçado | Hook `migrar` na onda 0, 10 s, depois o sync termina |

### Problema: `OutOfSync` para sempre

Depois do primeiro sync, o `StatefulSet` do Postgres e o `HTTPRoute` ficaram `OutOfSync`, apesar de iguais ao Git. Causa: o Kubernetes preenche valores padrão (`volumeMode: Filesystem` nos templates de volume, `group`/`kind` nos `parentRefs`) e a comparação do lado do Argo CD vê isso como diferença. Correção: `argocd.argoproj.io/compare-options: ServerSideDiff=true` na Application, que faz a comparação pelo servidor da API (com os padrões aplicados).

## Deploy ponta a ponta: do merge ao cluster

O CI do Job Radar fecha o ciclo ([`docs/CI-CD.md`](https://github.com/paulocerqr/job-radar/blob/main/docs/CI-CD.md), job `atualizar-lab`): depois de publicar a imagem, faz checkout deste repositório com uma **deploy key** (escrita só aqui), troca o `newTag` e faz commit como `github-actions[bot]`. Ninguém acessa o cluster para fazer deploy.

Primeira execução (24/10/2026, PR #14 do Job Radar), com a sonda pública a cada 0,5 s ([`17-gitops-ponta-a-ponta.txt`](evidencias/semana-4/saidas/17-gitops-ponta-a-ponta.txt)):

| Hora | Etapa | Duração |
|---|---|---|
| 18:59:34 | Merge do PR na `main` do Job Radar | — |
| 19:00:20 | Testes | 40 s |
| 19:00:54 | Imagem `696b7be` no GHCR | 32 s |
| 19:00:59 | Commit `ci: job-radar → 696b7be` no k8s-lab (`github-actions[bot]`) | 6 s |
| 19:04:46 | Argo CD detecta e inicia o sync; hook `migrar` (10 s) | **3 min 47 s de espera** |
| 19:05:22 | Rollout de API e worker concluído | 36 s |

**Total: ~6 min do merge à versão nova no ar, com 478 de 478 respostas `200`.**

A maior parte é o Argo CD esperando o próximo ciclo de leitura do Git (`timeout.reconciliation: 180s` + até 60 s de variação). Para ser imediato, o GitHub avisaria o Argo CD por **webhook**; isso exige expor o endpoint do Argo CD na internet (hoje só port-forward), então fica como evolução, com Cloudflare Access na frente.

## Acessando a interface

Sem exposição pública, por port-forward:

```bash
export KUBECONFIG=~/.kube/k8s-lab.conf
kubectl -n argocd port-forward svc/argocd-server 8080:80
# http://localhost:8080 — usuário admin; senha inicial:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## Conferindo

```bash
kubectl -n argocd get applications
# forçar a leitura do Git agora (sem esperar 3 min)
kubectl -n argocd annotate application raiz argocd.argoproj.io/refresh=hard --overwrite
```
