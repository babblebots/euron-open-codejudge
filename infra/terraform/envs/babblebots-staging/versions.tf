# Babblebots staging: Euron on one EC2 machine, as cheaply as possible.
# Everything (api, worker, web, one judge, Postgres, Redis, Caddy) runs as
# containers on the machine. See babblebots-monolith
# docs/integrations/Euron_code_judge/stories/v1-epic-4-deployment.md.
terraform {
  required_version = ">= 1.9"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  backend "s3" {
    bucket       = "babblebots-euron-tfstate-075008447270"
    key          = "staging/terraform.tfstate"
    region       = "ap-south-1"
    profile      = "staging"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = "ap-south-1"
  profile             = "staging"
  allowed_account_ids = ["075008447270"] # refuses to run against production
  default_tags {
    tags = { project = "euron", env = "staging", managed_by = "terraform" }
  }
}
