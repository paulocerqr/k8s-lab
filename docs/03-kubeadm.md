# 03 — Cluster com kubeadm (instalação manual)

Primeira montagem do cluster, feita **à mão** (decisão K18) para entender cada peça antes de automatizar com o Ansible. Os comandos foram executados pelo operador; as anotações de campo estão em [`notas/kubeadm-manual.md`](../notas/kubeadm-manual.md).

**Resultado (19/10/2026):** 3 nós `Ready`, Kubernetes v1.37.1, containerd 2.4.2, Cilium 1.20.3, teste de rede entre nós aprovado.

## As peças

| Peça | O que é | Onde roda |
|---|---|---|
| **containerd** | *Container runtime*: baixa imagens e cria containers, a pedido do kubelet (interface CRI) | Todos os nós |
| **kubelet** | Agente do Kubernetes em cada nó; garante que os containers de cada pod estejam rodando | Todos os nós |
| **kubeadm** | Ferramenta que monta o cluster: certificados, control plane, join | Usado em todos os nós, uma vez |
| **kubectl** | Cliente da API do Kubernetes | Nós e PC de administração |
| **etcd** | Banco chave-valor com todo o estado do cluster | `cp-1` (static pod) |
| **kube-apiserver** | Porta de entrada do cluster (6443) | `cp-1` (static pod) |
| **kube-scheduler** | Decide em qual nó cada pod roda | `cp-1` (static pod) |
| **kube-controller-manager** | Laços de controle (réplicas, IPs de pods por nó...) | `cp-1` (static pod) |
| **kube-proxy** | Implementa os Services (IPs virtuais) com regras de iptables | Todos os nós (DaemonSet) |
| **CoreDNS** | DNS interno: `meu-servico` → IP do Service | Workers (Deployment) |
| **Cilium** | CNI: dá IP aos pods e liga pods de nós diferentes (VXLAN) | Todos os nós (DaemonSet) |

*Static pods* são pods que o kubelet sobe a partir de arquivos em `/etc/kubernetes/manifests/`, sem depender do próprio cluster. É assim que o control plane existe antes de o cluster existir.

## Versões

| Componente | Versão | Origem |
|---|---|---|
| Kubernetes (kubeadm, kubelet, kubectl) | 1.37.1 | `pkgs.k8s.io/core:/stable:/v1.37` |
| containerd | 2.4.2 | Repositório do Docker (`containerd.io`) |
| Cilium | 1.20.3 | Chart Helm `cilium/cilium` |
| SO | Debian 13 (kernel 6.12, cgroup v2) | Imagem `debian-cloud/debian-13` |

## Passo 1 — Preparar os nós (os 3)

| Etapa | O que faz | Por quê |
|---|---|---|
| 1.1 Conferir swap e cgroup | `cat /proc/swaps`, `stat -fc %T /sys/fs/cgroup` | O kubelet não aceita swap por padrão e exige cgroup v2 |
| 1.2 Módulos `overlay` e `br_netfilter` | `/etc/modules-load.d/k8s.conf` + `modprobe` | Sistema de arquivos das imagens; tráfego da bridge visível ao iptables |
| 1.3 sysctl | `ip_forward=1`, `bridge-nf-call-ip(6)tables=1` em `/etc/sysctl.d/k8s.conf` | O nó encaminha pacotes de pods; os Services funcionam |
| 1.4 containerd | `containerd.io` (Docker) + `config default` + `SystemdCgroup = true` | Runtime compatível com o Kubernetes 1.37; mesmo gerenciador de cgroups que o kubelet |
| 1.5 kubeadm/kubelet/kubectl | Repositório `pkgs.k8s.io` v1.37 + `apt-mark hold` | Versão fixa; atualização só via `kubeadm upgrade` |
| 1.6 Pinning do apt | `/etc/apt/preferences.d/kubernetes` (prioridade 1001 para `pkgs.k8s.io`) | Ver problema 2 abaixo |

## Passo 2 — `kubeadm init` (`cp-1`)

Configuração em arquivo (`~/kubeadm-config.yaml`), não em flags:

