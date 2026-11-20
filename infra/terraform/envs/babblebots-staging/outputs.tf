output "public_ip" {
  description = "Namecheap A record: code-staging -> this address."
  value       = aws_eip.machine.public_ip
}
output "hostname" { value = local.hostname }
output "instance_id" { value = aws_instance.machine.id }
output "ecr_registry" {
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.region}.amazonaws.com"
}
output "objects_bucket" { value = aws_s3_bucket.objects.bucket }
output "secret_parameter_names" { value = [for p in aws_ssm_parameter.secret : p.name] }
