output "nos" {
  description = "Nós criados: nome => IP interno."
  value       = { for nome, vm in google_compute_instance.no : nome => vm.network_interface[0].network_ip }
}

output "acesso" {
  description = "Como acessar (depois que o nó aparecer na tailnet)."
  value       = "ssh ${var.usuario_admin}@<nó>  # Tailscale SSH; emergência: gcloud compute ssh <nó> --tunnel-through-iap"
}

output "bucket_backup" {
  value = google_storage_bucket.backup.name
}