| Campo | Valor | Por quê |
|---|---|---|
| `advertiseAddress` | `10.10.0.3` | IP do `cp-1` na VPC: é por ele que os workers chegam ao API server |
| `podSubnet` | `10.244.0.0/16` | IPs dos pods; não colide com a VPC (`10.10.0.0/24`) |
| `serviceSubnet` | `10.96.0.0/12` | IPs virtuais dos Services |
| `certSANs` | `cp-1`, `cp-1.<tailnet>.ts.net`, IP da tailnet, `10.10.0.3` | O certificado do API server aceita o `kubectl` vindo pela tailnet |
| `cgroupDriver` (kubelet) | `systemd` | Igual ao `SystemdCgroup = true` do containerd |

```bash
sudo kubeadm config images pull --config ~/kubeadm-config.yaml
sudo kubeadm init --config ~/kubeadm-config.yaml | tee ~/kubeadm-init.log
mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown "$(id -u):$(id -g)" ~/.kube/config
```

Estado esperado logo após o `init`: `cp-1` **NotReady** e CoreDNS **Pending**, porque ainda não há CNI.

## Passo 3 — `kubectl` no PC, pela tailnet

O `admin.conf` aponta para `https://10.10.0.3:6443`, que o PC não alcança (IP privado da VPC). A cópia no PC troca o endereço pelo nome do `cp-1` na tailnet, aceito graças aos `certSANs`:

```bash
ssh lab@cp-1 'cat ~/.kube/config' > ~/.kube/k8s-lab.conf
chmod 600 ~/.kube/k8s-lab.conf
sed -i 's#server: https://10.10.0.3:6443#server: https://cp-1.<tailnet>.ts.net:6443#' ~/.kube/k8s-lab.conf
export KUBECONFIG=~/.kube/k8s-lab.conf
```

> `k8s-lab.conf` é a credencial de administrador do cluster: permissão 600, nunca no Git.

## Passo 4 — Cilium (CNI), via Helm a partir do PC

Configuração versionada em [`cluster/cilium/values.yaml`](../cluster/cilium/values.yaml):

| Opção | Valor | Por quê |
|---|---|---|
| `ipam.mode` | `kubernetes` | Usa o `/24` que o controller-manager atribui a cada nó a partir do `podSubnet`. O padrão do Cilium (`10.0.0.0/8`) colidiria com a VPC |
| `routingMode` / `tunnelProtocol` | `tunnel` / `vxlan` | Tráfego entre nós encapsulado; não precisa de rotas na GCP |
| `kubeProxyReplacement` | `false` | Mantém o kube-proxy do kubeadm (substituição por eBPF fica como evolução) |
| `hubble.relay` / `hubble.ui` | habilitados | Visualização do tráfego entre pods |

```bash
helm repo add cilium https://helm.cilium.io/ && helm repo update
helm upgrade --install cilium cilium/cilium --version 1.20.3 -n kube-system -f cluster/cilium/values.yaml
```

Resultado: `cp-1` **Ready**, CoreDNS **Running**. `hubble-relay` e `hubble-ui` ficaram **Pending** até haver workers: o `cp-1` tem o *taint* `node-role.kubernetes.io/control-plane:NoSchedule`, que só pods com *toleration* (como o agente do Cilium) ignoram.

## Passo 5 — `kubeadm join` (workers)

