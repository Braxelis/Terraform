//VPC
resource "aws_vpc" "twotiers" {
  cidr_block           = var.twotiers_vpc
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "twotiers_vpc"
  }
}

//sous-réseaux
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.twotiers.id
  cidr_block              = var.twotiers_subnet_public1_eu_north_1a
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "twotiers_subnet_public1_eu_north_1a"
  }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.twotiers.id
  cidr_block        = var.twotiers_subnet_private1_eu_north_1a
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "twotiers_subnet_private1_eu_north_1a"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.twotiers.id
  cidr_block        = var.twotiers_subnet_private2_eu_north_1b
  availability_zone = "${var.aws_region}b"

  tags = {
    Name = "twotiers_subnet_private2_eu_north_1b"
  }
}

// passerelle internet
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.twotiers.id

  tags = {
    Name = "twotiers_igw"
  }
}

//table de routage publique
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.twotiers.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "twotiers_rt_public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

//table de routage privée
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.twotiers.id

  tags = {
    Name = "twotiers_rt_private"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}
