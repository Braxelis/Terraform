//web_sg : HTTP + SSH public
resource "aws_security_group" "web_sg" {
  name        = "web_sg"
  description = "Acces HTTP et SSH public vers EC2 Web"
  vpc_id      = aws_vpc.twotiers.id

  ingress {
    description = "HTTP depuis Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH depuis Internet"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "web_sg" }
}

// ec2-rds-1 : SG attaché à EC2
resource "aws_security_group" "ec2_rds_1" {
  name        = "ec2-rds-1"
  description = "Sortie MariaDB (3306) depuis EC2 vers RDS"
  vpc_id      = aws_vpc.twotiers.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "ec2-rds-1" }
}

// rds-ec2-1 : SG attaché à RDS
resource "aws_security_group" "rds_ec2_1" {
  name        = "rds-ec2-1"
  description = "Entree MariaDB (3306) depuis ec2-rds-1"
  vpc_id      = aws_vpc.twotiers.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "rds-ec2-1" }
}

// Règle croisée : EC2 → RDS sortant port 3306
resource "aws_security_group_rule" "ec2_to_rds_egress" {
  type                     = "egress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ec2_rds_1.id
  source_security_group_id = aws_security_group.rds_ec2_1.id
  description              = "MariaDB sortant vers RDS"
}

// Règle croisée : RDS ← EC2 entrant port 3306
resource "aws_security_group_rule" "rds_from_ec2_ingress" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_ec2_1.id
  source_security_group_id = aws_security_group.ec2_rds_1.id
  description              = "MariaDB entrant depuis EC2"
}