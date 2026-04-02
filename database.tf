//subnet group
resource "aws_db_subnet_group" "dbnet" {
  name        = "dbnet"
  description = "DB Subnet Group pour RDS MariaDB"
  subnet_ids  = [
    aws_subnet.private_a.id,  
    aws_subnet.private_b.id,  
  ]

  tags = {
    Name = "dbnet"
  }
}

//instance rds
resource "aws_db_instance" "db" {
  identifier        = "db"
  engine            = "mariadb"
  engine_version    = "10.11"
  instance_class    = "db.t4g.micro" 
  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = var.db_name      
  username = var.db_username  
  password = var.db_password  

  db_subnet_group_name   = aws_db_subnet_group.dbnet.name
  vpc_security_group_ids = [
    aws_security_group.rds_ec2_1.id,  
  ]

  publicly_accessible = false  
  skip_final_snapshot = true   
  deletion_protection = false  

  tags = {
    Name = "rds-mariadb-db"
  }
}
