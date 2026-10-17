# 01 — Terraform: como a infraestrutura é criada

Toda a infraestrutura do lab na GCP é criada pelo Terraform, a partir da pasta [`terraform/`](../terraform). **Nenhum recurso do lab foi criado pelo console ou pelo `gcloud`.**

## Como o Terraform funciona (em 4 conceitos)

| Conceito | O que é |
|---|---|
| **Provider** | Plugin que sabe falar com uma nuvem. Aqui, `hashicorp/google`, que chama as APIs da GCP. |
| **Resource** | Um bloco `resource "tipo" "nome" { ... }` descreve **um** recurso a existir (uma VM, uma regra de firewall...). |
| **State** | Arquivo `terraform.tfstate` em que o Terraform anota o que ele criou e os IDs reais na nuvem. É assim que ele sabe o que alterar ou destruir depois. |
| **Plan / Apply** | `plan` compara o código com o state e com a nuvem e **mostra** o que mudaria. `apply` **executa** essas mudanças. |

## Os arquivos, um a um

```
terraform/
├── versions.tf               # qual Terraform e qual provider usar
├── variables.tf              # parâmetros (projeto, zona, nós, auth key...)
├── main.tf                   # OS RECURSOS: rede, firewall, conta de serviço, VMs
├── bootstrap.sh.tftpl        # script que roda dentro de cada VM no boot
├── outputs.tf                # o que mostrar no fim do apply
├── terraform.tfvars.example  # modelo de valores (vai para o Git)
├── terraform.tfvars          # seus valores reais (NÃO vai para o Git)
├── .terraform.lock.hcl       # versão exata do provider (vai para o Git)
├── .terraform/               # provider baixado pelo init (NÃO vai para o Git)
└── terraform.tfstate         # o state (NÃO vai para o Git: tem dados sensíveis)
```

### `versions.tf`: com o que trabalhar

Declara a versão mínima do Terraform e o provider `hashicorp/google` na série 8.x (`~> 8.5`), e configura o provider com projeto, região e zona vindos das variáveis.

### `variables.tf`: os parâmetros

| Variável | Padrão | Para quê |
|---|---|---|
| `projeto` | — (obrigatória) | ID do projeto GCP |
| `regiao` / `zona` | `us-central1` / `us-central1-a` | Onde criar; tudo na mesma zona para o tráfego interno não ser cobrado |
| `nos` | `cp-1`: e2-standard-4, `worker-1/2`: e2-standard-2 | **Quais VMs criar**: nome → tipo de máquina |
| `disco_gb` | 30 | Tamanho do disco de cada VM |
| `imagem` | `debian-cloud/debian-13` | Sistema operacional |
| `usuario_admin` | `lab` | Usuário criado nos nós |
| `tailscale_auth_key` | — (obrigatória, sensível) | Chave que coloca os nós na tailnet |
| `tailscale_tag` | `tag:k8s-lab` | Tag dos nós na tailnet |
| `ligado` | `true` | `false` para parar as VMs sem destruir |

### `main.tf`: **é aqui que as VMs e a rede são criadas**

| Bloco | Recurso criado na GCP | Para quê |
|---|---|---|
| `google_compute_network.lab` | VPC `lab` | Rede própria do lab, sem as regras abertas da VPC `default` (K19) |
| `google_compute_subnetwork.nos` | Subnet `lab-nos` (`10.10.0.0/24`) | Faixa de IPs internos dos nós |
| `google_compute_firewall.interno` | Regra `lab-interno` | Libera todo o tráfego **entre os nós** (API do Kubernetes, kubelet, etcd, Cilium) |
| `google_compute_firewall.tailscale` | Regra `lab-tailscale` | UDP 41641, para o Tailscale conectar direto, sem relay |
| `google_compute_firewall.iap_ssh` | Regra `lab-iap-ssh` | SSH **só** a partir da faixa do IAP do Google: acesso de emergência |
| `google_service_account.nos` | Conta de serviço `k8s-lab-nos` | Identidade das VMs na GCP |
| `google_project_iam_member.nos` | 2 permissões | Só escrita de logs e métricas (mínimo recomendado) |
| **`google_compute_instance.no`** | **As 3 VMs** | Um único bloco com `for_each = var.nos`: o Terraform cria uma VM para cada item do mapa `nos` |

