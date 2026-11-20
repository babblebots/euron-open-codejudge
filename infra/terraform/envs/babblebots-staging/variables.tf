variable "instance_type" {
  description = "ARM64 machine for everything. t4g.medium fits one judge with lowered ceilings; t4g.large runs the fork's judge settings unchanged."
  type        = string
  default     = "t4g.medium"
}
