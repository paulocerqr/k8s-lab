# 00 — Ferramentas da máquina de administração

Tudo no lab é operado a partir de uma única máquina, o PC de administração (CachyOS). Este documento explica **para que serve cada ferramenta** e **como ela foi instalada**.

| Ferramenta | Versão | Para que serve no lab | Como foi instalada |
|---|---|---|---|
| `gcloud` | 589.0.0 | Autenticar na GCP e consultar/operar recursos pontualmente | Pacote oficial do Google, na pasta do usuário |
| `terraform` | 1.15.9 | **Criar a infraestrutura** (rede, firewall, VMs) a partir de arquivos | `pacman` |
| `ansible` | core 2.21.5 | Configurar o sistema dos nós (containerd, kubeadm...) | `pacman` |
| `kubectl` | 1.37.1 | Operar o cluster Kubernetes | `pacman` |
| `helm` | 4.3.0 | Instalar componentes de terceiros no cluster (Cilium, ingress...) | `pacman` |
| `tailscale` | 1.104.1 | Rede privada entre o PC e os nós; SSH sem porta pública | Já estava instalado |
| `git` / `gh` | — | Versionar e publicar o repositório no GitHub | Já estavam instalados |

## Visão geral: quem faz o quê

```
            seu PC (CachyOS)
 ┌──────────────────────────────────────────┐
 │ gcloud     → login na GCP (credenciais)  │
 │ terraform  → cria rede, firewall e VMs   │──── API da GCP ───► recursos no projeto
 │ ansible    → configura o SO dos nós      │──┐
 │ kubectl    → comanda o cluster           │──┤
 │ helm       → instala pacotes no cluster  │──┤  tudo pela tailnet
 │ tailscale  → rede privada até os nós     │──┘  (nada exposto na internet)
 └──────────────────────────────────────────┘
```

Regra prática: **o Terraform é a fonte da verdade da infraestrutura**. O `gcloud` serve para login e consultas; ele não deve criar o que o Terraform gerencia, senão o código deixa de representar a realidade.

---

## 1. Google Cloud CLI (`gcloud`)

**O que é:** a linha de comando oficial da Google Cloud. Faz login, lê e altera recursos do projeto.

**Por que foi instalado fora do `pacman`:** o pacote `google-cloud-cli` saiu do AUR (só restou uma variante "lite" sem manutenção garantida). O Google distribui um pacote `.tar.gz` oficial que roda inteiro na pasta do usuário, **sem `sudo`**.

**Passos executados:**

```bash
# 1. baixar o pacote oficial
curl -fL -o gcloud.tar.gz \
  https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz

# 2. extrair em ~/.local/share (pasta do usuário, sem sudo)
tar -xzf gcloud.tar.gz -C ~/.local/share

# 3. instalador em modo silencioso, sem mexer no .bashrc/.zshrc
~/.local/share/google-cloud-sdk/install.sh --quiet \
  --usage-reporting=false --path-update=false --command-completion=false

# 4. disponibilizar o comando: ~/.local/bin já está no PATH
ln -sf ~/.local/share/google-cloud-sdk/bin/gcloud ~/.local/bin/gcloud
```

**Autenticação (feita por você, abre o navegador):**

```bash
gcloud auth login                       # credencial do *gcloud* (seus comandos)
gcloud auth application-default login   # credencial que *outros programas* usam (o Terraform)
gcloud config set project <ID-do-projeto>
```

> Existem **duas** credenciais diferentes. `auth login` vale para os comandos `gcloud`. `application-default login` grava um arquivo em `~/.config/gcloud/` que bibliotecas e ferramentas como o Terraform leem automaticamente. Sem a segunda, o `terraform plan` falha com erro de credencial.

**Onde o `gcloud` foi usado até agora** (só consultas e operações pontuais; nenhuma VM foi criada por ele):

| Comando | Para quê |
|---|---|
| `gcloud config get-value project` | Ler o ID do projeto para preencher o `terraform.tfvars` |
| `gcloud services list --enabled` | Conferir se a Compute Engine API estava habilitada |
| `gcloud compute instances/disks/addresses/snapshots list` | Inventário antes do primeiro `apply` (não havia VMs) |
| `gcloud compute snapshots delete ...` | Apagar 4 snapshots das VMs antigas |
| `gcloud compute resource-policies delete default-schedule-1` | Apagar a política de snapshot diário |
| `gcloud compute instances get-serial-port-output cp-1` | Ler o console serial para diagnosticar o [incidente 001](incidentes/001-cloud-init-debian-gcp.md) |
| `gcloud compute instances reset cp-1 worker-1 worker-2` | Reiniciar as VMs para o `startup-script` rodar |

---

## 2. Terraform

**O que é:** ferramenta de *infraestrutura como código*. Você descreve em arquivos `.tf` **o estado desejado** ("quero uma VPC, 3 regras de firewall e 3 VMs assim"); o Terraform compara com o que existe na nuvem e faz as chamadas de API necessárias para chegar lá. O mesmo código recria tudo do zero ou destrói tudo no fim do lab.

**Instalação** (por você, precisa de `sudo`):

```bash
sudo pacman -S --needed terraform
```

> Antes da instalação, a sintaxe foi validada com a imagem Docker oficial (`hashicorp/terraform:1.15.9`), rodando `terraform fmt` e `terraform validate`, que não precisam de credenciais.

Como os arquivos do lab funcionam e quais comandos foram executados: **[01-terraform.md](01-terraform.md)**.

---

## 3. Ansible

**O que é:** ferramenta de *configuração*. Conecta por SSH nas máquinas e aplica tarefas descritas em arquivos YAML (*playbooks*): instalar pacotes, editar arquivos, habilitar serviços. É **idempotente**: rodar de novo não refaz o que já está certo.

**Divisão de trabalho com o Terraform:** o Terraform cria a VM vazia; o Ansible configura o que roda dentro dela (containerd, kubeadm, Beszel agent). Ver decisão K17 no [plano](plano.md).

```bash
sudo pacman -S --needed ansible
```

Ainda não foi usado: entra depois da instalação manual do kubeadm (decisão K18).

---

## 4. kubectl

**O que é:** o cliente oficial do Kubernetes. Conversa com a API do cluster (no `cp-1`, porta 6443) para criar, listar e apagar recursos (pods, deployments, services...).

```bash
sudo pacman -S --needed kubectl
```

A versão do `kubectl` deve ficar a no máximo uma versão *minor* de distância da versão do cluster.

---

## 5. Helm

**O que é:** gerenciador de pacotes do Kubernetes. Instala aplicações de terceiros empacotadas em *charts* (Cilium, Traefik, Argo CD, Prometheus...), com um arquivo `values.yaml` para personalizar.

```bash
sudo pacman -S --needed helm
```

Os quatro pacotes foram instalados de uma vez:

```bash
sudo pacman -S --needed terraform ansible kubectl helm
```

---

## 6. Tailscale

**O que é:** VPN baseada em WireGuard que cria uma rede privada (*tailnet*) entre os seus dispositivos, sem abrir portas no firewall. No lab, é **o único caminho** do PC até os nós: SSH e, depois, o `kubectl`.

Já estava instalado e logado neste PC. A configuração específica do lab (tag, auth key, SSH) está em **[02-acesso-tailscale.md](02-acesso-tailscale.md)**.

---

## Conferindo o ambiente

```bash
terraform version
ansible --version
kubectl version --client
helm version --short
gcloud version
tailscale status
```
