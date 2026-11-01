variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "ap-south-1" # Mumbai region
}

variable "project_name" {
  description = "Project name prefix for resources"
  type        = string
  default     = "voting-app-devops"
}

variable "instance_type" {
  description = "EC2 instance size"
  type        = string
  default     = "t3.small" # 2 vCPU, 2GB RAM (enough for K3s + 5 microservices)
}