output "ec2_public_ip" {
  description = "Adresse IP publique de l'instance EC2 Web"
  value       = aws_instance.web.public_ip
}

output "app_url" {
  description = "URL de l'application Guestbook"
  value       = "http://${aws_instance.web.public_ip}"
}

output "rds_endpoint" {
  description = "Endpoint de connexion RDS MariaDB"
  value       = aws_db_instance.db.address
}
