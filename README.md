# fast-food-api-terraform

1) Recuperar AWS KEY e AWS SECRET KEY
2) terraform init (na pasta que clonou o repositorio)
3) terraform plan -var="aws_access_key=${AWS_ACCESS_KEY_ID}" -var="aws_secret_key=${$AWS_SECRET_ACCESS_KEY}" -out=plan.tfplan
4) terraform apply plan.tfplan



