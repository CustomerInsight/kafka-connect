#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Kafka Connect Entrypoint Script (FINAL)
# - SSL 인증서 처리 (파일 → PKCS#8 → PKCS#12 keystore, truststore=PEM LOCATION)
# - Kafka/Connect 공통 SSL 환경 변수 구성
# - Connect 기본 토픽/컨버터/REST 설정 주입
# - Connect REST 준비 후 커넥터 자동 업서트(ENV + /connectors/*.json 지원)
# ============================================================================

# ===== Required ENVs =====
: "${KAFKA_URL:?ssl://host1:9096,... required}"
: "${SCHEMA_REGISTRY_URL:?Schema Registry URL required}"
: "${SSL_KEY_PASSWORD:?SSL_KEY_PASSWORD required}"

command -v openssl >/dev/null
command -v python3 >/dev/null
command -v curl >/dev/null

# ----------------------------------------------------------------------------
# 1) 인증서 파일 위치/존재 검사
# ----------------------------------------------------------------------------
SRC_DIR="/secrets-src"
CHAIN="${SRC_DIR}/client-cert.pem"    # leaf + chain (leaf-first 권장)
KEY_IN="${SRC_DIR}/client-key.pem"    # private key (any → PKCS#8(enc))
CA_PEM="${SRC_DIR}/ca-bundle.pem"     # truststore: PEM LOCATION

[ -s "$CHAIN" ] || { echo "[ERR] missing $CHAIN"; exit 1; }
[ -s "$KEY_IN" ] || { echo "[ERR] missing $KEY_IN"; exit 1; }
[ -s "$CA_PEM" ] || { echo "[ERR] missing $CA_PEM"; exit 1; }

# ----------------------------------------------------------------------------
# 2) 기본 포트/리소스
# ----------------------------------------------------------------------------
export PORT="${PORT:-8083}"
export KAFKA_HEAP_OPTS="${KAFKA_HEAP_OPTS:-"-Xms256m -Xmx1024m"}"

# ----------------------------------------------------------------------------
# 3) PKCS#12 keystore 생성 (truststore는 PEM LOCATION 사용)
# ----------------------------------------------------------------------------
tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT

# 개인키: 이미 PKCS#8(enc)이면 그대로, 아니면 변환
if grep -q "ENCRYPTED PRIVATE KEY" "$KEY_IN"; then
  cp "$KEY_IN" "${tmpdir}/key_pkcs8_enc.pem"
else
  openssl pkcs8 -topk8 -v2 aes-256-cbc -passout env:SSL_KEY_PASSWORD \
    -in "$KEY_IN" -out "${tmpdir}/key_pkcs8_enc.pem"
fi

# CHAIN leaf-first 보정(가능하면)
CHAIN_FIXED="$CHAIN"
if openssl pkcs8 -topk8 -nocrypt -in "$KEY_IN" -out "${tmpdir}/key_plain.pem" 2>/dev/null; then
  key_pub_sha="$(openssl pkey -pubout -in "${tmpdir}/key_plain.pem" 2>/dev/null | openssl sha256 | awk '{print $2}' || true)"
  if [ -n "${key_pub_sha:-}" ]; then
    awk 'BEGIN{c=0} /-----BEGIN CERTIFICATE-----/{c++} {print > sprintf("'"${tmpdir}"'/cert_%02d.pem", c)}' "$CHAIN" || true
    best=""
    for f in $(ls "${tmpdir}"/cert_*.pem 2>/dev/null | sort); do
      [ -s "$f" ] || continue
      csha="$(openssl x509 -pubkey -noout -in "$f" 2>/dev/null | openssl sha256 | awk '{print $2}' || true)"
      [ "$csha" = "$key_pub_sha" ] && { best="$f"; break; }
    done
    if [ -n "$best" ]; then
      CHAIN_FIXED="${tmpdir}/chain.fixed.pem"
      { cat "$best"; for f in $(ls "${tmpdir}"/cert_*.pem 2>/dev/null | sort); do
          [ "$f" = "$best" ] || cat "$f";
        done; } > "$CHAIN_FIXED"
    fi
  fi
fi

KEYSTORE="${tmpdir}/keystore.p12"
openssl pkcs12 -export -name client \
  -inkey "${tmpdir}/key_pkcs8_enc.pem" -passin env:SSL_KEY_PASSWORD \
  -in "$CHAIN_FIXED" \
  -out "$KEYSTORE" -passout env:SSL_KEY_PASSWORD

# ----------------------------------------------------------------------------
# 4) Bootstrap & SSL 세팅 (Heroku 스타일 URL → bootstrap.servers)
# ----------------------------------------------------------------------------
BOOTSTRAP_SERVERS="$(echo "$KAFKA_URL" | sed -E 's#(^|,)[A-Za-z0-9+._-]+://#\1#g; s/[[:space:]]//g')"

