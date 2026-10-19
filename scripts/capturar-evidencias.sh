#!/usr/bin/env bash
# Captura a saída dos comandos de verificação do lab como evidência, já higienizada.
#
#   scripts/capturar-evidencias.sh docs/evidencias/semana-1/saidas
#
# Cada arquivo .txt começa com o comando executado ("$ ...") seguido da saída.
# O nome da tailnet, o ID do projeto GCP, IPs públicos e da tailnet e qualquer
# auth key são mascarados antes de gravar: nada sensível chega ao disco.
set -euo pipefail

DESTINO=${1:?uso: $0 <pasta-de-destino>}
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$DESTINO"
DESTINO=$(cd "$DESTINO" && pwd)
cd "$RAIZ"

export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/k8s-lab.conf}

TAILNET=$(tailscale status --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["MagicDNSSuffix"])')
PROJETO=$(gcloud config get-value project 2>/dev/null)

higienizar() {
  sed -E \
    -e "s/${TAILNET//./\\.}/<tailnet>.ts.net/g" \
    -e "s/${PROJETO}/<projeto>/g" \
    -e 's/\b100\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}\b/100.\1.x.x/g' \
    -e 's/tskey-[A-Za-z0-9_-]+/tskey-<mascarado>/g' \
    -e 's/(--token )[a-z0-9]{6}\.[a-z0-9]{16}/\1<token>/g' \
    -e 's/sha256:[0-9a-f]{64}/sha256:<hash>/g' \
    -e 's/\x1b\[[0-9;]*m//g' \
    -e 's/[[:space:]]+$//'
}

# capturar <arquivo> <comando exibido> [comando executado]
capturar() {
  local arquivo=$1 exibido=$2 executado=${3:-$2}
  echo "→ $arquivo"
  { echo "\$ $exibido"; bash -c "$executado" 2>&1 || true; } | higienizar > "$DESTINO/$arquivo.txt"
}

# ---------- infraestrutura
capturar 01-terraform-state "terraform -chdir=terraform state list"
capturar 02-terraform-output "terraform -chdir=terraform output"
capturar 03-gcloud-vms \
  "gcloud compute instances list" \
  "gcloud compute instances list --format='table(name,zone.basename(),machineType.basename(),status,networkInterfaces[0].networkIP:label=INTERNAL_IP)'"
capturar 04-gcloud-firewall \
  "gcloud compute firewall-rules list --filter=network=lab" \
  "gcloud compute firewall-rules list --filter=network=lab --format='table(name,sourceRanges.list():label=ORIGEM,allowed[].map().firewall_rule().list():label=PERMITE)'"

# ---------- acesso
capturar 05-tailscale-status \
  "tailscale status | grep -E 'cp-1|worker-'" \
  "tailscale status | grep -E 'cp-1|worker-'"
capturar 06-nos-versoes \
  "for n in cp-1 worker-1 worker-2; do ssh lab@\$n 'SO, kernel, CPU, RAM e versões'; done" \
  "for n in cp-1 worker-1 worker-2; do ssh -o BatchMode=yes lab@\$n 'printf \"%-9s %s | kernel %s | %s vCPU | %s MB | containerd %s | kubeadm %s | kubelet %s\n\" \"\$(hostname)\" \"\$(. /etc/os-release; echo \$PRETTY_NAME)\" \"\$(uname -r)\" \"\$(nproc)\" \"\$(free -m | awk \"/Mem/{print \\\$2}\")\" \"\$(containerd --version | cut -d\" \" -f3)\" \"\$(kubeadm version -o short)\" \"\$(kubelet --version | cut -d\" \" -f2)\"'; done"

# ---------- cluster
capturar 07-kubectl-nodes "kubectl get nodes -o wide"
capturar 08-kubectl-pods "kubectl get pods -A -o wide"
capturar 09-cilium-status "kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief"
capturar 10-kubectl-version "kubectl version"

# ---------- teste de rede entre nós
capturar 11-teste-rede \
  "kubectl create deployment teste-rede ...; kubectl expose ...; kubectl run cliente ... wget http://teste-rede" \
  "kubectl create deployment teste-rede --image=nginx:1.29-alpine --replicas=2 \
   && kubectl rollout status deployment/teste-rede --timeout=120s \
   && kubectl expose deployment teste-rede --port 80 \
   && echo && kubectl get pods -l app=teste-rede -o wide \
   && echo && kubectl get service teste-rede \
   && echo && echo '\$ kubectl run cliente --rm -i --image=busybox:1.37 --restart=Never -- wget -qO- http://teste-rede | grep title' \
   && kubectl run cliente --rm -i --image=busybox:1.37 --restart=Never -- wget -qO- http://teste-rede 2>/dev/null | grep -o '<title>.*</title>' | head -1; \
   kubectl delete deployment,service teste-rede >/dev/null"

# ---------- Ansible: execução real contra o cluster (prova de idempotência: changed=0)
capturar 12-ansible-site \
  "cd ansible && ansible-playbook site.yml" \
  "cd ansible && ANSIBLE_NOCOLOR=1 ansible-playbook site.yml"
# recorte só com o resumo (PLAY RECAP + tempos), para a imagem
sed -n '1p;/^PLAY RECAP/,$p' "$DESTINO/12-ansible-site.txt" > "$DESTINO/13-ansible-recap.txt"

echo "evidências gravadas em $DESTINO"
