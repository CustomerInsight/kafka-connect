# kafka-connect
Docker Compose를 이용한 Kafka Connect 실행 환경

## 사전 요구사항
- Docker Compose
- Oracle Source Connector 이용 시 Oracle Database JDBC Driver 필요 [설치링크](https://www.oracle.com/kr/database/technologies/appdev/jdbc-downloads.html)

## 포함된 플러그인 (SMT)
다음 커스텀 SMT 플러그인이 포함되어 있습니다:
- `strip-null`: 데이터셋에 `0x00` (Null 문자)가 포함되어 있어 DB 적재 시 오류가 발생하는 경우, 이를 제거하기 위해 사용합니다.
- `tombstone-on-delete`: Debezium CDC 이벤트 중 삭제(`__op: 'd'`)가 발생했을 때, Kafka Record의 Value를 `null`로 치환하여 Tombstone 레코드를 생성합니다. (KStream 등에서 Compact 토픽으로 활용 시 필수)

## 권장 커넥터
### Redis Sink Connector
- **Confluent Hub 버전 사용 지양**: Confluent Hub에 배포된 버전은 구버전으로 기능이 제한적입니다.
- **GitHub 버전 사용 권장**: [redis-kafka-connect](https://github.com/redis-field-engineering/redis-kafka-connect) 리포지토리에서 최신 버전을 다운로드하거나 직접 빌드하여 사용하십시오.

## PEM 파일 (마운트 경로 고정)
컨테이너 내 `/secrets-src` 경로에 다음 파일들이 마운트되어야 합니다:
- `/secrets-src/client-cert.pem`
- `/secrets-src/client-key.pem`
- `/secrets-src/ca-bundle.pem`

## 필수 환경 변수
- `KAFKA_URL`: Kafka 브로커 주소 (e.g. ssl://host1:9096,ssl://host2:9096)
- `SCHEMA_REGISTRY_URL`: 스키마 레지스트리 URL
- `SSL_KEY_PASSWORD`: SSL 키 비밀번호
- `CONNECT_GROUP_ID`: 커넥트 클러스터 그룹 ID
- `CONNECT_CONFIG_STORAGE_TOPIC`
- `CONNECT_OFFSET_STORAGE_TOPIC`
- `CONNECT_STATUS_STORAGE_TOPIC`

## 실행 및 커넥터 관리
- 제공된 `Dockerfile.connect` 및 `main.sh`는 워커 프로세스만 실행합니다.
- 커넥터의 생성/수정/삭제는 실행 중인 컨테이너의 REST API (`http://localhost:8083/connectors`)를 통해 직접 수행해야 합니다.