# kafka-connect
docker compose를 이용한 kafka connect 스크립트

## 사전 요구사항
- Docker Compose
- Oracle Source Connector 이용 시 Oracle Database JDBC Driver 필요 [설치링크](https://www.oracle.com/kr/database/technologies/appdev/jdbc-downloads.html)

## PEM 파일 (마운트 경로 고정):
- /secrets-src/client-cert.pem
- /secrets-src/client-key.pem
- /secrets-src/ca-bundle.pem

## 요구 파라미터
- KAFKA_URL  
- SCHEMA_REGISTRY_URL  
- SSL_KEY_PASSWORD  
- CONNECT_GROUP_ID
- CONNECT_CONFIG_STORAGE_TOPIC
- CONNECT_OFFSET_STORAGE_TOPIC
- CONNECT_STATUS_STORAGE_TOPIC

## 커넥터 설정
- connectors 폴더에 .json으로 구성된 커넥터 파일 삽입