# AdminClient 기본값
export KAFKA_BOOTSTRAP_SERVERS="$BOOTSTRAP_SERVERS"
export KAFKA_SECURITY_PROTOCOL="SSL"
export KAFKA_SSL_TRUSTSTORE_TYPE="PEM"
export KAFKA_SSL_TRUSTSTORE_LOCATION="$CA_PEM"
export KAFKA_SSL_KEYSTORE_TYPE="PKCS12"
export KAFKA_SSL_KEYSTORE_LOCATION="$KEYSTORE"
export KAFKA_SSL_KEYSTORE_PASSWORD="${SSL_KEY_PASSWORD}"
export KAFKA_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM=""

# Connect Worker / Producer / Consumer / Admin 공통 SSL
for P in CONNECT CONNECT_PRODUCER CONNECT_CONSUMER CONNECT_ADMIN; do
  export ${P}_BOOTSTRAP_SERVERS="$BOOTSTRAP_SERVERS"
  export ${P}_SECURITY_PROTOCOL="SSL"
  export ${P}_SSL_TRUSTSTORE_TYPE="PEM"
  export ${P}_SSL_TRUSTSTORE_LOCATION="$CA_PEM"
  export ${P}_SSL_KEYSTORE_TYPE="PKCS12"
  export ${P}_SSL_KEYSTORE_LOCATION="$KEYSTORE"
  export ${P}_SSL_KEYSTORE_PASSWORD="${SSL_KEY_PASSWORD}"
  export ${P}_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM=""
done

# ----------------------------------------------------------------------------
# 5) Connect 필수/권장 기본값
# ----------------------------------------------------------------------------
export CONNECT_GROUP_ID="${CONNECT_GROUP_ID:-kafka-connect}"
export CONNECT_CONFIG_STORAGE_TOPIC="${CONNECT_CONFIG_STORAGE_TOPIC:-kafka-connect-configs}"
export CONNECT_OFFSET_STORAGE_TOPIC="${CONNECT_OFFSET_STORAGE_TOPIC:-kafka-connect-offsets}"
export CONNECT_STATUS_STORAGE_TOPIC="${CONNECT_STATUS_STORAGE_TOPIC:-kafka-connect-status}"

export CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR="${CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR:-3}"
export CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR="${CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR:-3}"
export CONNECT_STATUS_STORAGE_REPLICATION_FACTOR="${CONNECT_STATUS_STORAGE_REPLICATION_FACTOR:-3}"
export CONNECT_OFFSET_STORAGE_PARTITIONS="${CONNECT_OFFSET_STORAGE_PARTITIONS:-1}"
export CONNECT_STATUS_STORAGE_PARTITIONS="${CONNECT_STATUS_STORAGE_PARTITIONS:-1}"

# 외부 Avro, 내부 JSON(무스키마)
export CONNECT_KEY_CONVERTER="${CONNECT_KEY_CONVERTER:-io.confluent.connect.avro.AvroConverter}"
export CONNECT_VALUE_CONVERTER="${CONNECT_VALUE_CONVERTER:-io.confluent.connect.avro.AvroConverter}"
export CONNECT_KEY_CONVERTER_SCHEMA_REGISTRY_URL="${CONNECT_KEY_CONVERTER_SCHEMA_REGISTRY_URL:-$SCHEMA_REGISTRY_URL}"
export CONNECT_VALUE_CONVERTER_SCHEMA_REGISTRY_URL="${CONNECT_VALUE_CONVERTER_SCHEMA_REGISTRY_URL:-$SCHEMA_REGISTRY_URL}"

export CONNECT_INTERNAL_KEY_CONVERTER="${CONNECT_INTERNAL_KEY_CONVERTER:-org.apache.kafka.connect.json.JsonConverter}"
export CONNECT_INTERNAL_VALUE_CONVERTER="${CONNECT_INTERNAL_VALUE_CONVERTER:-org.apache.kafka.connect.json.JsonConverter}"
export CONNECT_INTERNAL_KEY_CONVERTER_SCHEMAS_ENABLE="${CONNECT_INTERNAL_KEY_CONVERTER_SCHEMAS_ENABLE:-false}"
export CONNECT_INTERNAL_VALUE_CONVERTER_SCHEMAS_ENABLE="${CONNECT_INTERNAL_VALUE_CONVERTER_SCHEMAS_ENABLE:-false}"

# REST/플러그인/광고 주소
export CONNECT_LISTENERS="${CONNECT_LISTENERS:-http://0.0.0.0:${PORT}}"
export CONNECT_REST_PORT="${CONNECT_REST_PORT:-$PORT}"
export CONNECT_REST_ADVERTISED_HOST_NAME="${CONNECT_REST_ADVERTISED_HOST_NAME:-0.0.0.0}"
export CONNECT_REST_ADVERTISED_PORT="${CONNECT_REST_ADVERTISED_PORT:-$PORT}"
export CONNECT_REST_ADVERTISED_LISTENERS="http://${CONNECT_REST_ADVERTISED_HOST_NAME}:${CONNECT_REST_ADVERTISED_PORT}"
export CONNECT_PLUGIN_PATH="${CONNECT_PLUGIN_PATH:-/usr/share/java/connect-plugins}"

