provider "aws" {
    region = "us-east-2"
}

// VPC
resource "aws_vpc" "my_vpc" {
    cidr_block = "10.1.0.0/16"

    tags = {
        Name = "My VPC Tech Challenge"
    }
}

// Security Groups 
resource "aws_security_group" "project_sg" {
    name = "project_sg"
    vpc_id = "${aws_vpc.my_vpc.id}"

    ingress {
        description = "SSH"
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
        ipv6_cidr_blocks = ["::/0"]
    }

    ingress {
        description = "HTTP"
        from_port = 80
        to_port = 80
        protocol = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
        ipv6_cidr_blocks = ["::/0"]
    }

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
 
    tags = {
        Name = "project_sg"
    }
}

// Subnets
resource "aws_subnet" "public1" {
    vpc_id = "${aws_vpc.my_vpc.id}"
    cidr_block = "10.1.0.0/24"
    availability_zone = "us-east-2a"
    map_public_ip_on_launch = "true"

    tags = {
        Name = "public_subnet_1"
    }
}

resource "aws_subnet" "public2" {
    vpc_id = "${aws_vpc.my_vpc.id}"
    cidr_block = "10.1.1.0/24"
    availability_zone = "us-east-2b"
    map_public_ip_on_launch = "true"

    tags = {
        Name = "public_subnet_2"
    }
}

resource "aws_subnet" "private1" {
    vpc_id = "${aws_vpc.my_vpc.id}"
    cidr_block = "10.1.2.0/24"
    availability_zone = "us-east-2a"

    tags = {
        Name = "private_subnet_1"
    }
}

resource "aws_subnet" "private2" {
    vpc_id = "${aws_vpc.my_vpc.id}"
    cidr_block = "10.1.3.0/24"
    availability_zone = "us-east-2b"

    tags = {
        Name = "private_subnet_1"
    }
}

// Internet Gateway to allow VPC to connect to internet
resource "aws_internet_gateway" "project_igw" {
    vpc_id = "${aws_vpc.my_vpc.id}"

    tags = {
        Name = "project_igw"
    }
}

// Route Table
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.my_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.project_igw.id
  }
  tags = {
    Name = "public-route-table"
  }
}

resource "aws_route_table_association" "public_rt_assoc" {
  subnet_id      = aws_subnet.public2.id
  route_table_id = aws_route_table.public_route_table.id
}

// EC2 Red Hat Instance
resource "aws_instance" "my_ec2" {
    ami           = "ami-078cbc4c2d057c244"
    instance_type = "t2.micro"
    key_name = "my-ec2-key"
    vpc_security_group_ids = [ "${aws_security_group.project_sg.id}" ]
    subnet_id     = aws_subnet.public2.id
    associate_public_ip_address = true

    root_block_device {
        volume_size = 20
    }

    tags = {
        Name = "Project-EC2-Instance"
    }
}

// Auto scaling group that spreads out instances across subnets sub3 and sub4
// Set up red hat linux AMI
data "aws_ami" "redhat_ami" {
  most_recent = true
  filter {
    name   = "name"
    values = ["RHEL-9.0.0_HVM-20220513-x86_64-0-Hourly2-GP2"]
  }
  owners = ["309956199498"]
}

// Launch Template - uses the AMI & sets up 20GB storage & scripts install
resource "aws_launch_template" "asg_launch_temp" {
  name          = "asg_launch_temp"
  image_id      = data.aws_ami.redhat_ami.id
  instance_type = "t2.micro"

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size = 20
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
        Name = "asg_launch_temp"
    }
  }

    // Script install of Apache Web Server
    user_data = base64encode(<<-EOF
              #!/bin/bash
              sudo yum update -y
              sudo yum install -y httpd
              sudo systemctl start httpd
              sudo systemctl enable httpd
              EOF
    )
}

// Auto-scaling group using the launch Configuration
resource "aws_autoscaling_group" "project_asg" {
    min_size             = 2
    max_size             = 6
    vpc_zone_identifier  = [aws_subnet.private1.id, aws_subnet.private2.id]

    target_group_arns = [aws_lb_target_group.project_tg.arn]

    launch_template {
        id = aws_launch_template.asg_launch_temp.id
        version = aws_launch_template.asg_launch_temp.latest_version
    }

    tag {
        key                 = "Name"
        value               = "ASG Instance"
        propagate_at_launch = true
    }
}

// 1 S3 bucket with two folders "Images" and "Logs"
resource "aws_s3_bucket" "proj_bucket" {
  bucket = "project-bucket-id1824"
  acl    = "private"
}

resource "aws_s3_bucket_object" "image_folder" {
    bucket = aws_s3_bucket.proj_bucket.bucket
    acl = "private"
    key = "Images/"
    source = "/dev/null"
}

resource "aws_s3_bucket_object" "logs_folder" {
    bucket = aws_s3_bucket.proj_bucket.bucket
    acl = "private"
    key = "Logs/"
    source = "/dev/null"
}



// Lifecycle rules for folders
resource "aws_s3_bucket_lifecycle_configuration" "bucket_lifecycle" {
    bucket = aws_s3_bucket.proj_bucket.id

    rule {
        id = "ImagesLifecycle"
        status = "Enabled"
        prefix = "Images/"

        transition {
            days = 90
            storage_class = "GLACIER"
        }
    }

    rule {
        id      = "LogsLifecycle"
        status  = "Enabled"
        prefix  = "Logs/"

        expiration {
            days = 90
        }
    }
}

// Load Balancer
// Set up target group
resource "aws_lb_target_group" "project_tg" {
  name     = "project-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.my_vpc.id
}

// Set up load Balancer
resource "aws_lb" "project_alb" {
    name = "project-alb"
    internal = false
    load_balancer_type = "application"
    security_groups = [aws_security_group.project_sg.id]
    subnets = [aws_subnet.private1.id, aws_subnet.private2.id]

    enable_deletion_protection = false

    tags = {
        Name = "project-alb"
    }
}

// Set up Listener
resource "aws_lb_listener" "alb_listener" {
    load_balancer_arn = aws_lb.project_alb.arn
    port = "80"
    protocol = "HTTP"

    default_action {
        type = "forward"
        target_group_arn = aws_lb_target_group.project_tg.arn
    }
}








