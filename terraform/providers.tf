provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        Project     = var.project
        Environment = var.environment
        ManagedBy   = "terraform"
        Component   = "data-lakehouse"
      },
      var.tags,
    )
  }
}
