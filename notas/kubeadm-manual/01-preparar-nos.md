# Etapa 1: preparar os nós

## Objetivo

Deixar o sistema pronto para o Kubernetes, com o kernel configurado, um container runtime (o containerd) e as três ferramentas do Kubernetes. Esta etapa é igual nos 3 nós. Primeiro no servidor control plane, um bloco por vez, conferindo a saída de cada um. Depois repita nos workers.

```bash
ssh usuario@control-plane
```

## 1.1 Conferir os pré-requisitos

- O kubelet, por padrão, não aceita swap: ele precisa saber exatamente quanta memória tem para decidir onde colocar os pods. Ele também precisa do cgroup v2, o mecanismo do kernel que limita CPU e memória dos containers.

```bash
cat /proc/swaps                  # deve mostrar só o cabeçalho (sem swap)
stat -fc %T /sys/fs/cgroup       # deve mostrar: cgroup2fs
```

## 1.2 Módulos do kernel

- overlay: sistema de arquivos em camadas que as imagens de container usam.
- br_netfilter: faz o tráfego entre pods, que passa por uma bridge, ser visível para as regras de firewall que o Kubernetes cria.

O arquivo em /etc/modules-load.d/ garante que eles carreguem a cada boot, e o modprobe carrega agora.

```bash
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
lsmod | grep -E '^(overlay|br_netfilter)'
```

## 1.3 Parâmetros de rede do kernel (sysctl)

- ip_forward = 1: permite que o nó encaminhe pacotes entre interfaces, ou seja, entre pods e para fora.
- bridge-nf-call-*tables = 1: aplica as regras de iptables ao tráfego da bridge, o que faz os Services do Kubernetes funcionarem.

```bash
cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system | grep -E 'bridge-nf-call|ip_forward'
```

## 1.4 containerd (o container runtime)

O Kubernetes não roda containers sozinho. O kubelet pede ao containerd, pela interface CRI, que baixe imagens e crie containers. Usamos o pacote containerd.io do repositório do Docker, que traz a versão 2.x.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gpg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y containerd.io
containerd --version
```

O containerd.io vem com o plugin CRI desligado, porque foi pensado para o Docker. Por isso geramos a configuração padrão completa. Também ligamos o SystemdCgroup: o kubelet e o containerd precisam usar o mesmo gerenciador de cgroups, e no Debian esse gerenciador é o systemd. Se divergirem, os pods ficam reiniciando.

```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep -n 'SystemdCgroup' /etc/containerd/config.toml
sudo systemctl restart containerd
systemctl is-active containerd
```

## 1.5 kubeadm, kubelet e kubectl

| Ferramenta | Papel |
|---|---|
| `kubeadm` | Monta o cluster: gera os certificados, sobe o control plane e faz o join dos nós. |
| `kubelet` | O agente que roda em todo nó e garante que os containers de cada pod estejam rodando. |
| `kubectl` | O cliente para comandar o cluster de dentro do nó. |

O repositório é fixado na série 1.37. O apt-mark hold impede que um apt upgrade troque a versão sozinho: no Kubernetes, atualizar é um procedimento à parte (kubeadm upgrade).

```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.37/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl containerd.io
sudo systemctl enable kubelet
kubeadm version -o short
```

Depois disso, o kubelet vai ficar reiniciando em loop (systemctl status kubelet). Isso é normal: ele ainda não tem a configuração, que o kubeadm init cria na etapa 2.

---

Quando terminar no control plane, rode os três comandos para verificar:

```bash
sudo sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
grep -n 'SystemdCgroup' /etc/containerd/config.toml
systemctl is-active kubelet
```

A saída deve ser algo assim:

```text
usuario@contro-plane:/$ sudo sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward

# saida
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1

usuario@contro-plane:/$ grep -n 'SystemdCgroup' /etc/containerd/config.toml

# saida
89:            SystemdCgroup = true

usuario@contro-plane:/$ systemctl is-active kubelet

# saida
inactive
```

Se algum comando der erro, em especial, se o grep SystemdCgroup não mostrar nada, a configuração do containerd 2.x pode ter mudado de formato.

[Índice das etapas](../kubeadm-manual.md)
