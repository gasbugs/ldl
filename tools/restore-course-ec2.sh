#!/usr/bin/env bash
set -euo pipefail

# Notion "AWS EC2 자체 환경 구축 (강의용 시스템)" 절차를 재실행 가능한 형태로 묶는다.
# 두 번째 노트의 Bedrock 모델 호출과 Module 08 Knowledge Base 준비 권한을 반영한다.

AWS_REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}
AWS_PROFILE_NAME=${AWS_PROFILE_NAME:-owasp-llm-cpu-lab}
PROJECT_TAG=${PROJECT_TAG:-awsw-preserve-t3-micro}
LAB_NAME=${LAB_NAME:-owasp-llm-cpu-lab}
LAB_ROLE=${LAB_ROLE:-owasp-llm-bedrock-ec2}
INSTANCE_TYPE=${INSTANCE_TYPE:-m6a.large}
KEY_FILE=${KEY_FILE:-"$HOME/$LAB_NAME.pem"}
KNOWLEDGE_BASE_ID=""

usage() {
  cat <<'EOF'
usage: restore-course-ec2.sh [--profile PROFILE] [--knowledge-base-id ID]

Signs in with the selected AWS profile when needed, restores or creates the course
EC2 instance, and installs Docker Engine, Compose, and AWS CLI over SSH. The script
also grants Nova Lite, Titan Embed, and the scoped permissions required to create or
repair the Module 08 Knowledge Base. Existing keys, instances, and instance profiles
are reused. If a Knowledge Base ID is supplied, read/retrieve access is also limited
to that Knowledge Base.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      AWS_PROFILE_NAME=$2
      shift 2
      ;;
    --knowledge-base-id)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      KNOWLEDGE_BASE_ID=$2
      shift 2
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

for command in aws curl ssh ssh-keygen; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "required command missing: $command" >&2
    exit 1
  }
done

export AWS_PAGER=""
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
AWS=(aws --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION")

# 기존 세션이 유효하면 재사용하고, 만료됐을 때만 브라우저 로그인을 연다.
if ! "${AWS[@]}" sts get-caller-identity >/dev/null 2>&1; then
  printf 'AWS profile %s needs sign-in. Complete the browser approval shown below.\n' "$AWS_PROFILE_NAME"
  aws login --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION" --remote
fi
ACCOUNT_ID="$("${AWS[@]}" sts get-caller-identity --query Account --output text)"
CALLER_ARN="$("${AWS[@]}" sts get-caller-identity --query Arn --output text)"
printf 'AWS account=%s region=%s caller=%s\n' "$ACCOUNT_ID" "$AWS_REGION" "$CALLER_ARN"

trust_policy="$(mktemp)"
model_policy="$(mktemp)"
kb_policy="$(mktemp)"
kb_preparation_policy="$(mktemp)"
docker_bootstrap="$(mktemp)"
cleanup() {
  rm -f -- "$trust_policy" "$model_policy" "$kb_policy" \
    "$kb_preparation_policy" "$docker_bootstrap"
}
trap cleanup EXIT

cat >"$trust_policy" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
JSON

if ! "${AWS[@]}" iam get-role --role-name "$LAB_ROLE" >/dev/null 2>&1; then
  "${AWS[@]}" iam create-role \
    --role-name "$LAB_ROLE" \
    --assume-role-policy-document "file://$trust_policy" \
    --tags "Key=Project,Value=$PROJECT_TAG" >/dev/null
else
  "${AWS[@]}" iam update-assume-role-policy \
    --role-name "$LAB_ROLE" \
    --policy-document "file://$trust_policy"
fi

if ! "${AWS[@]}" iam get-instance-profile \
  --instance-profile-name "$LAB_ROLE" >/dev/null 2>&1; then
  "${AWS[@]}" iam create-instance-profile \
    --instance-profile-name "$LAB_ROLE" \
    --tags "Key=Project,Value=$PROJECT_TAG" >/dev/null
fi

profile_role="$("${AWS[@]}" iam get-instance-profile \
  --instance-profile-name "$LAB_ROLE" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)"
if [ "$profile_role" = None ]; then
  "${AWS[@]}" iam add-role-to-instance-profile \
    --instance-profile-name "$LAB_ROLE" --role-name "$LAB_ROLE"
elif [ "$profile_role" != "$LAB_ROLE" ]; then
  echo "instance profile $LAB_ROLE is already connected to role $profile_role" >&2
  exit 1
fi

# 두 번째 노트에서 가져온 모델 호출 권한만 EC2 역할에 부여한다.
cat >"$model_policy" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["bedrock:GetInferenceProfile", "bedrock:InvokeModel"],
      "Resource": "arn:aws:bedrock:us-east-1:${ACCOUNT_ID}:inference-profile/us.amazon.nova-lite-v1:0"
    },
    {
      "Effect": "Allow",
      "Action": "bedrock:InvokeModel",
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/amazon.nova-lite-v1:0",
        "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v2:0"
      ]
    }
  ]
}
JSON
"${AWS[@]}" iam put-role-policy --role-name "$LAB_ROLE" \
  --policy-name OwaspLabModel --policy-document "file://$model_policy"

