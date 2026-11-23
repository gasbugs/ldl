# Amazon Bedrock API Lab

이 디렉터리는 Nova Lite·Titan·Knowledge Base를 직접 호출하는 방어 실습의 자료입니다. LDL 배포용 Terraform과 독립적으로 사용할 수 있습니다.

- `knowledge-base/`: 수강생이 읽고 직접 실행하는 정책 원문과 S3 문서
- `runtime/requirements.txt`: Boto3 버전 고정. Tool Use 예제 Python 파일은 수강생이 직접 작성합니다.

Nova Lite와 Titan Text Embeddings V2는 On-Demand API이므로 Terraform으로 모델 서버를 생성하지 않습니다. Nova Lite는 답변을 생성하고, Titan은 텍스트를 1024차원 의미 벡터로 변환합니다. AWS 자격 증명 준비는 과정 운영자가 별도로 안내하며 자격 증명을 저장소나 이미지에 넣지 않습니다.

이 폴더의 Knowledge Base 실습 리소스는 Terraform이나 래퍼 스크립트에 포함하지 않습니다. 수강생은 정책 원문을 확인하고 AWS CLI 명령을 단계별로 직접 실행합니다.

이 폴더의 Knowledge Base는 단독 실습용입니다. 이후 통합 방어 실습의 별도 Knowledge Base와 구분합니다.
