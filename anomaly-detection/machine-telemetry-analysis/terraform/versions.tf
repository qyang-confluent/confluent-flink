terraform {
  required_version = ">= 1.3"

  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "~> 2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

# Credentials come from the CONFLUENT_CLOUD_API_KEY and CONFLUENT_CLOUD_API_SECRET
# environment variables (read natively by the provider).
provider "confluent" {}
