locals {
  name     = "euron-staging"
  hostname = "code-staging.babblebots.ai"
  images   = ["euron-api", "euron-judge", "euron-web"]
  # Generated here, read by the machine at boot. Names only appear in docs.
  secrets = ["SESSION_SECRET", "INVITE_TOKEN_PEPPER", "JUDGE_TOKEN", "LOCAL_MASTER_KEY",
  "POSTGRES_PASSWORD", "CODEJUDGE_ADMIN_PASSWORD"]
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" { state = "available" }
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# ── network: its own VPC, no peering, no route to anything Babblebots ─────────
resource "aws_vpc" "this" {
  cidr_block           = "10.40.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.40.0.0/24"
  availability_zone = "ap-south-1b" # zone a had no t4g.medium capacity on 20 Nov
  tags              = { Name = "${local.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# HTTPS for the API; 80 only so Caddy can get/renew its certificate and
# redirect. No SSH: admin access is SSM Session Manager.
resource "aws_security_group" "machine" {
  name        = local.name
  description = "Euron staging machine: HTTPS in, 80 for ACME and redirect"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = local.name }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.machine.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.machine.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.machine.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ── images, test files, secrets, logs ────────────────────────────────────────
resource "aws_ecr_repository" "image" {
  for_each             = toset(local.images)
  name                 = each.key
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "image" {
  for_each   = aws_ecr_repository.image
  repository = each.value.name
  policy = jsonencode({ rules = [{
    rulePriority = 1, description = "keep the last 5 images",
    selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 },
    action       = { type = "expire" }
  }] })
}

resource "aws_s3_bucket" "objects" {
  bucket = "babblebots-${local.name}-objects"
}

resource "aws_s3_bucket_versioning" "objects" {
  bucket = aws_s3_bucket.objects.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "objects" {
  bucket = aws_s3_bucket.objects.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "objects" {
  bucket                  = aws_s3_bucket.objects.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ponytail: SSM SecureString (free) rather than Secrets Manager ($0.40 each);
# the values also sit in the Terraform state, which is why that bucket is
# private and encrypted. Move to Secrets Manager with rotation for production.
resource "random_password" "secret" {
  for_each = toset(local.secrets)
  length   = 48
  special  = false
}

resource "aws_ssm_parameter" "secret" {
  for_each = toset(local.secrets)
  name     = "/${local.name}/${each.key}"
  type     = "SecureString"
  value    = random_password.secret[each.key].result
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/euron/staging"
  retention_in_days = 14
}

# ── the machine's role: only Euron's own things ──────────────────────────────
resource "aws_iam_role" "machine" {
  name = local.name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole",
    Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.machine.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "machine" {
  name = local.name
  role = aws_iam_role.machine.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      { Effect = "Allow",
        Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"],
      Resource = [for r in aws_ecr_repository.image : r.arn] },
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.objects.arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      Resource = "${aws_s3_bucket.objects.arn}/*" },
      { Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"],
      Resource = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${local.name}/*" },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"],
      Resource = "${aws_cloudwatch_log_group.this.arn}:*" },
    ]
  })
}

resource "aws_iam_instance_profile" "machine" {
  name = local.name
  role = aws_iam_role.machine.name
}

# ── the machine ──────────────────────────────────────────────────────────────
resource "aws_instance" "machine" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.machine.id]
  iam_instance_profile        = aws_iam_instance_profile.machine.name
  associate_public_ip_address = true

  # IMDSv2 only. Hop limit 2 because the api container needs the role for S3;
  # the judge's container network is blocked from the metadata address by a
  # host firewall rule the bootstrap installs (DOCKER-USER chain).
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 40
    encrypted   = true
    tags        = { Name = local.name, snapshot = "nightly" }
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    dnf install -y docker
    systemctl enable --now docker
    mkdir -p /usr/local/lib/docker/cli-plugins /opt/euron
    curl -fsSL "https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-linux-aarch64" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  EOT

  lifecycle { ignore_changes = [ami, user_data] } # a new AMI must not replace the machine
  tags = { Name = local.name }
}

resource "aws_eip" "machine" {
  domain   = "vpc"
  instance = aws_instance.machine.id
  tags     = { Name = local.name }
}

# ── nightly disk snapshot, kept 3 days (staging data is re-seedable) ─────────
resource "aws_iam_role" "dlm" {
  name = "${local.name}-dlm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole",
    Principal = { Service = "dlm.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "nightly" {
  description        = "Euron staging nightly snapshot"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"
  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { snapshot = "nightly" }
    schedule {
      name = "nightly"
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["20:30"] # 02:00 IST
      }
      retain_rule { count = 3 }
      copy_tags = true
    }
  }
}
