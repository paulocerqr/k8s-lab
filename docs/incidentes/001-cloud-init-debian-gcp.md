# Incidente 001 — Nós não entraram na tailnet (cloud-init ausente no Debian da GCP)

## Contexto e impacto

Primeiro `terraform apply` do lab, em 17/10/2026. As 3 VMs subiram, mas nenhuma apareceu na tailnet depois de 3 minutos. Sem Tailscale, não havia acesso aos nós (SSH público fechado por desenho). Nenhum dado afetado: VMs recém-criadas.

## Diagnóstico

A saída do console serial (`gcloud compute instances get-serial-port-output cp-1`) não tinha nenhuma linha do `cloud-init`. Só apareciam o `google_guest_agent` e erros de permissão de log.

**Causa:** as imagens Debian publicadas pelo Google (`debian-cloud`) **não incluem cloud-init**; quem executa a configuração inicial é o Google guest agent, que lê a chave de metadata `startup-script`. A chave `user-data` (usada pelo cloud-init, presente nas imagens Ubuntu) era simplesmente ignorada.

Achado secundário: a conta de serviço dos nós foi criada sem nenhum papel, e o guest agent registrava `Permission 'logging.logEntries.create' denied` continuamente, poluindo o console.

## Correção

- `cloud-init.yaml.tftpl` substituído por `bootstrap.sh.tftpl`, passado como `startup-script`. Como roda a **cada boot**, o script é idempotente: só cria o usuário, instala e registra o Tailscale se ainda não estiver feito.
- Conta de serviço com os papéis mínimos recomendados para VMs: `roles/logging.logWriter` e `roles/monitoring.metricWriter`.
- `terraform apply` (metadata atualizado no lugar, sem recriar VMs) + `gcloud compute instances reset` para o script rodar.

## Validação

Os 3 nós entraram na tailnet com `tag:k8s-lab` cerca de 50 s após o reset. Tailscale SSH com o usuário `lab` e `sudo` sem senha funcionando nos três.

## Aprendizado

- Verificar o mecanismo de bootstrap **da imagem escolhida** antes de escrevê-lo: cloud-init é padrão no Ubuntu, não no Debian da GCP.
- O console serial é o primeiro lugar para olhar quando uma VM sem acesso de rede "não faz nada".
- Uma conta de serviço sem papéis é menor privilégio demais: o agente de logs do próprio Google precisa de `logWriter`.
