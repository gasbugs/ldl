# CUSTOM FILE
# Terraform language: https://developer.hashicorp.com/terraform/language

# The existing Gateway compares role tags exactly. Keep lab default tags on
# the infrastructure resources, and use the audited contract on these roles.
provider "aws" {
  alias  = "course_contract"
  region = "us-east-1"
}

locals {
  knowledge_contracts = jsondecode(templatefile("${path.module}/knowledge-role-contracts.json.tftpl", {
    account_id = data.aws_caller_identity.current.account_id
  }))
  bedrock_prefix = "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}"
  course_owners = {
    "aws:ResourceTag/Course"    = "tenant-03"
    "aws:ResourceTag/ManagedBy" = "guided-control-center"
  }
  request_owners = {
    "aws:RequestTag/Course"    = "tenant-03"
    "aws:RequestTag/ManagedBy" = "guided-control-center"
  }
}

resource "aws_iam_role" "knowledge_source" {
  provider           = aws.course_contract
  for_each           = local.knowledge_contracts
  name               = each.value.role_name
  assume_role_policy = jsonencode(each.value.trust_policy)
  tags               = each.value.tags
}

resource "aws_iam_role_policy" "knowledge_source" {
  for_each = local.knowledge_contracts
  name     = each.value.policy_name
  role     = aws_iam_role.knowledge_source[each.key].id
  policy   = jsonencode(each.value.runtime_policy)
}

resource "aws_iam_role_policy" "course_preparation" {
  name = "GuidedCourseResourcePreparation"
  role = aws_iam_role.ldl.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.learner_session.arn
      },
      {
        Effect   = "Allow"
        Action   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListAttachedRolePolicies", "iam:ListRolePolicies"]
        Resource = [for role in aws_iam_role.knowledge_source : role.arn]
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [for role in aws_iam_role.knowledge_source : role.arn]
        Condition = { StringEquals = {
          "iam:PassedToService" = "bedrock.amazonaws.com"
        } }
      },
      {
        Effect = "Allow"
        Action = [
          "s3:CreateBucket", "s3:GetBucketPublicAccessBlock", "s3:GetBucketTagging", "s3:ListBucket",
          "s3:PutBucketPublicAccessBlock", "s3:PutBucketTagging"
        ]
        Resource = [for contract in local.knowledge_contracts : "arn:aws:s3:::${contract.source_bucket}"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = [for contract in local.knowledge_contracts : "arn:aws:s3:::${contract.source_bucket}/${contract.source_prefix}*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3vectors:CreateVectorBucket", "s3vectors:GetVectorBucket"]
        Resource = [for contract in local.knowledge_contracts : contract.vector_bucket_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3vectors:CreateIndex", "s3vectors:GetIndex", "s3vectors:ListVectors"]
        Resource = [for contract in local.knowledge_contracts : contract.index_arn]
      },
      {
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v2:0"
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:ListKnowledgeBases", "bedrock:ListGuardrails"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:CreateKnowledgeBase", "bedrock:CreateGuardrail"]
        Resource = "*"
        Condition = {
          StringEquals = merge(local.request_owners, { "aws:RequestTag/Activity" = ["H02", "P03", "P04"] })
        }
      },
      {
        Effect   = "Allow"
        Action   = "bedrock:TagResource"
        Resource = ["${local.bedrock_prefix}:knowledge-base/*", "${local.bedrock_prefix}:guardrail/*"]
        Condition = {
          StringEquals = merge(local.request_owners, { "aws:RequestTag/Activity" = ["H02", "P03", "P04"] })
        }
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:CreateDataSource", "bedrock:GetDataSource", "bedrock:GetIngestionJob", "bedrock:GetKnowledgeBase",
          "bedrock:GetKnowledgeBaseDocuments", "bedrock:ListDataSources", "bedrock:ListIngestionJobs",
          "bedrock:ListTagsForResource", "bedrock:Retrieve", "bedrock:StartIngestionJob"
        ]
        Resource = "${local.bedrock_prefix}:knowledge-base/*"
        Condition = {
          StringEquals = merge(local.course_owners, { "aws:ResourceTag/Activity" = ["H02", "P03"] })
        }
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:ApplyGuardrail", "bedrock:GetGuardrail", "bedrock:ListTagsForResource"]
        Resource = "${local.bedrock_prefix}:guardrail/*"
        Condition = {
          StringEquals = merge(local.course_owners, { "aws:ResourceTag/Activity" = "P04" })
        }
      },
    ]
  })
}
