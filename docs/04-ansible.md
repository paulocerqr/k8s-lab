# 04 — Ansible: o cluster do zero, sem passos manuais

Os passos do [03-kubeadm.md](03-kubeadm.md), feitos à mão uma vez, viraram playbooks idempotentes em [`ansible/`](../ansible). Junto com o Terraform, o cluster inteiro é recriado com dois comandos.

## Terraform + Ansible: quem faz o quê

| | Terraform | Ansible |
|---|---|---|
| Pergunta que responde | **Quais** máquinas e redes existem? | **O que** está configurado **dentro** das máquinas? |
| Fala com | API da GCP | SSH nos nós, pela tailnet |
| Guarda estado | Sim (`terraform.tfstate`) | Não: confere o estado real a cada execução |
| No lab | VPC, firewall, conta de serviço, 3 VMs | containerd, pacotes do Kubernetes, `init`, `join`, kubeconfig, Cilium |

## Os arquivos

```
ansible/
├── ansible.cfg                     # usuário "lab", sudo, SSH pela tailnet, tempo de cada tarefa
├── inventory.ini                   # [control_plane] cp-1 · [workers] worker-1, worker-2
├── group_vars/all/main.yml         # versões fixas e redes do cluster
├── templates/kubeadm-config.yaml.j2
├── site.yml                        # importa os playbooks na ordem
└── playbooks/
    ├── 00-base.yml
    ├── 01-kubernetes-pacotes.yml
    ├── 02-control-plane.yml
    ├── 03-workers.yml
    ├── 04-kubeconfig-local.yml
    ├── 05-cilium.yml
    └── 06-beszel-agent.yml
```

| Playbook | Onde roda | Equivale a | O que faz |
|---|---|---|---|
| `00-base` | 3 nós | Passo 1.1–1.4 | Confere swap e cgroup v2; módulos; sysctl; repositório do Docker; containerd 2.x com `SystemdCgroup` |
| `01-kubernetes-pacotes` | 3 nós | Passo 1.5–1.6 | Repositório v1.37; **pinning do `pkgs.k8s.io` antes de instalar**; versão fixa; hold |
| `02-control-plane` | `cp-1` | Passo 2 | Lê nome e IP da tailnet do próprio Tailscale; gera a configuração; `kubeadm init` |
| `03-workers` | workers | Passo 5 | Token novo (30 min) e `join`, com `no_log` |
| `04-kubeconfig-local` | `cp-1` → PC | Passo 3 | Copia o `admin.conf` para `~/.kube/k8s-lab.conf` apontando para a tailnet |
| `05-cilium` | PC | Passo 4 | `helm upgrade --install` com `cluster/cilium/values.yaml`; espera os nós `Ready` |
| `06-beszel-agent` | 3 nós | — | Opcional: agent do Beszel (binário + systemd), só se as credenciais do Hub existirem |

## Como a idempotência foi garantida

| Situação | Técnica |
|---|---|
| `kubeadm init` e `join` não podem rodar duas vezes | `creates: /etc/kubernetes/admin.conf` e `creates: /etc/kubernetes/kubelet.conf` |
| Não reiniciar o containerd à toa | A configuração é **comparada** com a gravada; o handler só roda se houver diferença |
| Pacotes travados (`hold`) entre execuções | `allow_change_held_packages` no módulo `apt`, sem destravar e travar de novo |
| Comandos que só leem informação | `changed_when: false` e `check_mode: false` (rodam até no `--check`) |
| Token de join é uma credencial | Gerado a cada execução que precise de join, com validade de 30 min e `no_log` |
| Nada da tailnet no Git | Nome e IP lidos com `tailscale status --self --json` na hora |

## Validação em três etapas

### 1. Simulação contra o cluster montado à mão

```bash
ansible-playbook site.yml --check --diff
```

Nenhuma falha e nenhuma mudança no que importa (pacotes, kernel, `init`, `join`, Cilium). As diferenças encontradas:
- migração dos repositórios `.list` da instalação manual para o formato deb822;
- **dono do socket do containerd**: `containerd config default` grava o usuário de quem o executa. À mão, ele rodou como `lab` (uid 1000), deixando o socket com dono `lab` em vez de `root`. O playbook roda como root e corrige.

### 2. Idempotência

| Execução | `changed` (cp-1 / worker-1 / worker-2) |
|---|---|
| 1ª (aplica as correções) | 8 / 5 / 5 |
| 2ª | **0 / 0 / 0** |

### 3. Recriação do zero (19/10/2026)

```bash
terraform -chdir=terraform destroy
# Tailscale: remover as 3 machines antigas e gerar uma auth key nova (terraform.tfvars)
for n in cp-1 worker-1 worker-2; do ssh-keygen -R $n; done
terraform -chdir=terraform apply
cd ansible && ansible-playbook site.yml
```

| Etapa | Tempo |
|---|---|
| `terraform destroy` (11 recursos) | 89 s |
| `terraform apply` (11 recursos) | 123 s |
| Nós na tailnet com os nomes originais | 20 s |
| `ansible-playbook site.yml` (0 falhas) | 217 s |
| **Total: do zero ao cluster pronto** | **≈ 6 min** |

Resultado: 3 nós `Ready` (v1.37.1, containerd 2.4.2), 18 pods `Running`, Cilium `OK` e teste de rede entre nós aprovado, **sem nenhum comando digitado nos nós**.

## Cuidados ao recriar

| O que muda | Por quê | Como tratar |
|---|---|---|
| Auth key do Tailscale | A anterior foi revogada ou venceu | Gerar uma nova (reutilizável, pré-aprovada, `tag:k8s-lab`, 1 dia) antes do `apply`; revogar depois |
| Nomes na tailnet | As machines antigas continuam cadastradas; as novas entrariam como `cp-1-1`… e o inventário quebraria | Remover as 3 machines antigas antes do `apply` |
| Chaves SSH dos nós | VMs novas têm chaves novas | `ssh-keygen -R` para os três nomes |
| Kubeconfig do PC | Credenciais do cluster novo | Sobrescrito pelo playbook `04` |

## Beszel (opcional)

O `06-beszel-agent.yml` só roda se `beszel_hub_url` estiver definido. As credenciais ficam cifradas com o `ansible-vault`:

```bash
ansible-vault create group_vars/all/vault.yml
#   beszel_hub_url: "https://<hub>.<tailnet>.ts.net"
#   beszel_key: "ssh-ed25519 AAAA..."
#   beszel_token: "..."
ansible-playbook site.yml --ask-vault-pass
```

O DNS dos nós é o da GCP (`169.254.169.254`), que não resolve `*.ts.net` (o mesmo problema do incidente 001 do `beszel-infra`). O playbook grava o nome do Hub no `/etc/hosts` de cada nó com o IP da tailnet obtido no PC de administração.
