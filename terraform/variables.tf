variable "projeto" {
  description = "ID do projeto GCP (fica só no terraform.tfvars, fora do Git)."
  type        = string
}

variable "regiao" {
  type    = string
  default = "us-central1"
}

variable "zona" {
  description = "Todos os nós na mesma zona: tráfego interno sem custo."
  type        = string
  default     = "us-central1-a"
}

variable "nos" {
  description = "Nós do cluster: nome => tipo de máquina."
  type        = map(string)
  default = {
    "cp-1"     = "e2-standard-4" # control plane + monitoring
    "worker-1" = "e2-standard-2"
    "worker-2" = "e2-standard-2"
  }
}

variable "disco_gb" {
  type    = number
  default = 30
}

variable "imagem" {
  description = "Família de imagem do SO."
  type        = string
  default     = "debian-cloud/debian-13"
}

variable "usuario_admin" {
  description = "Usuário criado nos nós (sudo sem senha), acessado via Tailscale SSH."
  type        = string
  default     = "lab"
}

variable "tailscale_auth_key" {
  description = "Auth key reutilizável, pré-autorizada, com tag:k8s-lab e validade curta (K21)."
  type        = string
  sensitive   = true
}

variable "tailscale_tag" {
  type    = string
  default = "tag:k8s-lab"
}

variable "ligado" {
  description = "false para parar as VMs (discos continuam cobrando; vCPU/RAM não)."
  type        = bool
  default     = true
}
