source ~/vault/ccloud/dsp-cc.env
#terraform destroy -var-file="dsp.tfvars"
terraform plan -var-file="dsp.tfvars"
terraform apply -var-file="dsp.tfvars"

