# Incidente 002 — Gateway API do Cilium falha para backends no mesmo nó

## Contexto e impacto

20–21/10/2026. Depois de trocar o kube-proxy pelo kube-proxy replacement do Cilium e ligar a Gateway API do Cilium (para substituir o ingress-nginx, aposentado), um app de teste com 2 réplicas (uma em cada worker) respondia de forma instável pelo Gateway: cerca de **metade das requisições ficava sem resposta**. A partir de pods — de onde o `cloudflared` falaria com o Gateway — nenhum teste inicial funcionou. Nenhuma aplicação real foi afetada (o Gateway ainda não estava publicado).

## Causa

**O Envoy do Cilium nunca consegue se conectar ao backend que está no mesmo nó que ele; com backends em outros nós, sempre consegue.** Contadores do Envoy (`cilium-dbg envoy admin clusters`):

| Envoy em | → pod no mesmo nó | → pod no outro nó |
|---|---|---|
| `worker-1` | `cx_connect_fail` 10/10 | `rq_success` 10 |
| `worker-2` | `cx_connect_fail` 4/4 | `rq_success` 6 |

Com 2 réplicas, o Envoy alterna entre elas: a requisição que cai no pod local espera o `upstream_cx_connect_timeout` (o cliente, com 5 s de limite, desiste antes e vê "sem resposta").

É um bug aberto do Cilium: [cilium/cilium#47940](https://github.com/cilium/cilium/issues/47940) — mesmos sintomas, reproduzido no v1.19.6 e v1.20.0, sem correção nem contorno. Reportamos a nossa reprodução (x86_64/GCE/kubeadm/Debian 13/Cilium 1.20.3, ambiente diferente do original) [na issue](https://github.com/cilium/cilium/issues/47940#issuecomment-6313460987).

## Correção

Gateway API do Cilium desligada; **Traefik** como implementação da Gateway API (K23), rodando como pod comum. O kube-proxy replacement do Cilium foi mantido (K24).

Validação: 40/40 requisições a partir de pods nos dois workers, divididas entre os dois backends (inclusive o do mesmo nó do Traefik); host sem rota → `404`.

## Linha do tempo da investigação

Registro honesto, incluindo os erros de diagnóstico — eles são parte do aprendizado.

| # | Hipótese / ação | Resultado |
|---|---|---|
| 1 | Migração do kube-proxy deixou regras velhas | Real, mas era outro problema: a limpeza estava falhando (ver "Bugs encontrados no caminho") |
| 2 | Portas do proxy diferentes entre os nós | **Erro meu**: comparei o encaminhamento de um nó com os listeners de outros. Nó a nó, as portas batiam |
| 3 | Módulos de TPROXY ausentes no kernel (aviso da documentação do Cilium) | Todos carregados |
| 4 | Roteamento por marca (`fwmark 0x200 → tabela 2004`) | Correto |
| 5 | `rp_filter` estrito da imagem da GCP | O próprio Cilium já desliga nas interfaces dele |
| 6 | eBPF host routing pulando o iptables | Host routing estava `Legacy` |
| 7 | `bpf.tproxy: true` (desvio em eBPF) | **Primeiro teste inválido**: o helm atualizou o ConfigMap, mas os agentes não reiniciaram (faltava `rollOutCiliumPods`). Depois de corrigido, sem efeito |
| 8 | Envoy recusando configuração | Real: `reuse port cannot be changed during an update` ao trocar opções; reiniciar o Envoy depois dos agentes resolveu o NACK, não o problema |
| 9 | `socketLB.hostNamespaceOnly: false` | O Cilium manteve `true` nesta combinação |
| 10 | Políticas (NPDS) não chegando ao Envoy | Chegavam normalmente |
| 11 | Plano B: modo host network do Gateway | Mesma falha, agora também a partir do nó: mostrou que o problema não era o caminho de **entrada** |
| 12 | `tailscale0` como device do Cilium | `devices: ens4` não mudou nada (mantido por outros motivos) |
| 13 | **Leitura dos contadores certos** do Envoy (`metrics`, não `stats`) | **Virada da investigação**: toda requisição chegava ao Envoy; a falha era na **saída** para o pod local |
| 14 | Envoy embutido no agente (`envoy.enabled: false`) | Mesma falha (dado novo, reportado na issue) |

**O erro que mais custou tempo:** durante os passos 3–12, usei `cilium-dbg envoy admin stats`, que **não é um subcomando válido** — ele só imprimia a ajuda, e os filtros a descartavam. Daí a conclusão errada de que "nenhuma requisição chegava ao Envoy", que direcionou a investigação para o caminho de entrada. Lição: **validar que a ferramenta de medição devolve dados antes de concluir qualquer coisa a partir de "zero"**.

## Bugs encontrados no caminho (corrigidos nos playbooks)

| Bug | Sintoma | Correção |
|---|---|---|
| `grep -q` + `set -o pipefail` | A limpeza do iptables pulava justamente a tabela principal: o `-q` fecha o pipe cedo, o `iptables-save` recebe `SIGPIPE` e o `if` dava falso | Contar com `grep -c` (lê a saída inteira) |
| Limpeza ampla (`grep -v KUBE`) | Apagava as regras do kubelet, que as recria: o playbook nunca chegava a `changed=0` | Remover só as cadeias do kube-proxy |
| Pods do kube-proxy terminando | Eles recriavam as regras depois da limpeza | `kubectl wait --for=delete` antes de limpar |
| Helm sem reiniciar pods | Mudanças de configuração do Cilium só valiam no próximo restart | `rollOutCiliumPods`, `envoy.rollOutPods`, `operator.rollOutPods` |
| Aspas no `jsonpath` | O módulo `command` do Ansible removia as aspas de `"InternalIP"` | Forma `argv` |

## Comandos que realmente diagnosticaram

```bash
# contadores do Envoy por backend (quem falha e quem funciona)
kubectl -n kube-system exec <cilium-pod-do-nó> -c cilium-agent -- cilium-dbg envoy admin clusters | grep <rota>
# métricas do Envoy (formato Prometheus) — o subcomando certo é "metrics"
kubectl -n kube-system exec <cilium-pod-do-nó> -c cilium-agent -- cilium-dbg envoy admin metrics
# fluxos de um pod (mostrou o SYN "to-proxy" sem resposta)
kubectl -n kube-system exec <cilium-pod-do-nó> -c cilium-agent -- hubble observe --pod <ns>/<pod> -o compact
```