# ----------------------------------------------------------------------------
# 6) 커넥터 업서트 유틸
# ----------------------------------------------------------------------------
CONNECT_HOST="http://127.0.0.1:${PORT}"
AUTH_ARGS=()
if [ -n "${CONNECT_REST_USERNAME:-}" ] && [ -n "${CONNECT_REST_PASSWORD:-}" ]; then
  AUTH_ARGS=(-u "${CONNECT_REST_USERNAME}:${CONNECT_REST_PASSWORD}")
fi

wait_for_connect() {
  echo "[WAIT] Connect REST ${CONNECT_HOST} ..."
  for i in $(seq 1 90); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${AUTH_ARGS[@]}" \
      "${CONNECT_HOST}/connectors")" || true
    if [ "$code" = "200" ]; then
      echo "[OK] Connect REST is up"
      return 0
    fi
    sleep 1
  done
  echo "[ERR] Connect REST not ready"
  return 1
}

# JSON compact (jq 없이 python3)
compact_json() {
  python3 - "$1" <<'PY'
import json,sys,os
s=sys.argv[1]
# ENV 문자열일 수도 있고 파일 경로일 수도 있음 → 우선 파일 여부 체크
if os.path.exists(s):
  with open(s,'r',encoding='utf-8') as f:
    d=json.load(f)
else:
  d=json.loads(s)
print(json.dumps(d, ensure_ascii=False, separators=(',',':')))
PY
}

# 파일에서 name 추출: {"name": "..."} 없으면 파일명 사용
extract_name_from_file() {
  python3 - "$1" <<'PY'
import json,sys,os
p=sys.argv[1]
with open(p,'r',encoding='utf-8') as f:
    d=json.load(f)
name=d.get('name') or os.path.splitext(os.path.basename(p))[0]
print(name)
PY
}

upsert_payload() {
  local name="$1"; local json_compact="$2"
  # PUT /connectors/{name}/config (create or update)
  local http_code
  http_code="$(printf '%s' "$json_compact" | curl -sS -X PUT \
    -H 'Content-Type: application/json' \
    "${AUTH_ARGS[@]}" \
    --data-binary @- \
    -o /dev/null -w '%{http_code}' \
    "${CONNECT_HOST}/connectors/${name}/config" || true)"
  echo "$http_code"
}

upsert_env_connector() {
  local name="$1"
  local var="CONNECTOR_${name}"
  local raw="${!var:-}"
  if [ -z "$raw" ]; then
    echo "[WARN] ${var} is empty. Skipped."
    return 0
  fi
  local compact; compact="$(compact_json "$raw")"
  echo "[INFO] Upserting (ENV) ${name}"
  local code; code="$(upsert_payload "$name" "$compact")"
  case "$code" in
    200|201) echo "[OK] ${name} upserted (HTTP ${code})";;
    *)       echo "[ERROR] ${name} upsert failed (HTTP ${code})"; return 1;;
  esac
}

upsert_file_connector() {
  local file="$1"
  local name; name="$(extract_name_from_file "$file")"
  local compact; compact="$(compact_json "$file")"
  echo "[INFO] Upserting (FILE) ${name} from ${file}"
  local code; code="$(upsert_payload "$name" "$compact")"
  case "$code" in
    200|201) echo "[OK] ${name} upserted (HTTP ${code})";;
    *)       echo "[ERROR] ${name} upsert failed (HTTP ${code})"; return 1;;
  esac
}

# ----------------------------------------------------------------------------
# 7) 부팅 로그 & 워커 실행(백그라운드) → REST 대기 → 커넥터 업서트
# ----------------------------------------------------------------------------
echo "[BOOT] BS=${BOOTSTRAP_SERVERS}"
/etc/confluent/docker/run &
RUN_PID=$!

wait_for_connect

# ENV 기반 업서트
if [ -n "${CONNECTOR_NAMES:-}" ]; then
  for name in ${CONNECTOR_NAMES}; do
    upsert_env_connector "$name" || echo "[WARN] ENV upsert failed: $name"
  done
fi

# /connectors/*.json 업서트
shopt -s nullglob
for j in /connectors/*.json; do
  upsert_file_connector "$j" || echo "[WARN] FILE upsert failed: $j"
done
shopt -u nullglob

# ----------------------------------------------------------------------------
# 8) 메인 프로세스 대기
# ----------------------------------------------------------------------------
wait "$RUN_PID"
