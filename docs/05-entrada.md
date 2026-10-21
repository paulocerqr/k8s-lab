# 05 — Entrada do cluster: kube-proxy replacement e Gateway API

Como uma requisição de fora chega a um pod, e as peças que fazem isso: o **Cilium** cuidando dos Services (no lugar do kube-proxy) e o **Traefik** como proxy reverso pela **Gateway API**.

## O caminho completo

```
Usuário → https://jobradar-lab.utileasy.com.br
   │
   ▼
Cloudflare ─ DNS + TLS (o HTTPS termina aqui)
   │  túnel de saída (próxima etapa: cloudflared)
   ▼
cloudflared (pod) ──► Service traefik.traefik:80 (ClusterIP)
                          │   (Services resolvidos pelo Cilium em eBPF, sem kube-proxy)
                          ▼
                     Traefik (2 réplicas) ── Gateway "lab", listener *.utileasy.com.br
                          │   HTTPRoute: jobradar-lab.utileasy.com.br → Service job-radar
                          ▼
                     Service → Pods
```

## As peças

| Peça | O que é | No lab |
|---|---|---|
| **kube-proxy** | Componente padrão que implementa os Services criando regras de iptables em cada nó | **Removido** (K24) |
| **kube-proxy replacement (Cilium)** | O Cilium implementa os Services em eBPF, direto no kernel | `kubeProxyReplacement: true` em `cluster/cilium/values.yaml` |
| **Gateway API** | Padrão oficial do Kubernetes para entrada HTTP, sucessor do objeto `Ingress` | CRDs v1.6.3 |
| **GatewayClass** | "Qual software implementa" os Gateways | `traefik` |
| **Gateway** | A porta de entrada: protocolo, porta, domínios aceitos | `lab` (namespace `traefik`), HTTP, `*.utileasy.com.br` |
| **HTTPRoute** | A regra de roteamento: "este host/caminho vai para este Service" | Uma por aplicação, no namespace da aplicação |
| **Traefik** | Proxy reverso que lê os Gateways e HTTPRoutes e encaminha o tráfego | Chart `traefik/traefik` 42.1.0, 2 réplicas (uma por worker) |

Comparando com o servidor doméstico: o Traefik faz o papel do **Caddy**, e cada HTTPRoute é o equivalente a um bloco do `Caddyfile`, só que versionado como objeto do cluster.

## Arquivos

| Arquivo | Conteúdo |
|---|---|
| `cluster/cilium/values.yaml` | Cilium com kube-proxy replacement; Gateway API do Cilium **desligada** |
| `cluster/traefik/values.yaml` | Traefik só com o provider de Gateway API, Service ClusterIP, Gateway `lab` |
| `ansible/playbooks/05-cilium.yml` | Instala/atualiza o Cilium; passa `k8sServiceHost` lido do cluster |
| `ansible/playbooks/06-traefik.yml` | CRDs da Gateway API + Traefik; espera o Gateway ficar `Programmed` |
| `ansible/playbooks/migracao-kube-proxy.yml` | Uso único: tira o kube-proxy de um cluster que já o tinha |
| `ansible/templates/kubeadm-config.yaml.j2` | `skipPhases: [addon/kube-proxy]`: clusters novos nascem sem kube-proxy |

## Por que o Cilium precisa de `k8sServiceHost`

Com o kube-proxy, o Cilium encontra o API server pelo Service `kubernetes` (`10.96.0.1`). Sem kube-proxy, **é o próprio Cilium que implementa esse Service**: ele não pode depender dele para ligar. Por isso recebe o endereço real do API server (IP do `cp-1` na VPC), que o playbook lê do próprio cluster com `kubectl get nodes`.

## Por que Traefik e não a Gateway API do Cilium

A primeira escolha foi a Gateway API do próprio Cilium (sem componente a mais). Ela foi instalada e funcionou **pela metade**: o Envoy do Cilium não consegue se conectar a pods que estão no mesmo nó que ele, então metade das requisições falhava. É um bug aberto do Cilium ([#47940](https://github.com/cilium/cilium/issues/47940)), sem correção nem contorno; a investigação completa está no [incidente 002](incidentes/002-gateway-cilium-backend-mesmo-no.md). O Traefik roda como um pod comum e não passa por esse caminho.

O kube-proxy replacement **continua**: ele funciona e não depende da Gateway do Cilium.

## Migração do kube-proxy (no cluster que já existia)

```bash
cd ansible
ansible-playbook playbooks/05-cilium.yml             # liga o kube-proxy replacement
ansible-playbook playbooks/migracao-kube-proxy.yml   # remove o kube-proxy e as regras dele
```

O playbook de migração:
1. **confirma** que o Cilium já está com `KubeProxyReplacement: True` (sem isso, remover o kube-proxy derrubaria todos os Services);
2. apaga o DaemonSet e a configuração do kube-proxy e **espera os pods terminarem** (eles recriam regras enquanto saem);
3. remove **só** as cadeias de iptables do kube-proxy (`KUBE-SVC-*`, `KUBE-SEP-*`, `KUBE-SERVICES`...). As do kubelet (`KUBE-FIREWALL`, `KUBE-KUBELET-CANARY`, `KUBE-IPTABLES-HINT`) ficam: ele as recria e elas devem existir;
4. reinicia o Cilium **só se** algo foi limpo. Rodar de novo: `changed=0`.

| | Antes | Depois |
|---|---|---|
| `KubeProxyReplacement` | `False` | `True` |
| DaemonSet `kube-proxy` | 3 pods | removido |
| Regras `KUBE-*` por nó | 101 | só as 3 cadeias do kubelet |

## Conferindo

```bash
export KUBECONFIG=~/.kube/k8s-lab.conf
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | grep ^KubeProxyReplacement
kubectl get gatewayclass,gateway -A
kubectl -n traefik get pods -o wide
```

Teste de ponta a ponta (de dentro do cluster, antes do túnel existir):

```bash
# app de teste + rota para teste-lab.utileasy.com.br
kubectl create namespace teste-gw
kubectl -n teste-gw create deployment whoami --image=traefik/whoami:v1.11.0 --replicas=2
kubectl -n teste-gw expose deployment whoami --port 80
cat <<'EOF' | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: whoami, namespace: teste-gw}
spec:
  parentRefs: [{name: lab, namespace: traefik}]
  hostnames: ["teste-lab.utileasy.com.br"]
  rules: [{backendRefs: [{name: whoami, port: 80}]}]
EOF

# 20 requisições a partir de um pod: todas devem responder, alternando entre os 2 pods
kubectl -n teste-gw run cliente --rm -i --restart=Never --image=busybox:1.37 -- sh -c \
  'for i in $(seq 1 20); do wget -qO- -T 5 --header "Host: teste-lab.utileasy.com.br" http://traefik.traefik | grep ^Hostname; done'

kubectl delete namespace teste-gw
```

Resultado em 21/10/2026: **40/40** requisições com sucesso (20 de cada worker), divididas entre os dois pods, incluindo o pod no mesmo nó do Traefik; host sem rota → `404`.
