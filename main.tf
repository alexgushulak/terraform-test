
# Define variables
variable "AWS_ACCESS_KEY_ID" {
  description = "AWS Access Key ID"
}

variable "AWS_SECRET_ACCESS_KEY" {
  description = "AWS Secret Key"
}

variable "POSTGRES_DB_USER" {
  description = "DB Username"
}

variable "POSTGRES_DB_PASS" {
  description = "DB Password"
}

# Configure AWS provider
provider "aws" {
  region     = "us-east-1"
  access_key = var.AWS_ACCESS_KEY_ID
  secret_key = var.AWS_SECRET_ACCESS_KEY
}

# 1. Create VPC
resource "aws_vpc" "prod-vpc" {
  cidr_block = "10.0.0.0/16"
  tags       = {
    Name = "production"
  }
}

# 2. Create Internet Gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.prod-vpc.id
}

# 3. Create Route Table
resource "aws_route_table" "prod-route-table" {
  vpc_id = aws_vpc.prod-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "prod"
  }
}

# 4. Create Public Subnet
resource "aws_subnet" "public-subnet" {
  vpc_id                  = aws_vpc.prod-vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "prod-subnet"
  }
}

# 5. Create Private Subnet
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.prod-vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "private-subnet"
  }
}

resource "aws_subnet" "private_subnet2" {
  vpc_id            = aws_vpc.prod-vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name = "private-subnet2"
  }
}

# 6. Associate Public Subnet with Route Table
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public-subnet.id
  route_table_id = aws_route_table.prod-route-table.id
}

# 7. Create Web Server Security Group
resource "aws_security_group" "allow_web" {
  name        = "allow_web_traffic"
  description = "Allow Web inbound traffic"
  vpc_id      = aws_vpc.prod-vpc.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
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

  tags = {
    Name = "allow_WEB"
  }
}

# 8. Create RDS Security Group
resource "aws_security_group" "rds_sg" {
  name        = "rds_security_group"
  description = "Security group for RDS"
  vpc_id      = aws_vpc.prod-vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 9. Create Web Server Network Interface
resource "aws_network_interface" "web-server-nic" {
  subnet_id       = aws_subnet.public-subnet.id
  private_ips     = ["10.0.1.50"]
  security_groups = [aws_security_group.allow_web.id]
}

# 10. Create RDS Network Interface
resource "aws_network_interface" "rds-nic" {
  subnet_id       = aws_subnet.private_subnet.id
  private_ips     = ["10.0.2.51"]
  security_groups = [aws_security_group.rds_sg.id]
}

# 11. Create Elastic IP for Web Server
resource "aws_eip" "one" {
  domain                    = "vpc"
  network_interface         = aws_network_interface.web-server-nic.id
  associate_with_private_ip = "10.0.1.50"
  depends_on                = [aws_internet_gateway.gw]
}

# 12. Create Ubuntu Web Server Instance
resource "aws_instance" "web-server-instance" {
  ami                  = "ami-0c7217cdde317cfec"
  instance_type        = "t2.micro"
  availability_zone    = "us-east-1a"
  key_name             = "main-key"

  network_interface {
    device_index          = 0
    network_interface_id  = aws_network_interface.web-server-nic.id
  }

  user_data = <<-EOF
                #!/bin/bash
                sudo apt update -y
                sudo apt install apache2 -y
                sudo systemctl start apache2
                sudo bash -c 'echo your very first web server on AWS > /var/www/html/index.html'
              EOF

  tags = {
    Name = "web-server"
  }
}

# 13. Create RDS DB Subnet Group
resource "aws_db_subnet_group" "postgres_subnet_group" {
  name       = "postgres-subnet-group"
  subnet_ids = [aws_subnet.private_subnet.id, aws_subnet.private_subnet2.id]
}

# 14. Create RDS Security Group Rule
resource "aws_security_group_rule" "postgres_ingress" {
  security_group_id = aws_security_group.rds_sg.id
  type              = "ingress"
  from_port         = 5432  # PostgreSQL default port
  to_port           = 5432
  protocol          = "tcp"
  source_security_group_id = aws_security_group.allow_web.id
}

# 15. Associate RDS Network Interface with Ubuntu Web Server
resource "aws_network_interface_attachment" "rds_attachment" {
  instance_id          = aws_instance.web-server-instance.id
  device_index         = 1
  network_interface_id = aws_network_interface.rds-nic.id
}

# 17. Create PostgreSQL RDS instance
resource "aws_db_instance" "postgres_db" {
  identifier           = "prod-postgres-db"
  allocated_storage    = 20
  storage_type         = "gp2"
  engine               = "postgres"
  engine_version       = "15.4"
  instance_class       = "db.t3.micro"
  username             = var.POSTGRES_DB_USER
  password             = var.POSTGRES_DB_PASS
  publicly_accessible  = false
  multi_az             = false
  skip_final_snapshot  = true
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.postgres_subnet_group.name
}

# 16. Output the PostgreSQL RDS endpoint
output "postgres_endpoint" {
  value = aws_db_instance.postgres_db.endpoint
}

output "ubuntu_server" {
  value = aws_instance.web-server-instance.private_ip
}