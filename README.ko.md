# LLM Defense Lab (LDL) AWS 배포

[English](README.md) · 한국어

LLM Defense Lab(LDL)은 브라우저에서 AI 애플리케이션의 보안 통제를 구현하고 검증하는 실습 환경입니다. Control Center에서 24개의 미션을 열어 Bedrock 모델 접근, 개인정보 보호, 가드레일, 사용량 제한, 검색 권한, 보안 관측, MCP 도구 권한을 실습합니다.

이 저장소는 LDL을 AWS에 배포하는 Terraform과 첫 부팅 스크립트를 관리합니다. 기본 VPC와 서브넷이 있는 `us-east-1`에서 전용 Ubuntu EC2 `m6a.large` 한 대, 암호화된 100 GiB gp3 볼륨, IAM 역할, 보안 그룹, Grafana 로그인용 Secrets Manager 시크릿을 준비합니다. 첫 부팅에서 [setup 저장소](https://github.com/gasbugs/owasp-llm-application-security-lab)의 고정 커밋을 받아 Control Center와 실습 서비스를 설치합니다.

[Bedrock API 실습 자료](bedrock-api-lab/)에는 Nova Lite·Titan·Knowledge Base 실습의 원문 문서, IAM 정책 템플릿, Boto3 버전 고정 파일을 둡니다. 짧은 Tool Use Python 예제는 수강생이 직접 작성합니다. 이 자료는 Control Center가 사용하는 LAL 런타임과 분리됩니다.

## 운영자 배포

AWS CLI와 Terraform이 이미 설치된 Bash 터미널을 사용한다. AWS 콘솔 로그인 창에서 배포할 수강생 계정의 권한을 선택한다. 브라우저를 같은 환경에서 열 수 없으면 첫 명령에 `--remote`를 붙이고 브라우저에 표시된 인증 코드를 터미널에 입력한다.

```bash
aws login --profile ldl-login --region us-east-1
aws configure set credential_process \
  'aws configure export-credentials --profile ldl-login --format process' --profile ldl-terraform
export AWS_PROFILE=ldl-terraform
aws sts get-caller-identity --region us-east-1
```

`Account`가 배포할 계정인지 확인한다. `ldl-terraform` 프로필은 Terraform AWS 공급자에 로그인 세션의 임시 자격 증명을 전달한다. `learner_ipv4_cidr`에는 수강생의 PC에서 확인한 공인 IPv4 한 개를 `/32`로 입력한다.

```bash
terraform init
read -r -p '수강생 PC 공인 IPv4 (/32 포함): ' LEARNER_CIDR
terraform plan -var="learner_ipv4_cidr=$LEARNER_CIDR" -out=ldl.plan
terraform apply ldl.plan
```

EC2 상태가 실행 중이 된 뒤에도 첫 부팅에서 Docker·AWS CLI 설치와 LDL 이미지 빌드가 진행된다. EC2 콘솔의 시스템 로그에서 `LDL_BOOTSTRAP_READY`를 확인한 다음 `terraform output -raw ldl_url`로 나온 주소를 수강생에게 전달한다. 수강생은 브라우저에서 접속한다. 이 모듈의 보안 그룹은 수강생 PC의 `9010–9015/tcp`만 허용한다.

LDL 홈과 P00은 바로 열 수 있다. 보조 Grafana 화면을 사용할 때는 운영자가 AWS Secrets Manager에서 이 LDL 인스턴스의 두 로그인 정보를 확인해 해당 수강생에게 전달한다. 첫 부팅에서 생성한 비밀번호는 Terraform 입력과 부팅 로그에 들어가지 않는다. 이 모듈은 로그인 정보 보관용 Secrets Manager 시크릿 한 개도 생성한다.

```bash
aws secretsmanager get-secret-value --region us-east-1 \
  --secret-id "$(terraform output -raw grafana_secret_arn)" \
  --query SecretString --output text
```

첫 부팅은 암호화한 루트 볼륨에 4 GiB 스왑을 설정하고, 이미지 빌드 동시성을 1로 제한한다. 설치가 끝나면 LDL 사용자 서비스가 이후 EC2 시작 시 기존 데이터와 함께 컨테이너를 시작하고 새 공인 IPv4를 반영한다. EC2를 중지한 뒤 다시 시작한 경우 현재 공인 IPv4를 EC2 콘솔에서 확인해 접속 주소에 사용한다.

부팅에 실패하면 시스템 로그에서 `LDL_BOOTSTRAP_FAILED` 앞의 오류를 확인한다. Terraform 상태 파일로 해당 AWS 계정의 자원을 관리한다. 첫 부팅은 [setup 저장소](https://github.com/gasbugs/owasp-llm-application-security-lab)의 LDL 런타임을 고정 Git 커밋에서 받는다. Terraform 코드는 이 저장소 루트에서 실행한다.

EC2 역할은 Nova Lite 호출과 미션 전용 AWS 자원 준비에 필요한 권한을 갖는다. Terraform이 P01-02·03용 Knowledge Base 서비스 역할을 먼저 만들고, 실습 화면에서 원본 버킷·벡터 버킷·Knowledge Base 연결을 준비한다. P02-01의 관리형 Guardrail도 실습 화면에서 준비한다.

P01-02·03은 실행 범위를 제한한 15분짜리 자격 증명을 사용한다. Gateway만 학습용 IAM 역할을 맡을 수 있고, 각 미션의 세션 정책은 현재 문서 또는 Knowledge Base로 권한을 좁힌다.

검증 배포를 정리할 때는 먼저 이번 미션에서 만든 버킷·Knowledge Base·Guardrail의 소유권을 확인한다. 이 자원은 미션 실행 중 만들어지므로 Terraform 상태에 등록되지 않는다. 이후 해당 배포의 Terraform 상태를 사용해 EC2와 배포 자원을 정리한다.

## 라이선스

이 저장소에서 직접 작성한 부분은 비상업적 사용에 [PolyForm Noncommercial License 1.0.0](LICENSE)을 적용합니다. 상업적 사용에는 [별도의 서면 상업용 라이선스](COMMERCIAL-LICENSE.md)가 필요합니다. [저작권 고지](NOTICE.md)와 [외부 구성요소의 라이선스](THIRD-PARTY-LICENSES.md)를 확인하세요.
