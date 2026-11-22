# CUSTOM FILE
# Terraform language: https://developer.hashicorp.com/terraform/language

resource "aws_iam_role" "learner_session" {
  name = "${aws_iam_role.ldl.name}-learner"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.ldl.arn }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "learner_session" {
  name = "GuidedDocumentAndSearchSession"
  role = aws_iam_role.learner_session.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::owasp-llm-03-${data.aws_caller_identity.current.account_id}-source/h02/knowledge/*"
      },
      {
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v2:0"
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:GetIngestionJob", "bedrock:Retrieve"]
        Resource = "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.account_id}:knowledge-base/*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Activity" = "P03"
            "aws:ResourceTag/Course"   = "tenant-03"
          }
        }
      }
    ]
  })
}
