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

# ---------- identidade dos nós: só os papéis mínimos recomendados para VMs
# (escrita de logs e métricas). Outros papéis entram quando algo precisar
# (ex.: GCE PD CSI driver na Fase E).

resource "google_service_account" "nos" {
  account_id   = "k8s-lab-nos"
  display_name = "Nós do k8s-lab"
}

resource "google_project_iam_member" "nos" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.metricWriter"])

  project = var.projeto
  role    = each.value
  member  = "serviceAccount:${google_service_account.nos.email}"
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
}