Detalhes importantes do bloco das VMs:
- `access_config {}` dá um IP externo **só para saída** (baixar pacotes, Tailscale). Nenhuma regra de firewall libera entrada da internet.
- `metadata.startup-script` recebe o `bootstrap.sh.tftpl` já preenchido com usuário, hostname e auth key.
- `block-project-ssh-keys = true`: nenhuma chave SSH no metadata; o acesso é pelo Tailscale SSH (K20).
- `shielded_instance_config` liga o Secure Boot.
- `desired_status` usa a variável `ligado` para parar ou ligar as VMs.

### `bootstrap.sh.tftpl`: o que acontece dentro da VM

É um *template* (`.tftpl`): o Terraform substitui `${usuario}`, `${hostname}`, `${tailscale_auth_key}` e `${tailscale_tag}` antes de enviar. Na VM, o **Google guest agent** executa esse script a cada boot. O script:

1. cria o usuário `lab` com `sudo` sem senha (se ainda não existir);
2. instala o Tailscale (se ainda não estiver instalado);
3. registra o nó na tailnet com a tag `tag:k8s-lab` e o Tailscale SSH ligado (se ainda não estiver registrado).

> Inicialmente isso foi escrito como *cloud-init*, que as imagens Debian da GCP **não têm**. Ver [incidente 001](incidentes/001-cloud-init-debian-gcp.md).

### `outputs.tf`: o resultado

No fim do `apply`, mostra o IP interno de cada nó e como acessá-lo.

### `terraform.tfvars` e `terraform.tfvars.example`

O `.example` é o modelo versionado. O `terraform.tfvars` real tem o ID do projeto e a auth key, fica com permissão `600` (só seu usuário lê) e está no `.gitignore`.

## Fluxo completo: do comando à VM na tailnet

```
terraform apply
   │
   ├─► API da GCP cria: VPC → subnet → firewall → conta de serviço → 3 VMs
   │
   └─► cada VM liga
         └─► Google guest agent executa o startup-script (bootstrap.sh)
               ├─► cria o usuário "lab"
               ├─► instala o Tailscale
               └─► tailscale up --auth-key=... --advertise-tags=tag:k8s-lab --ssh
                     └─► nó aparece na tailnet → ssh lab@cp-1 funciona
```

## Comandos executados

```bash
cd ~/repositorios/k8s-lab/terraform

# 1. valores: modelo → arquivo real (projeto preenchido do gcloud; auth key colada por você)
cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars

# 2. baixa o provider google para .terraform/ e confere o .terraform.lock.hcl
terraform init

# 3. mostra o que seria criado e salva o plano em um arquivo
terraform plan -out=lab.tfplan
#    → Plan: 9 to add, 0 to change, 0 to destroy

# 4. executa exatamente o plano revisado
terraform apply lab.tfplan
#    → Apply complete! Resources: 9 added

# 5. (incidente 001) correção do bootstrap e das permissões
terraform plan -out=lab.tfplan     # → 2 to add, 3 to change (metadata no lugar)
terraform apply lab.tfplan
gcloud compute instances reset cp-1 worker-1 worker-2 --zone us-central1-a

# conferir o que o Terraform gerencia
terraform state list
terraform output
```

> Usar `plan -out` + `apply <arquivo>` garante que o que é aplicado é **exatamente** o que foi revisado, mesmo que algo mude entre um comando e outro.

## Recursos gerenciados hoje (`terraform state list`)

```
google_compute_firewall.iap_ssh
google_compute_firewall.interno
google_compute_firewall.tailscale
google_compute_instance.no["cp-1"]
google_compute_instance.no["worker-1"]
google_compute_instance.no["worker-2"]
google_compute_network.lab
google_compute_subnetwork.nos
google_project_iam_member.nos["roles/logging.logWriter"]
google_project_iam_member.nos["roles/monitoring.metricWriter"]
google_service_account.nos
```

## Operações do dia a dia

| Quero... | Comando |
|---|---|
| Ver o que mudaria | `terraform plan` |
| Parar as VMs (economizar) | `ligado = false` no `terraform.tfvars` → `terraform apply` |
| Ligar de novo | `ligado = true` → `terraform apply` |
| Trocar o tipo de uma VM | editar `nos` em `variables.tf` (ou sobrescrever no tfvars) → `terraform apply` |
| Destruir tudo (fim do lab) | `terraform destroy` |

> O `terraform.tfstate` é a memória do Terraform: se ele for apagado, o Terraform "esquece" que os recursos existem e tentaria criá-los de novo. Não apague, e não versione (tem a auth key em texto puro).
