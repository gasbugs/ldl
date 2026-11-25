#!/usr/bin/env bash
set -euo pipefail

# restore-course-ec2.sh가 만든 수업용 EC2 리소스만 제거한다.
# Knowledge Base, S3, S3 Vectors와 로컬 개인 키는 기본 삭제 범위가 아니다.

AWS_REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}
AWS_PROFILE_NAME=${AWS_PROFILE_NAME:-${AWS_PROFILE:-owasp-llm-cpu-lab}}
PROJECT_TAG=${PROJECT_TAG:-awsw-preserve-t3-micro}
LAB_NAME=${LAB_NAME:-owasp-llm-cpu-lab}
LAB_ROLE=${LAB_ROLE:-owasp-llm-bedrock-ec2}
KEY_FILE=${KEY_FILE:-"$HOME/$LAB_NAME.pem"}
DELETE_LOCAL_KEY=false
CONFIRMED=false

usage() {
  cat <<'EOF'
usage: delete-course-ec2.sh --yes [--profile PROFILE] [--delete-local-key]

Deletes the course EC2 instance, its delete-on-termination root volume, the
dedicated security group, AWS key pair, instance profile, and the two inline
policies installed by restore-course-ec2.sh.

Knowledge Bases, S3 buckets, S3 Vector resources, and unrelated IAM policies
are not deleted. The local PEM file is retained unless --delete-local-key is
specified.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      AWS_PROFILE_NAME=$2
      shift 2
      ;;
    --delete-local-key)
      DELETE_LOCAL_KEY=true
      shift
      ;;
    --yes)
      CONFIRMED=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CONFIRMED" != true ]; then
  echo "refusing destructive cleanup without --yes" >&2
  usage >&2
  exit 2
fi

command -v aws >/dev/null 2>&1 || {
  echo "required command missing: aws" >&2
  exit 1
}

export AWS_PAGER=""
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
AWS=(aws --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION")

ACCOUNT_ID="$("${AWS[@]}" sts get-caller-identity --query Account --output text)"
CALLER_ARN="$("${AWS[@]}" sts get-caller-identity --query Arn --output text)"
printf 'Delete target: account=%s region=%s caller=%s lab=%s project=%s\n' \
  "$ACCOUNT_ID" "$AWS_REGION" "$CALLER_ARN" "$LAB_NAME" "$PROJECT_TAG"

instance_output="$("${AWS[@]}" ec2 describe-instances \
  --filters "Name=tag:Name,Values=$LAB_NAME" "Name=tag:Project,Values=$PROJECT_TAG" \
    'Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down' \
  --query 'Reservations[].Instances[].InstanceId' --output text)"

INSTANCE_IDS=()
if [ -n "$instance_output" ] && [ "$instance_output" != None ]; then
  read -r -a INSTANCE_IDS <<<"$instance_output"
  printf 'Terminating EC2 instance(s): %s\n' "${INSTANCE_IDS[*]}"
  "${AWS[@]}" ec2 terminate-instances --instance-ids "${INSTANCE_IDS[@]}" >/dev/null
  "${AWS[@]}" ec2 wait instance-terminated --instance-ids "${INSTANCE_IDS[@]}"
else
  echo "No matching EC2 instance found."
fi

VPC_ID="$("${AWS[@]}" ec2 describe-vpcs \
  --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != None ]; then
  SG_ID="$("${AWS[@]}" ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$LAB_NAME" \
      "Name=tag:Project,Values=$PROJECT_TAG" \
    --query 'SecurityGroups[0].GroupId' --output text)"
  if [ -n "$SG_ID" ] && [ "$SG_ID" != None ]; then
    deleted=false
    for _ in $(seq 1 12); do
      if "${AWS[@]}" ec2 delete-security-group --group-id "$SG_ID" >/dev/null 2>&1; then
        deleted=true
        break
      fi
      sleep 5
    done
    [ "$deleted" = true ] || {
      echo "security group is still in use and was not deleted: $SG_ID" >&2
      exit 1
    }
    printf 'Deleted security group: %s\n' "$SG_ID"
  else
    echo "No matching security group found."
  fi
fi

if "${AWS[@]}" ec2 describe-key-pairs --key-names "$LAB_NAME" >/dev/null 2>&1; then
  "${AWS[@]}" ec2 delete-key-pair --key-name "$LAB_NAME"
  printf 'Deleted AWS key pair: %s\n' "$LAB_NAME"
else
  echo "No matching AWS key pair found."
fi

if "${AWS[@]}" iam get-role --role-name "$LAB_ROLE" >/dev/null 2>&1; then
  for policy_name in OwaspLabModel OwaspLabKnowledgeRead; do
    if "${AWS[@]}" iam get-role-policy --role-name "$LAB_ROLE" \
      --policy-name "$policy_name" >/dev/null 2>&1; then
      "${AWS[@]}" iam delete-role-policy \
        --role-name "$LAB_ROLE" --policy-name "$policy_name"
      printf 'Deleted inline policy: %s/%s\n' "$LAB_ROLE" "$policy_name"
    fi
  done
fi

if "${AWS[@]}" iam get-instance-profile \
  --instance-profile-name "$LAB_ROLE" >/dev/null 2>&1; then
  profile_roles="$("${AWS[@]}" iam get-instance-profile \
    --instance-profile-name "$LAB_ROLE" \
    --query 'InstanceProfile.Roles[].RoleName' --output text)"
  for profile_role in $profile_roles; do
    "${AWS[@]}" iam remove-role-from-instance-profile \
      --instance-profile-name "$LAB_ROLE" --role-name "$profile_role"
  done
  "${AWS[@]}" iam delete-instance-profile --instance-profile-name "$LAB_ROLE"
  printf 'Deleted instance profile: %s\n' "$LAB_ROLE"
fi

if "${AWS[@]}" iam get-role --role-name "$LAB_ROLE" >/dev/null 2>&1; then
  inline_count="$("${AWS[@]}" iam list-role-policies --role-name "$LAB_ROLE" \
    --query 'length(PolicyNames)' --output text)"
  attached_count="$("${AWS[@]}" iam list-attached-role-policies --role-name "$LAB_ROLE" \
    --query 'length(AttachedPolicies)' --output text)"
  if [ "$inline_count" = 0 ] && [ "$attached_count" = 0 ]; then
    "${AWS[@]}" iam delete-role --role-name "$LAB_ROLE"
    printf 'Deleted empty IAM role: %s\n' "$LAB_ROLE"
  else
    printf 'Preserved IAM role %s: unrelated policies remain (inline=%s attached=%s).\n' \
      "$LAB_ROLE" "$inline_count" "$attached_count"
  fi
fi

if [ "$DELETE_LOCAL_KEY" = true ]; then
  case "$KEY_FILE" in
    ''|/|"$HOME") echo "unsafe KEY_FILE path: $KEY_FILE" >&2; exit 1 ;;
  esac
  if [ -f "$KEY_FILE" ]; then
    rm -f -- "$KEY_FILE"
    printf 'Deleted local private key: %s\n' "$KEY_FILE"
  fi
else
  printf 'Retained local private key: %s\n' "$KEY_FILE"
fi

echo "Course EC2 cleanup complete. Knowledge Base, S3, and S3 Vectors were not changed."
