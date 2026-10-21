# 08 — Observabilidade: Prometheus, Alertmanager e Grafana

O lab tem **duas camadas** de observabilidade (K09):

| Camada | Ferramenta | O que vê |
|---|---|---|
| Hosts | **Beszel** (projeto `beszel-infra`) | CPU, RAM, disco e rede das VMs, junto com os outros servidores |
| Cluster | **kube-prometheus-stack** (este documento) | Pods, nós, API server, CoreDNS, kubelet, uso por namespace/workload, alertas |

## As peças

| Componente | Função | Onde roda |
|---|---|---|
| **Prometheus** | Coleta métricas de tempos em tempos ("scrape") e guarda como séries temporais | `cp-1`, volume de 10 GB (local-path), 7 dias de retenção |
| **Alertmanager** | Recebe os alertas do Prometheus e decide para onde mandar | `cp-1` |
| **Grafana** | Painéis em cima dos dados do Prometheus | `cp-1` |
| **Prometheus Operator** | Transforma objetos `ServiceMonitor`/`PodMonitor` em configuração de coleta | `cp-1` |
| **kube-state-metrics** | Expõe o **estado** dos objetos (réplicas desejadas × prontas, pods reiniciando...) | `cp-1` |
| **node-exporter** | Expõe métricas de cada **nó** (CPU, memória, disco, rede) | todos os nós (DaemonSet) |

Tudo (menos o node-exporter) fica no `cp-1` com *toleration* para o taint de control plane (K10): o control plane usa ~2 GB dos 16 GB, e os workers ficam livres para as aplicações.

## Arquivos

| Arquivo | Conteúdo |
|---|---|
| `cluster/monitoring/values.yaml` | Configuração do chart 92.1.0 (comentada) |
| `cluster/monitoring/grafana-admin-sealedsecret.yaml` | Usuário e senha do Grafana, cifrados |
| `ansible/playbooks/10-monitoramento.yml` | Namespace, segredo e chart; só reinstala se versão ou valores mudarem |

A senha do Grafana foi gerada aleatoriamente (32 caracteres) e fica **só** em `~/.config/k8s-lab/grafana-admin-senha` (permissão `600`). No Git, só a versão cifrada.

## O que é coletado

Estado em 21/10/2026: **23 alvos, todos `up`**.

| Job | Alvos | Origem |
|---|---|---|
| `apiserver` | 1 | API do Kubernetes |
| `kubelet` | 9 | 3 por nó: kubelet, cAdvisor (containers) e probes |
| `node-exporter` | 3 | um por nó |
| `coredns` | 2 | DNS do cluster |
| `kube-state-metrics` | 1 | estado dos objetos |
| `kps-*` | 6 | o próprio Prometheus, Alertmanager, Grafana e operator |

**Desligados de propósito:** `kube-controller-manager`, `kube-scheduler` e `etcd` (o kubeadm expõe as métricas deles só em `127.0.0.1`; o Prometheus não alcança e ficaria alertando `TargetDown` para sempre) e `kube-proxy` (não existe: K24). Expor os três primeiros exige mudar os manifests do control plane — evolução registrada no plano.

O único alerta disparando é o **`Watchdog`**: ele dispara sempre, de propósito, para provar que a cadeia Prometheus → Alertmanager está viva.

## Acessando o Grafana

Por enquanto só pela API do Kubernetes (nada exposto):

```bash
export KUBECONFIG=~/.kube/k8s-lab.conf
kubectl -n monitoring port-forward svc/kps-grafana 3000:80
# abrir http://localhost:3000 — usuário: admin, senha: ~/.config/k8s-lab/grafana-admin-senha
```

Painéis úteis para começar (25 vêm prontos):

| Painel | Mostra |
|---|---|
| *Kubernetes / Compute Resources / Cluster* | Uso de CPU/memória do cluster inteiro, por namespace |
| *Kubernetes / Compute Resources / Namespace (Pods)* | Uso por pod, comparado com `requests`/`limits` |
| *Node Exporter / Nodes* | CPU, memória, disco e rede de cada VM |
| *Kubernetes / API server* | Latência e erros da API |
| *CoreDNS* | Consultas e erros de DNS |

## Conferindo

```bash
kubectl -n monitoring get pods -o wide
# alvos e alertas, pela API do Kubernetes (a imagem do Prometheus não tem curl/wget)
P=/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy/api/v1
kubectl get --raw "$P/targets?state=active" | jq '.data.activeTargets[] | {job: .labels.job, health}'
kubectl get --raw "$P/alerts" | jq '.data.alerts[] | select(.state=="firing") | .labels.alertname'
```
