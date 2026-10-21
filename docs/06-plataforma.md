# 06 — Plataforma: volumes persistentes e segredos no Git

Dois componentes que as aplicações vão precisar: onde guardar dados que sobrevivem ao pod (**local-path-provisioner**) e como versionar senhas e tokens sem expô-los (**Sealed Secrets**). Os dois são instalados pelo `ansible/playbooks/08-plataforma.yml`.

## local-path-provisioner: volumes no disco do nó

| Conceito | O que é |
|---|---|
| **PersistentVolumeClaim (PVC)** | O pedido de um app: "quero 1 GiB de disco" |
| **PersistentVolume (PV)** | O disco de fato, criado para atender o pedido |
| **StorageClass** | "Quem" cria os PVs e como. Aqui: `local-path`, a padrão do cluster |
| **local-path-provisioner** | Cria cada PV como uma pasta em `/opt/local-path-provisioner/` no nó onde o pod roda |

Limitação (K06): o volume fica **preso ao nó** onde foi criado. Se o nó cair, o pod que usa o volume não sobe em outro nó até o nó voltar. Para o lab, com backup do Postgres, é aceitável; o GCE PD CSI driver (disco da GCP que muda de nó) fica como evolução.

Versão fixa: `local_path_versao` em `ansible/group_vars/all/main.yml` (manifesto oficial da release).

### Teste (21/10/2026)

Um PVC de 1 GiB; um pod grava um arquivo e é apagado; um pod novo monta o mesmo PVC e lê o arquivo.

```
escritor: ok | PVC: Bound
leitura no pod novo, depois de apagar o escritor: gravado-as-135556
pasta no nó: pvc-67c5a1c8-..._teste-plat_dados        (em /opt/local-path-provisioner/ do worker-1)
```

## Sealed Secrets: segredos cifrados que podem ir para o Git

O problema: os manifestos do cluster ficam no Git (público), mas um `Secret` do Kubernetes guarda os valores só em base64, que **não é cifragem**. O Sealed Secrets resolve com criptografia assimétrica:

```
seu PC                                          cluster
──────                                          ───────
Secret (texto puro, nunca vai ao Git)
   │  kubeseal (usa a chave PÚBLICA do cluster)
   ▼
SealedSecret (cifrado)  ── Git ──►  kubectl apply  ──►  controlador (chave PRIVADA)
                                                            │
                                                            ▼
                                                     Secret normal, usado pelos pods
```

Só o controlador, dentro do cluster, tem a chave privada que abre o `SealedSecret`. O arquivo cifrado pode ir para o repositório público.

| Peça | Onde |
|---|---|
| Controlador `sealed-secrets-controller` | namespace `kube-system`, manifesto oficial da release (`sealed_secrets_versao`) |
| `kubeseal` (cliente) | PC de administração, `~/.local/bin/kubeseal` (0.40.0, checksum conferido) |
| Cópia da chave privada | `~/.config/k8s-lab/sealed-secrets-chave.yaml` (pasta `700`, arquivo `600`, **fora do Git**) |

### Por que guardar uma cópia da chave

O controlador gera a chave privada **dentro do cluster** na primeira instalação. O lab é recriado do zero (teste de recriação, encerramento em novembro): um cluster novo geraria uma chave nova, e **todos os SealedSecrets do Git deixariam de abrir**. Por isso o playbook:

1. na **primeira instalação**, exporta a chave para o PC;
2. num **cluster recriado** (sem chave), restaura a cópia **antes** do controlador subir.

> Essa cópia é a "chave mestra" dos segredos do lab. Vale guardar uma segunda cópia fora do PC (ex.: gerenciador de senhas). Se ela se perder, os segredos não ficam expostos — só precisam ser selados de novo a partir dos valores originais.

### Como selar um segredo

```bash
export KUBECONFIG=~/.kube/k8s-lab.conf

# 1. gerar o Secret localmente (não vai para o Git; --dry-run não cria nada no cluster)
kubectl -n <namespace> create secret generic <nome> \
  --from-literal=CHAVE=valor --dry-run=client -o yaml > /tmp/segredo.yaml

# 2. selar com a chave pública do cluster
kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller \
  --format yaml < /tmp/segredo.yaml > apps/<app>/sealedsecret.yaml
rm /tmp/segredo.yaml

# 3. versionar e aplicar o arquivo selado
kubectl apply -f apps/<app>/sealedsecret.yaml
```

### Teste (21/10/2026)

```
o que vai para o Git:  senha: AgBbhWRiah1c+qZjCDd11g1kEQWZgm9JrFjWTowj0vqw...
texto puro no arquivo selado: 0
cluster decifrou: valor-de-teste-123
backup do PC decifra sozinho: valor-de-teste-123      (kubeseal --recovery-unseal)
```

O último teste prova que a cópia da chave funciona sem o cluster, que é o que garante as recriações.

## Idempotência

Rodar o playbook de novo termina com `changed=0`. Três ajustes foram necessários para isso:

| Tarefa | Problema | Solução |
|---|---|---|
| StorageClass padrão | `kubectl annotate` responde "annotated" mesmo sem mudar nada | Ler a anotação antes e só anotar se faltar |
| Controlador | `kubectl apply` desse manifesto sempre responde "configured" (o cluster completa campos do Deployment) | `kubectl diff` antes: só aplica se houver diferença real |
| Restaurar a chave | Restaurar num cluster que já tem chave não faz sentido | Só restaura quando o cluster não tem nenhuma chave |
