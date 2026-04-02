data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "web" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  key_name                    = var.ssh_key_name

  vpc_security_group_ids = [
    aws_security_group.web_sg.id,
    aws_security_group.ec2_rds_1.id,
  ]

  user_data = <<-EOF
    #!/bin/bash
    wget -q https://gitea.newkube.ia86.cc/Nicolas_Horde/Formation_Cloud_demo1/raw/branch/main/install_flask_app.sh \
      -O /tmp/install.sh
    chmod +x /tmp/install.sh
    bash /tmp/install.sh
  EOF

  user_data_replace_on_change = true

  tags = {
    Name = "ec2-web"
  }
}