```bash
# no cp-1: o token do init vale 24 h; gerar um novo
sudo kubeadm token create --print-join-command
# em cada worker, com sudo:
sudo kubeadm join 10.10.0.3:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

O `join` faz a **descoberta** (confere o hash da CA, para ter certeza de que fala com o control plane certo), o **TLS bootstrap** (o kubelet ganha um certificado próprio) e o **registro** do nó.

> O comando de join é uma credencial enquanto o token vale: não vai para chat, anotações ou Git.

## Passo 6 — Teste de rede

```bash
kubectl create deployment teste-rede --image=nginx:1.29-alpine --replicas=2
kubectl expose deployment teste-rede --port 80
kubectl run cliente --rm -i --image=busybox:1.37 --restart=Never -- wget -qO- http://teste-rede
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief
kubectl delete deployment,service teste-rede
```

| Observado | Comprova |
|---|---|
| Pods em `worker-1` (`10.244.1.210`) e `worker-2` (`10.244.2.40`) | Cada nó com sua faixa `/24` do `podSubnet` |
| Service com IP `10.105.168.231` | kube-proxy criando IPs virtuais (`10.96.0.0/12`) |
| `<title>Welcome to nginx!</title>` | CoreDNS resolveu o nome; tráfego atravessou nós pelo VXLAN |
| `cilium-dbg status` → `OK` | Agentes do Cilium saudáveis |

## Estado final

```
NAME       STATUS   ROLES           VERSION   INTERNAL-IP   CONTAINER-RUNTIME
cp-1       Ready    control-plane   v1.37.1   10.10.0.3     containerd://2.4.2
worker-1   Ready    <none>          v1.37.1   10.10.0.2     containerd://2.4.2
worker-2   Ready    <none>          v1.37.1   10.10.0.4     containerd://2.4.2
```

## Problemas encontrados

### 1. containerd do Debian não serve para o Kubernetes 1.37

O Debian 13 oferece o containerd **1.7.24**. O changelog do Kubernetes alinha o fim do suporte ao containerd 1.7 com a versão 1.37. **Solução:** `containerd.io` 2.x do repositório oficial do Docker. Esse pacote vem com o plugin CRI **desligado** (feito para o Docker), por isso a configuração é regenerada com `containerd config default`.

### 2. Dois pacotes chamados `kubectl`

A imagem Debian da GCP já traz o repositório do Google Cloud SDK, que publica um pacote **também chamado `kubectl`** (um "dispatcher" do gcloud) com versão `1:589.0.0-0`. O `1:` é uma *epoch*, que vence qualquer versão sem epoch, então o apt instalou o pacote do Google (que se apresentava como v1.35.9) no lugar do `1.37.1-1.1` do `pkgs.k8s.io`. `kubeadm` e `kubelet` não foram afetados (o Google não publica pacotes com esses nomes).

**Solução:** *pinning* do apt com prioridade 1001 para a origem `pkgs.k8s.io`; acima de 1000, o apt aceita até voltar de versão:

```
# /etc/apt/preferences.d/kubernetes
Package: kubectl kubeadm kubelet cri-tools kubernetes-cni
Pin: origin pkgs.k8s.io
Pin-Priority: 1001
```

seguido de `apt-mark unhold kubectl && apt-get install --allow-downgrades kubectl && apt-mark hold kubectl`. No Ansible, o pinning entra **antes** da instalação dos pacotes.

### 3. `apt-mark` interpreta `.` como expressão regular

Um `apt-mark hold containerd.i` (erro de digitação) travou `containerd.io-dbgsym` e `golang-github-containerd-imgcrypt-dev`, pacotes nem instalados. Inofensivo, mas mostra o risco. Conferir sempre com `apt-mark showhold`.

### 4. `sysctl: command not found`

No Debian, comandos de administração em `/usr/sbin` não estão no `PATH` de usuários comuns; com `sudo` funcionam.

### 5. Token de join expirado

O token criado pelo `init` vale 24 h; o join aconteceu 32 h depois. `kubeadm token create --print-join-command` gera outro (o hash da CA não muda).

### 6. Erros de digitação no shell (aprendizado)

- `\ ` no meio de uma linha vira um espaço literal no argumento (`" wget"`); a `\` só serve como continuação **no fim** da linha.
- Num *heredoc*, a linha de fechamento precisa ser exatamente `EOF`, sem comentário depois.
- `kubectl -wide` é lido como as flags curtas `-w -i -d -e`; o certo é `-o wide`.
- `kubectl run -it ... | grep`: o `-t` (terminal) não combina com pipe; use só `-i`.

## Próximo passo

Transformar estes passos em playbooks do Ansible (`ansible/playbooks/00-base.yml` a `05-kubeconfig.yml`) e provar que o cluster sobe do zero sem nenhum passo manual (`terraform destroy` → `apply` → `ansible-playbook site.yml`).
