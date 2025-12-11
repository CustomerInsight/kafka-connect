#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Kafka Connect Entrypoint
# =============================================================================

# --- 환경 변수 검증 ---
: "${KAFKA_URL:?e.g. ssl://host1:9096,ssl://host2:9096}"
: "${SCHEMA_REGISTRY_URL:?e.g. https://schema-registry:8081}"
: "${SSL_KEY_PASSWORD:?set SSL_KEY_PASSWORD}"
: "${CONNECT_GROUP_ID:?set CONNECT_GROUP_ID}"
: "${CONNECT_CONFIG_STORAGE_TOPIC:?set CONNECT_CONFIG_STORAGE_TOPIC}"
: "${CONNECT_OFFSET_STORAGE_TOPIC:?set CONNECT_OFFSET_STORAGE_TOPIC}"
: "${CONNECT_STATUS_STORAGE_TOPIC:?set CONNECT_STATUS_STORAGE_TOPIC}"

# --- 필수 명령어 검증 ---
command -v openssl >/dev/null

PORT="${PORT:-8083}"
export PORT

# --- SSL 인증서 원본 경로 ---
SRC_DIR="/secrets-src"
CHAIN="${SRC_DIR}/client-cert.pem"
KEY_IN="${SRC_DIR}/client-key.pem"
CA_PEM="${SRC_DIR}/ca-bundle.pem"

[ -s "$CHAIN" ]  || { echo "[ERR] missing $CHAIN"; exit 1; }
[ -s "$KEY_IN" ] || { echo "[ERR] missing $KEY_IN"; exit 1; }
[ -s "$CA_PEM" ] || { echo "[ERR] missing $CA_PEM"; exit 1; }

# --- Keystore 생성 ---
# Debezium 커넥터 설정의 'schema.history.internal.*' 속성이
# 이 경로를 참조하므로, 고정된 경로를 사용합니다.
# 이 파일은 컨테이너가 중지될 때 자동으로 삭제됩니다.
KEYSTORE_PATH="/tmp/keystore.p12"

openssl pkcs12 -export -name client \
  -inkey "$KEY_IN" -passin env:SSL_KEY_PASSWORD \
  -in "$CHAIN" \
  -out "$KEYSTORE_PATH" -passout env:SSL_KEY_PASSWORD
chmod 600 "$KEYSTORE_PATH" || true

# --- Kafka Connect 워커 설정 ---
BOOTSTRAP_SERVERS="$(echo "$KAFKA_URL" | sed -E 's#(^|,)[A-Za-z0-9+._-]+://#\1#g; s/[[:space:]]//g')"
export CONNECT_BOOTSTRAP_SERVERS="$BOOTSTRAP_SERVERS"
export KAFKA_BOOTSTRAP_SERVERS="$BOOTSTRAP_SERVERS"

export KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS:-"-Xms256m -Xmx1024m"}"
export CONNECT_GROUP_ID
export CONNECT_CONFIG_STORAGE_TOPIC
export CONNECT_OFFSET_STORAGE_TOPIC
export CONNECT_STATUS_STORAGE_TOPIC
export CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR="${CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR:-3}"
export CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR="${CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR:-3}"
export CONNECT_STATUS_STORAGE_REPLICATION_FACTOR="${CONNECT_STATUS_STORAGE_REPLICATION_FACTOR:-3}"

# --- 컨버터 설정 ---
export CONNECT_KEY_CONVERTER="io.confluent.connect.avro.AvroConverter"
export CONNECT_VALUE_CONVERTER="io.confluent.connect.avro.AvroConverter"
export CONNECT_KEY_CONVERTER_SCHEMA_REGISTRY_URL="${SCHEMA_REGISTRY_URL}"
export CONNECT_VALUE_CONVERTER_SCHEMA_REGISTRY_URL="${SCHEMA_REGISTRY_URL}"

export CONNECT_INTERNAL_KEY_CONVERTER="org.apache.kafka.connect.json.JsonConverter"
export CONNECT_INTERNAL_VALUE_CONVERTER="org.apache.kafka.connect.json.JsonConverter"
export CONNECT_INTERNAL_KEY_CONVERTER_SCHEMAS_ENABLE=false
export CONNECT_INTERNAL_VALUE_CONVERTER_SCHEMAS_ENABLE=false

# --- REST API 설정 ---
export CONNECT_PLUGIN_PATH="/usr/share/java/connect-plugins"
HOST_DEFAULT="${HEROKU_DNS_DYNO_NAME:-${HEROKU_APP_NAME:-${HOSTNAME}}}"
export CONNECT_REST_ADVERTISED_HOST_NAME="${CONNECT_REST_ADVERTISED_HOST_NAME:-${HOST_DEFAULT}}"
export CONNECT_REST_ADVERTISED_PORT="${CONNECT_REST_ADVERTISED_PORT:-${PORT}}"
export CONNECT_LISTENERS="http://0.0.0.0:${PORT}"
export CONNECT_REST_ADVERTISED_LISTENERS="${CONNECT_REST_ADVERTISED_LISTENERS:-http://${CONNECT_REST_ADVERTISED_HOST_NAME}:${PORT}}"

# --- 워커 SSL 설정 ---
export CONNECT_SECURITY_PROTOCOL="SSL"
export CONNECT_SSL_TRUSTSTORE_TYPE="PEM"
export CONNECT_SSL_TRUSTSTORE_LOCATION="${CA_PEM}"
export CONNECT_SSL_KEYSTORE_TYPE="PKCS12"
export CONNECT_SSL_KEYSTORE_LOCATION="$KEYSTORE_PATH" # 고정 경로 사용
export CONNECT_SSL_KEYSTORE_PASSWORD="${SSL_KEY_PASSWORD}"
export CONNECT_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM=""

# 내부 Producer/Consumer/Admin 클라이언트에도 SSL 설정 적용
for P in CONNECT CONNECT_PRODUCER CONNECT_CONSUMER CONNECT_ADMIN; do
  export ${P}_BOOTSTRAP_SERVERS="$BOOTSTRAP_SERVERS"
  export ${P}_SECURITY_PROTOCOL="SSL"
  export ${P}_SSL_TRUSTSTORE_TYPE="PEM"
  export ${P}_SSL_TRUSTSTORE_LOCATION="${CA_PEM}"
  export ${P}_SSL_KEYSTORE_TYPE="PKCS12"
  export ${P}_SSL_KEYSTORE_LOCATION="$KEYSTORE_PATH" # 고정 경로 사용
  export ${P}_SSL_KEYSTORE_PASSWORD="${SSL_KEY_PASSWORD}"
  export ${P}_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM=""
done

# =============================================================================
# 메인 실행 로직 -> Start Worker Directly
# =============================================================================
echo "[INFO] Starting Kafka Connect worker..."
exec /etc/confluent/docker/run