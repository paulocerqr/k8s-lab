locals {
  rotulos = {
    projeto        = "k8s-lab"
    gerenciado-por = "terraform"
  }
  faixa_subnet = "10.10.0.0/24"
  # faixa de origem do IAP TCP forwarding (acesso de emergência)
  faixa_iap = "35.235.240.0/20"
}

# ---------- rede (K19: VPC própria, começa fechada)

resource "google_compute_network" "lab" {
  name                    = "lab"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "nos" {
  name          = "lab-nos"
  network       = google_compute_network.lab.id
  ip_cidr_range = local.faixa_subnet
}

resource "google_compute_firewall" "interno" {
  name          = "lab-interno"
  network       = google_compute_network.lab.id
  description   = "Tráfego entre os nós: API server, kubelet, etcd, Cilium."
  source_ranges = [local.faixa_subnet]
  target_tags   = ["k8s-lab"]

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "tailscale" {
  name          = "lab-tailscale"
  network       = google_compute_network.lab.id
  description   = "Conexão direta do Tailscale (sem relay DERP)."
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["k8s-lab"]

  allow {
    protocol = "udp"
    ports    = ["41641"]
  }
}

resource "google_compute_firewall" "iap_ssh" {
  name          = "lab-iap-ssh"
  network       = google_compute_network.lab.id
  description   = "SSH de emergência via IAP, caso o Tailscale falhe."
  source_ranges = [local.faixa_iap]
  target_tags   = ["k8s-lab"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# ---------- identidade dos nós: papéis mínimos recomendados para VMs (logs e
# métricas) + o necessário para o GCE PD CSI driver (docs/11-discos-gerenciados.md)

resource "google_service_account" "nos" {
  account_id   = "k8s-lab-nos"
  display_name = "Nós do k8s-lab"
}

resource "google_project_iam_member" "nos" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/compute.storageAdmin", # PD CSI: criar, apagar e redimensionar discos
    # id montado à mão: o for_each precisa da chave já no plan
    "projects/${var.projeto}/roles/k8sLabPdCsi",
  ])

  project = var.projeto
  role    = each.value
  member  = "serviceAccount:${google_service_account.nos.email}"

  depends_on = [google_project_iam_custom_role.pd_csi]
}

# PD CSI: anexar/desanexar discos nas VMs. O script oficial do driver também dá
# roles/editor ao projeto; aqui fica só o papel customizado que ele define.
resource "google_project_iam_custom_role" "pd_csi" {
  role_id = "k8sLabPdCsi"
  title   = "k8s-lab: GCE PD CSI driver"
  permissions = [
    "compute.instances.get",
    "compute.instances.attachDisk",
    "compute.instances.detachDisk",
    "compute.disks.get",
  ]
}

# Anexar um disco a uma VM exige poder "agir como" a conta de serviço dela.
# Escopo: só a própria conta dos nós, não todas as contas do projeto.
resource "google_service_account_iam_member" "nos_usam_a_si_mesmos" {
  service_account_id = google_service_account.nos.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.nos.email}"
}

# ---------- VMs

resource "google_compute_instance" "no" {
  for_each = var.nos

  name           = each.key
  machine_type   = each.value
  zone           = var.zona
  tags           = ["k8s-lab"]
  labels         = merge(local.rotulos, { papel = startswith(each.key, "cp-") ? "control-plane" : "worker" })
  desired_status = var.ligado ? "RUNNING" : "TERMINATED"

  # Pods podem usar IPs que não são o da VM (roteamento nativo do Cilium, se adotado)
  can_ip_forward = true

  boot_disk {
    initialize_params {
      image  = var.imagem
      size   = var.disco_gb
      type   = "pd-balanced"
      labels = local.rotulos
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.nos.id
    # IP externo efêmero só para saída (pacotes, imagens, Tailscale);
    # nenhuma regra de firewall libera entrada pela internet
    access_config {}
  }

  metadata = {
    # Debian na GCP não tem cloud-init: o bootstrap é um startup-script
    startup-script = templatefile("${path.module}/bootstrap.sh.tftpl", {
      hostname           = each.key
      usuario            = var.usuario_admin
      tailscale_auth_key = var.tailscale_auth_key
      tailscale_tag      = var.tailscale_tag
    })
    # sem chaves SSH no metadata: o acesso é pelo Tailscale SSH (K20)
    block-project-ssh-keys = "true"
  }

  service_account {
    email  = google_service_account.nos.email
    scopes = ["cloud-platform"]
  }

  scheduling {
    on_host_maintenance = "MIGRATE"
    automatic_restart   = true
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  allow_stopping_for_update = true

  lifecycle {
    # discos dos PVCs são anexados pelo GCE PD CSI driver, fora do Terraform; sem isto
    # o próximo apply desanexaria o disco do Postgres com o banco rodando
    ignore_changes = [attached_disk]
  }
}

# ---------- backup do Postgres do Job Radar (docs/12-backup.md)
# CronJob diário envia pg_dump para cá com a conta dos nós. Só "criar objetos": quem
# invadir o cluster consegue gravar, mas não apagar nem sobrescrever backups antigos.

resource "google_storage_bucket" "backup" {
  name                        = "${var.projeto}-k8s-lab-backup" # nome global: prefixo do projeto
  location                    = var.regiao
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  # o backup final é baixado antes do encerramento (plano §7); depois disso o destroy
  # precisa conseguir apagar o bucket com o que restar dentro
  force_destroy = true

  lifecycle_rule {
    condition { age = 7 } # dias
    action { type = "Delete" }
  }

  labels = local.rotulos
}

resource "google_storage_bucket_iam_member" "nos_gravam_backup" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.nos.email}"
}
