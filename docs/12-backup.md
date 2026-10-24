# 12 — Backup do Postgres

Backup diário do banco do Job Radar num bucket do Google Cloud Storage, **fora do cluster e fora dos discos das VMs**: se o disco do Postgres, a VM ou o cluster inteiro sumirem, os dados voltam do bucket.

## Como funciona

```
03:00 (Brasília)  CronJob backup-postgres
  ├─ init "dump"  (postgres:16-alpine)  pg_dump -Fc → /backup/jobradar.dump → pg_restore -l confere
  └─ "enviar"     (curlimages/curl)     token da VM (metadados) → POST na API do GCS → confere o tamanho
                                                       │
                                gs://<projeto>-k8s-lab-backup/jobradar-<data UTC>.dump
                                apagado automaticamente com 7 dias
```

| Peça | Onde | Detalhe |
|---|---|---|
| Bucket | `terraform/main.tf` | Privado (`public_access_prevention`), `us-central1`, regra de ciclo de vida: apaga com 7 dias |
| Permissão | `terraform/main.tf` | `roles/storage.objectCreator` da conta dos nós, **só neste bucket** |
| CronJob | `apps/job-radar/backup.yaml` | Diário às 03:00, fora da janela de coleta; sem root, sistema de arquivos somente leitura |
| NetworkPolicy | `apps/job-radar/networkpolicy.yaml` | Pods `app: backup` liberados para o Postgres |

**Nenhuma chave guardada:** o token de acesso vem do servidor de metadados da VM, como no PD CSI ([11-discos-gerenciados.md](11-discos-gerenciados.md)). O nome do bucket também é montado a partir do ID do projeto lido dos metadados, para o ID não ficar no Git.

### Por que só "criar objetos"

Com `objectCreator`, o cluster **grava** backups novos mas **não lê, não apaga e não sobrescreve** os existentes. Se alguém tomar o cluster (ou um bug apagar dados e o próximo backup tentar "corrigir"), os backups dos dias anteriores continuam lá. Quem lê e restaura é o administrador, com a própria conta (`gcloud`).

## Testes (24/10/2026)

Evidência: [`15-backup-postgres.txt`](evidencias/semana-4/saidas/15-backup-postgres.txt).

| Teste | Resultado |
|---|---|
| Backup manual (`kubectl create job --from=cronjob/backup-postgres`) | 7 s; 249 KB, 13 tabelas; tamanho conferido com a resposta do GCS |
| **Restauração** num banco temporário (`restore_teste`) a partir do arquivo baixado do bucket | OK; 12 tabelas idênticas; `execucao_coleta` com 1 linha a menos: uma coleta rodou às 18:30, depois do backup das 18:29:59 |
| De dentro de um pod, com o token da VM: apagar, sobrescrever e ler o backup | **403** nos três; objeto intacto |

> Backup que nunca foi restaurado não é backup: o teste de restauração faz parte da entrega.

## Comandos

```bash
export KUBECONFIG=~/.kube/k8s-lab.conf
BK=$(cd terraform && terraform output -raw bucket_backup)

# backup agora, fora do horário
kubectl -n job-radar create job --from=cronjob/backup-postgres backup-$(date +%s)

# listar e baixar
gcloud storage ls -l gs://$BK/
gcloud storage cp gs://$BK/<arquivo>.dump ~/.config/k8s-lab/

# restaurar num banco temporário para conferir
kubectl -n job-radar exec postgres-0 -- psql -U jobradar -d jobradar -c "CREATE DATABASE restore_teste"
kubectl -n job-radar exec -i postgres-0 -- pg_restore -U jobradar -d restore_teste --no-owner < ~/.config/k8s-lab/<arquivo>.dump
kubectl -n job-radar exec postgres-0 -- psql -U jobradar -d jobradar -c "DROP DATABASE restore_teste"
```

Restaurar **por cima** do banco de produção (desastre): parar worker e CronJobs como na migração ([11-discos-gerenciados.md](11-discos-gerenciados.md#migração-do-postgres-24102026)), `pg_restore --clean --if-exists -d jobradar`, conferir e religar com o playbook.

## Achado: o Terraform ia desanexar o disco do Postgres

No primeiro `terraform plan` para criar o bucket, apareceu uma alteração **não pedida** no `worker-2`:

```
~ resource "google_compute_instance" "no" {
    - attached_disk {
        - device_name = "pvc-e2a83f75-..." -> null
```

O disco do Postgres foi anexado pelo PD CSI driver, por fora do Terraform. O Terraform trata o que não declarou como diferença a desfazer: o apply teria **desanexado o disco com o banco rodando**. Correção em `terraform/main.tf`:

```hcl
lifecycle {
  ignore_changes = [attached_disk]   # discos dos PVCs são do Kubernetes
}
```

Lição: em infraestrutura compartilhada entre ferramentas (Terraform cria a VM, o Kubernetes anexa discos nela), **cada campo precisa de um único dono**, e o `plan` precisa ser lido antes de todo `apply`.

## Encerramento

O backup final (plano §7) é o mais recente do bucket, baixado com `gcloud storage cp` antes do `terraform destroy`. O bucket tem `force_destroy`: o destroy o apaga **com o que houver dentro**.
