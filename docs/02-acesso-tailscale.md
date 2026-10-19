# 02 — Acesso aos nós pelo Tailscale

Nenhuma porta dos nós está aberta para a internet. O PC de administração chega até eles **somente pela tailnet** (rede privada do Tailscale). Este documento explica as peças que tornam isso possível.

## As peças

| Peça | O que é | Para que serve no lab |
|---|---|---|
| **Tailnet** | A rede privada formada pelos seus dispositivos no Tailscale | PC e nós se enxergam como se estivessem na mesma rede |
| **Tag** (`tag:k8s-lab`) | Uma "identidade de grupo" dada a dispositivos que não são de uma pessoa | As regras de acesso valem para "todos os nós do lab", não nó a nó; nós com tag não expiram |
| **ACL / política** | Arquivo de regras da tailnet (quem acessa o quê) | Define quem pode usar a tag e quem pode fazer SSH nos nós |
| **Auth key** | Chave que registra um dispositivo na tailnet sem login interativo | Os nós entram na tailnet sozinhos no primeiro boot |
| **Tailscale SSH** | SSH autenticado pela identidade da tailnet, sem chaves SSH | `ssh lab@cp-1` funciona sem gerenciar `authorized_keys` (K20) |
| **MagicDNS** | DNS da tailnet | Os nós são acessados pelo nome (`cp-1`), não pelo IP `100.x` |

## Passo 1: política da tailnet (feito por você)

Em https://login.tailscale.com/admin/acls, na política da tailnet:

```jsonc
"tagOwners": {
  // quem pode atribuir a tag aos dispositivos: os administradores da tailnet
  "tag:k8s-lab": ["autogroup:admin"]
},
"ssh": [
  // administradores podem fazer SSH nos nós do lab, como "lab" ou "root"
  {"action": "accept", "src": ["autogroup:admin"], "dst": ["tag:k8s-lab"], "users": ["lab", "root"]}
]
```

- `tagOwners` é obrigatório: sem ele, nenhuma chave pode aplicar `tag:k8s-lab`.
- A regra `ssh` com `"action": "accept"` libera o SSH direto. A alternativa `"check"` pede reautenticação no navegador periodicamente, o que atrapalharia o Ansible.

## Passo 2: auth key (feito por você)

Em **Settings → Keys → Generate auth key**:

| Opção | Valor | Por quê |
|---|---|---|
| Reusable | ✅ | Uma única key registra os 3 nós |
| Ephemeral | ❌ | Nós efêmeros somem da tailnet quando a VM é desligada (K21) |
| Pre-approved | ✅ | Os nós entram sem aprovação manual no painel |
| Tags | `tag:k8s-lab` | Os nós já entram com a tag (e as regras de SSH valem) |
| Expiração | 1 dia | A key só serve para o registro inicial; depois fica inútil |

A key foi colada na linha `tailscale_auth_key` do `terraform/terraform.tfvars` (ver [01-terraform.md](01-terraform.md)).

## Passo 3: registro automático dos nós

Feito pelo `startup-script` (`terraform/bootstrap.sh.tftpl`) no boot de cada VM:

```bash
curl -fsSL https://tailscale.com/install.sh | sh     # instala o Tailscale
tailscale up \
  --auth-key=<key> \             # registra sem login interativo
  --hostname=cp-1 \              # nome do nó na tailnet (e no MagicDNS)
  --advertise-tags=tag:k8s-lab \ # entra com a tag
  --ssh                          # liga o Tailscale SSH
```

Resultado (cerca de 50 s após o boot):

```
cp-1      online  [tag:k8s-lab]  100.94.x.x
worker-1  online  [tag:k8s-lab]  100.86.x.x
worker-2  online  [tag:k8s-lab]  100.68.x.x
```

## Passo 4: acessar

```bash
tailscale status          # os 3 nós aparecem online
ssh lab@cp-1              # Tailscale SSH: sem chave, sem senha
ssh lab@cp-1 sudo -n true # sudo sem senha (configurado pelo bootstrap)
```

Na primeira conexão, o SSH pergunta se confia na chave do host; isso é normal.

## Passo 5: depois do registro (você)

**Revogue a auth key** em Settings → Keys. Os nós já registrados continuam funcionando; a key só é usada para registrar dispositivos novos, e ela continua gravada no state do Terraform e no metadata das VMs até expirar.

## Acesso de emergência (se o Tailscale falhar)

A regra de firewall `lab-iap-ssh` permite SSH vindo apenas do serviço IAP do Google:

```bash
gcloud compute ssh lab@cp-1 --zone us-central1-a --tunnel-through-iap
```

O IAP autentica pela sua conta Google; o `gcloud` cria uma chave SSH temporária para a sessão.
