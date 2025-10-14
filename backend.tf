terraform {
  backend "s3" {
    bucket         = "terraform-tfstate-bucket-0406"
    key            = "project/vpc/terraform.tfstate"
    region         = "ap-southeast-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"   
  }
}