# restore-module08-aws.sh가 고정 이름으로 만드는 자원에만 준비 권한을 준다.
MODULE08_PREFIX=owasp-llm-module08
MODULE08_BUCKET="${MODULE08_PREFIX}-${ACCOUNT_ID}-source"
MODULE08_VECTOR_BUCKET="${MODULE08_PREFIX}-${ACCOUNT_ID}-vectors"
MODULE08_KB_ROLE="${MODULE08_PREFIX}-knowledge-base-role"
cat >"$kb_preparation_policy" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PrepareModule08SourceBucket",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket", "s3:GetBucketPublicAccessBlock", "s3:ListBucket",
        "s3:PutBucketPublicAccessBlock"
      ],
      "Resource": "arn:aws:s3:::${MODULE08_BUCKET}"
    },
    {
      "Sid": "UploadModule08Documents",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::${MODULE08_BUCKET}/knowledge/*"
    },
    {
      "Sid": "PrepareModule08VectorBucket",
      "Effect": "Allow",
      "Action": [
        "s3vectors:CreateVectorBucket", "s3vectors:GetVectorBucket",
        "s3vectors:ListIndexes"
      ],
      "Resource": "arn:aws:s3vectors:${AWS_REGION}:${ACCOUNT_ID}:bucket/${MODULE08_VECTOR_BUCKET}"
    },
    {
      "Sid": "PrepareModule08VectorIndex",
      "Effect": "Allow",
      "Action": ["s3vectors:CreateIndex", "s3vectors:GetIndex"],
      "Resource": "arn:aws:s3vectors:${AWS_REGION}:${ACCOUNT_ID}:bucket/${MODULE08_VECTOR_BUCKET}/index/guardrail-knowledge"
    },
    {
      "Sid": "ManageModule08KnowledgeBaseServiceRole",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:GetRole", "iam:PutRolePolicy",
        "iam:UpdateAssumeRolePolicy"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${MODULE08_KB_ROLE}"
    },
    {
      "Sid": "PassModule08RoleOnlyToBedrock",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${MODULE08_KB_ROLE}",
      "Condition": {"StringEquals": {"iam:PassedToService": "bedrock.amazonaws.com"}}
    },
    {
      "Sid": "ListModule08KnowledgeBases",
      "Effect": "Allow",
      "Action": "bedrock:ListKnowledgeBases",
      "Resource": "*"
    },
    {
      "Sid": "CreateTaggedModule08KnowledgeBase",
      "Effect": "Allow",
      "Action": ["bedrock:CreateKnowledgeBase", "bedrock:TagResource"],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/Project": "llm-defense-lab",
          "aws:RequestTag/Module": "08"
        }
      }
    },
    {
      "Sid": "OperateModule08KnowledgeBase",
      "Effect": "Allow",
      "Action": [
        "bedrock:CreateDataSource", "bedrock:DeleteDataSource",
        "bedrock:DeleteKnowledgeBase", "bedrock:GetDataSource",
        "bedrock:GetIngestionJob", "bedrock:GetKnowledgeBase",
        "bedrock:ListDataSources", "bedrock:ListIngestionJobs",
        "bedrock:Retrieve", "bedrock:StartIngestionJob"
      ],
      "Resource": "arn:aws:bedrock:${AWS_REGION}:${ACCOUNT_ID}:knowledge-base/*"
    }
  ]
}
JSON
"${AWS[@]}" iam put-role-policy --role-name "$LAB_ROLE" \
  --policy-name OwaspLabKnowledgePreparation \
  --policy-document "file://$kb_preparation_policy"

if [ -n "$KNOWLEDGE_BASE_ID" ]; then
  case "$KNOWLEDGE_BASE_ID" in
    *[!A-Za-z0-9]*) echo "invalid Knowledge Base ID: $KNOWLEDGE_BASE_ID" >&2; exit 2 ;;
  esac
  cat >"$kb_policy" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["bedrock:Retrieve","bedrock:GetKnowledgeBase"],"Resource":"arn:aws:bedrock:${AWS_REGION}:${ACCOUNT_ID}:knowledge-base/${KNOWLEDGE_BASE_ID}"}]}
JSON
  "${AWS[@]}" iam put-role-policy --role-name "$LAB_ROLE" \
    --policy-name OwaspLabKnowledgeRead --policy-document "file://$kb_policy"
fi

VPC_ID="$("${AWS[@]}" ec2 describe-vpcs \
  --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
[ "$VPC_ID" != None ] || { echo "default VPC not found in $AWS_REGION" >&2; exit 1; }

SUPPORTED_AZS="$("${AWS[@]}" ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
  --query 'sort(InstanceTypeOfferings[].Location)' --output text)"
[ -n "$SUPPORTED_AZS" ] || { echo "$INSTANCE_TYPE is unavailable in $AWS_REGION" >&2; exit 1; }

SUBNET_ID=""
for availability_zone in $SUPPORTED_AZS; do
  SUBNET_ID="$("${AWS[@]}" ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" Name=default-for-az,Values=true \
      "Name=availability-zone,Values=$availability_zone" Name=state,Values=available \
    --query 'sort_by(Subnets, &SubnetId)[0].SubnetId' --output text)"
  [ "$SUBNET_ID" != None ] && break
done
[ -n "$SUBNET_ID" ] && [ "$SUBNET_ID" != None ] || {
  echo "no default subnet supports $INSTANCE_TYPE" >&2
  exit 1
}
printf 'VPC=%s supported_AZs=%s subnet=%s\n' "$VPC_ID" "$SUPPORTED_AZS" "$SUBNET_ID"

MY_IP="$(curl -4fsS https://checkip.amazonaws.com | tr -d '\n')"
case "$MY_IP" in
  *[!0-9.]*|'') echo "public IPv4 lookup returned an invalid value" >&2; exit 1 ;;
esac
printf 'Allowed client IPv4=%s/32\n' "$MY_IP"

# 기존 서버는 로컬 키·보안 그룹 복구에 앞서 시작한다.
INSTANCE_ID="$("${AWS[@]}" ec2 describe-instances \
  --filters "Name=tag:Name,Values=$LAB_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'sort_by(Reservations[].Instances[], &LaunchTime)[-1].InstanceId' --output text)"
if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != None ]; then
  instance_state="$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)"
  printf 'Reusing EC2 %s (state=%s)\n' "$INSTANCE_ID" "$instance_state"
  if [ "$instance_state" = stopping ]; then
    "${AWS[@]}" ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
    instance_state=stopped
  fi
  if [ "$instance_state" = stopped ]; then
    "${AWS[@]}" ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
    printf 'EC2 start requested: %s\n' "$INSTANCE_ID"
  fi
  if [ ! -f "$KEY_FILE" ]; then
    "${AWS[@]}" ec2 wait instance-running --instance-ids "$INSTANCE_ID"
    PUBLIC_IP="$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
    printf 'EC2 running: instance=%s public_ip=%s\n' "$INSTANCE_ID" "$PUBLIC_IP"
    echo 'Private key is unavailable; SSH bootstrap skipped. Existing EC2 was preserved and started.'
    exit 0
  fi
fi

key_pair_id="$("${AWS[@]}" ec2 describe-key-pairs --key-names "$LAB_NAME" \
  --query 'KeyPairs[0].KeyPairId' --output text 2>/dev/null || true)"
EC2_KEY_NAME=$LAB_NAME
if [ -z "$key_pair_id" ] || [ "$key_pair_id" = None ]; then
  [ ! -e "$KEY_FILE" ] || {
    echo "local key exists but AWS key pair does not: $KEY_FILE" >&2
    exit 1
  }
  umask 077
  "${AWS[@]}" ec2 create-key-pair --key-name "$LAB_NAME" \
    --key-type rsa --key-format pem \
    --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=$LAB_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
    --query KeyMaterial --output text >"$KEY_FILE"
  chmod 400 "$KEY_FILE"
elif [ ! -f "$KEY_FILE" ]; then
  # 기존 AWS 키는 보존하고 새 인스턴스에 사용할 키를 별도로 만든다.
  EC2_KEY_NAME="${LAB_NAME}-$(date -u +%Y%m%d%H%M%S)-$$"
  KEY_FILE="$HOME/$EC2_KEY_NAME.pem"
  umask 077
  "${AWS[@]}" ec2 create-key-pair --key-name "$EC2_KEY_NAME" \
    --key-type rsa --key-format pem \
    --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=$LAB_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
    --query KeyMaterial --output text >"$KEY_FILE"
  chmod 400 "$KEY_FILE"
  printf 'Created recovery key pair: %s; private key: %s\n' "$EC2_KEY_NAME" "$KEY_FILE"
fi
ssh-keygen -y -f "$KEY_FILE" >/dev/null

SG_ID="$("${AWS[@]}" ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$LAB_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)"
if [ "$SG_ID" = None ]; then
  SG_ID="$("${AWS[@]}" ec2 create-security-group \
    --group-name "$LAB_NAME" --description 'OWASP LLM CPU lab access' \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$LAB_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
    --query GroupId --output text)"
fi

authorize_port() {
  local from_port=$1
  local to_port=$2
  "${AWS[@]}" ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=$from_port,ToPort=$to_port,IpRanges=[{CidrIp=${MY_IP}/32}]" \
    >/dev/null 2>&1 || {
      existing="$("${AWS[@]}" ec2 describe-security-groups --group-ids "$SG_ID" \
        --query "length(SecurityGroups[0].IpPermissions[?IpProtocol=='tcp' && FromPort==\`${from_port}\` && ToPort==\`${to_port}\`].IpRanges[?CidrIp=='${MY_IP}/32'])" \
        --output text)"
      [ "$existing" != 0 ] || return 1
    }
}
authorize_port 22 22
authorize_port 9010 9020

INSTANCE_ID="$("${AWS[@]}" ec2 describe-instances \
  --filters "Name=tag:Name,Values=$LAB_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'sort_by(Reservations[].Instances[], &LaunchTime)[-1].InstanceId' --output text)"

if [ "$INSTANCE_ID" = None ]; then
  AMI_ID="$("${AWS[@]}" ec2 describe-images --owners 099720109477 \
    --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
      Name=architecture,Values=x86_64 Name=state,Values=available \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)"

  # 새 instance profile이 EC2 제어면에 전파될 시간을 준다.
  sleep 10

  INSTANCE_ID="$("${AWS[@]}" ec2 run-instances \
    --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --count 1 \
    --key-name "$EC2_KEY_NAME" --iam-instance-profile "Name=$LAB_ROLE" \
    --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=[$SG_ID],AssociatePublicIpAddress=true" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=100,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}' \
    --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=2,HttpEndpoint=enabled' \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=$LAB_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
      "ResourceType=volume,Tags=[{Key=Name,Value=$LAB_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
    --query 'Instances[0].InstanceId' --output text)"
else
  instance_state="$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)"
  if [ "$instance_state" = stopped ]; then
    "${AWS[@]}" ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
  elif [ "$instance_state" = stopping ]; then
    "${AWS[@]}" ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
    "${AWS[@]}" ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
  fi
fi

# 기존 EC2는 교체하지 않는다. Profile이 없을 때만 이번 역할을 연결한다.
instance_profile_arn="$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)"
expected_profile_arn="arn:aws:iam::${ACCOUNT_ID}:instance-profile/${LAB_ROLE}"
if [ -z "$instance_profile_arn" ] || [ "$instance_profile_arn" = None ]; then
  "${AWS[@]}" ec2 associate-iam-instance-profile --instance-id "$INSTANCE_ID" \
    --iam-instance-profile "Name=$LAB_ROLE" >/dev/null
elif [ "$instance_profile_arn" != "$expected_profile_arn" ]; then
  echo "existing EC2 uses a different instance profile: $instance_profile_arn" >&2
  echo "preserving the current profile; no replacement was attempted" >&2
  exit 1
fi

"${AWS[@]}" ec2 wait instance-running --instance-ids "$INSTANCE_ID"
"${AWS[@]}" ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"
PUBLIC_IP="$("${AWS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

[ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != None ] || {
  echo "EC2 has no public IPv4 address: $INSTANCE_ID" >&2
  exit 1
}

# 새 인스턴스와 기존 인스턴스에 동일한 멱등 부트스트랩을 적용한다.
cat >"$docker_bootstrap" <<'BOOTSTRAP'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ca-certificates curl unzip
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
usermod -aG docker ubuntu

if ! command -v aws >/dev/null 2>&1; then
  temp_dir="$(mktemp -d)"
  trap 'rm -rf -- "$temp_dir"' EXIT
  curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o "$temp_dir/awscliv2.zip"
  unzip -q "$temp_dir/awscliv2.zip" -d "$temp_dir"
  "$temp_dir/aws/install"
fi
BOOTSTRAP

ssh_options=(-i "$KEY_FILE" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
ssh_target="ubuntu@$PUBLIC_IP"
printf 'EC2 running: instance=%s public_ip=%s; waiting for SSH\n' "$INSTANCE_ID" "$PUBLIC_IP"
ssh_ready=false
for attempt in {1..30}; do
  if ssh "${ssh_options[@]}" "$ssh_target" true >/dev/null 2>&1; then
    ssh_ready=true
    break
  fi
  sleep 5
done
[ "$ssh_ready" = true ] || { echo "SSH unavailable after 150 seconds: $ssh_target" >&2; exit 1; }

# Cloud-init가 apt 잠금을 놓은 뒤, SSH를 통해 설치한다.
ssh "${ssh_options[@]}" "$ssh_target" 'timeout 900 sudo cloud-init status --wait >/dev/null'
ssh "${ssh_options[@]}" "$ssh_target" 'sudo bash -s' <"$docker_bootstrap"

# 새 SSH 세션에서 docker 그룹이 반영됐는지 일반 사용자 권한으로 확인한다.
ssh "${ssh_options[@]}" "$ssh_target" \
  "docker version && docker compose version && aws sts get-caller-identity --region '$AWS_REGION' --query Arn --output text"
printf '\nEC2 ready: instance=%s public_ip=%s\n' "$INSTANCE_ID" "$PUBLIC_IP"
printf 'SSH: ssh -i %q ubuntu@%s\n' "$KEY_FILE" "$PUBLIC_IP"
