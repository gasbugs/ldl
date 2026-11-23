# LLM Defense Lab (LDL) on AWS

English · [한국어](README.ko.md)

LLM Defense Lab is a hands-on environment for implementing and verifying security controls in AI applications. Its browser-based Control Center provides 24 missions covering Amazon Bedrock model access, guardrails, privacy, usage limits, retrieval permissions, security observability, and MCP tool authorization.

This repository contains the Terraform and first-boot script for deploying LDL. It provisions one dedicated Ubuntu EC2 `m6a.large` instance, an encrypted 100 GiB gp3 root volume, IAM roles, a security group, and an AWS Secrets Manager secret for Grafana logins. On first boot, the instance installs the Control Center and practice services from a pinned commit of the [LAL runtime](https://github.com/gasbugs/owasp-llm-application-security-lab).

The [Bedrock API lab](bedrock-api-lab/) contains the source documents, IAM policy templates, and pinned Boto3 dependency for the course's Nova Lite, Titan, and Knowledge Base exercises. Learners write the short Tool Use Python example themselves. This lab material is separate from the LAL runtime used by the Control Center.

## Deploy

Use a Bash terminal with AWS CLI and Terraform installed. The AWS account needs a default VPC and default subnets in `us-east-1`. Sign in to the AWS account where the lab should run. Add `--remote` to `aws login` if the browser is on another device.

```bash
aws login --profile ldl-login --region us-east-1
aws configure set credential_process \
  'aws configure export-credentials --profile ldl-login --format process' --profile ldl-terraform
export AWS_PROFILE=ldl-terraform
aws sts get-caller-identity --region us-east-1
```

Check that `Account` matches the intended deployment account. The `ldl-terraform` profile passes temporary login credentials to the Terraform AWS provider. Enter the learner's public IPv4 address in `/32` notation so the security group permits ports 9010–9015 only from that address.

```bash
terraform init
read -r -p 'Learner public IPv4 address with /32: ' LEARNER_CIDR
terraform plan -var="learner_ipv4_cidr=$LEARNER_CIDR" -out=ldl.plan
terraform apply ldl.plan
```

After EC2 enters the running state, first boot installs Docker and AWS CLI and builds the practice images. Wait for `LDL_BOOTSTRAP_READY` in the EC2 system log, then open the address returned by `terraform output -raw ldl_url`. If first boot fails, check the system log above `LDL_BOOTSTRAP_FAILED`.

## Use and operate the lab

The home page and P00 are available in the browser. For the separate Grafana views, the operator can retrieve the two logins generated for this deployment. The passwords are stored in Secrets Manager.

```bash
aws secretsmanager get-secret-value --region us-east-1 \
  --secret-id "$(terraform output -raw grafana_secret_arn)" \
  --query SecretString --output text
```

First boot enables 4 GiB of swap on the encrypted root volume and builds images one at a time. On a later EC2 start, the LDL service starts the containers with their existing data and applies the current public IPv4 address. Check that address in the EC2 console after a stop and start.

Terraform creates the service roles for the P01-02 and P01-03 Knowledge Bases. Prepare their source buckets, vector buckets, and Knowledge Bases through the corresponding missions. Prepare the P02-01 managed Guardrail through its mission. The Gateway issues 15-minute sessions for the document and retrieval missions, scoped to the document or Knowledge Base used in the current execution.

## Remove a deployment

Check ownership before deleting any buckets, Knowledge Bases, or Guardrails created by missions. These resources are created during practice and tracked outside Terraform state. After removing the resources owned by this deployment, use its Terraform state to remove EC2 and the remaining infrastructure.

## License

Original LDL code is available for noncommercial use under the [PolyForm Noncommercial License 1.0.0](LICENSE). Commercial use requires a [separate written license](COMMERCIAL-LICENSE.md). See the [copyright notice](NOTICE.md) and [third-party licenses](THIRD-PARTY-LICENSES.md).
