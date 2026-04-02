//Région
variable "aws_region" {
  description = "Région AWS cible"
  type        = string
  default     = "eu-north-1"
}

//Réseau
variable "twotiers_vpc" {
  description = "CIDR du VPC principal"
  type        = string
  default     = "10.0.0.0/16"
}

variable "twotiers_subnet_public1_eu_north_1a" {
  description = "CIDR du subnet public eu-north-1a"
  type        = string
  default     = "10.0.1.0/24"
}

variable "twotiers_subnet_private1_eu_north_1a" {
  description = "CIDR du subnet privé A eu-north-1a"
  type        = string
  default     = "10.0.3.0/24"
}

variable "twotiers_subnet_private2_eu_north_1b" {
  description = "CIDR du subnet privé B eu-north-1b"
  type        = string
  default     = "10.0.4.0/24"
}

//Base de données
variable "db_username" {
  description = "Utilisateur admin RDS"
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "Mot de passe RDS"
  type        = string
  sensitive   = true
  default     = "12345678"
}

variable "db_name" {
  description = "Nom de la base de données"
  type        = string
  default     = "guestbook"
}

//Calcul
variable "ssh_key_name" {
  description = "Nom de la Key Pair AWS pour SSH"
  type        = string
  default     = "stdkeys"
}
