#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Kafka Connect Entrypoint
# =============================================================================

: "${KAFKA_URL:?e.g. ssl://host1:9096,ssl://host2:9096}"
: "${SCHEMA_REGISTRY_URL:?e.g. https://schema-registry:8081}"
: "${SSL_KEY_PASSWORD:?set SSL_KEY_PASSWORD}"
: "${CONNECT_GROUP_ID:?set CONNECT_GROUP_ID}"
: "${CONNECT_CONFIG_STORAGE_TOPIC:?set CONNECT_CONFIG_STORAGE_TOPIC}"
: "${CONNECT_OFFSET_STORAGE_TOPIC:?set CONNECT_OFFSET_STORAGE_TOPIC}"
: "${CONNECT_STATUS_STORAGE_TOPIC:?set CONNECT_STATUS_STORAGE_TOPIC}"

command -v curl >/dev/null
command -v python3 >/dev/null
command -v openssl >/dev/null

PORT="${PORT:-8083}"
export PORT

SRC_DIR="/secrets-src"
CHAIN="${SRC_DIR}/client-cert.pem"
KEY_IN="${SRC_DIR}/client-key.pem"
CA_PEM="${SRC_DIR}/ca-bundle.pem"

[ -s "$CHAIN" ]  || { echo "[ERR] missing $CHAIN"; exit 1; }
[ -s "$KEY_IN" ] || { echo "[ERR] missing $KEY_IN"; exit 1; }
[ -s "$CA_PEM" ] || { echo "[ERR] missing $CA_PEM"; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cp -f "$CHAIN" "${tmpdir}/chain.pem"
cp -f "$KEY_IN" "${tmpdir}/key.pem"

openssl pkcs12 -export -name client \
  -inkey "${tmpdir}/key.pem" -passin env:SSL_KEY_PASSWORD \
  -in "${tmpdir}/chain.pem" \
  -out "/tmp/keystore.p12" -passout env:SSL_KEY_PASSWORD
chmod 600 /tmp/keystore.p12 || true

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

export CONNECT_KEY_CONVERTER="io.confluent.connect.avro.AvroConverter"
export CONNECT_VALUE_CONVERTER="io.confluent.connect.avro.AvroConverter"
export CONNECT_KEY_CONVERTER_SCHEMA_REGISTRY_URL="${SCHEMA_REGISTRY_URL}"
export CONNECT_VALUE_CONVERTER_SCHEMA_REGISTRY_URL="${SCHEMA_REGISTRY_URL}"

export CONNECT_INTERNAL_KEY_CONVERTER="org.apache.kafka.connect.json.JsonConverter"
export CONNECT_INTERNAL_VALUE_CONVERTER="org.apache.kafka.connect.json.JsonConverter"
export CONNECT_INTERNAL_KEY_CONVERTER_SCHEMAS_ENABLE=false
export CONNECT_INTERNAL_VALUE_CONVERTER_SCHEMAS_ENABLE=false

export CONNECT_PLUGIN_PATH="/usr/share/java/connect-plugins"
HOST_DEFAULT="${HEROKU_DNS_DYNO_NAME:-${HEROKU_APP_NAME:-${HOSTNAME}}}"
export CONNECT_REST_ADVERTISED_HOST_NAME="${CONNECT_REST_ADVERTISED_HOST_NAME:-${HOST_DEFAULT}}"
export CONNECT_REST_ADVERTISED_PORT="${CONNECT_REST_ADVERTISED_PORT:-${PORT}}"
export CONNECT_LISTENERS="http://0.0.0.0:${PORT}"
export CONNECT_REST_ADVERTISED_LISTENERS="${CONNECT_REST_ADVERTISED_LISTENERS:-http://${CONNECT_REST_ADVERTISED_HOST_NAME}:${PORT}}"

export CONNECT_SECURITY_PROTOCOL="SSL"
export CONNECT_SSL_TRUSTSTORE_TYPE="PEM"
export CONNECT_SSL_TRUSTSTORE_LOCATION="${CA_PEM}"
export CONNECT_SSL_KEYSTORE_TYPE="PKCS12"
export CONNECT_SSL_KEYSTORE_LOCATION="/tmp/keystore.p12"
export CONNECT_SSL_KEYSTORE_PASSWORD="${SSL_KEY_PASSWORD}"
export CONNECT_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM=""

for P in CONNECT CONNECT_PRODUCER CONNECT_CONSUMER CONNECT_ADMIN; do
  export ${P}_BOOTSTRAP_SERVERS="$BOOTSTRAP_SERVERS"
  export ${P}_SECURITY_PROTOCOL="SSL"
  export ${P}_SSL_TRUSTSTORE_TYPE="PEM"
  export ${P}_SSL_TRUSTSTORE_LOCATION="${CA_PEM}"
  export ${P}_SSL_KEYSTORE_TYPE="PKCS12"
  export ${P}_SSL_KEYSTORE_LOCATION="/tmp/keystore.p12"
  export ${P}_SSL_KEYSTORE_PASSWORD="${SSL_KEY_PASSWORD}"
  export ${P}_SSL_ENDPOINT_IDENTIFICATION_ALGORITHM=""
done

BASE_URL="http://127.0.0.1:${PORT}"
CURL='curl -sS -L --max-time 10 --connect-timeout 3 -H Accept:application/json'

wait_connect_ready() {
  local tries=120 sleep_s=1 code
  for i in $(seq 1 "$tries"); do
    code="$(${CURL} -o /dev/null -w '%{http_code}' "${BASE_URL}/connectors" || true)"
    if [ "$code" = "200" ]; then
      echo "[INFO] REST ready (/connectors 200) after ${i}s"
      return 0
    fi
    sleep "$sleep_s"
  done
  echo "[ERROR] Connect REST not ready"
  return 1
}

name_from_path() { basename "$1" .json; }

compact_config_from_file() {
  # 파일이 {"config": {...}} 이면 내부만, 아니면 전체를 compact JSON으로 출력
  python3 - "$1" <<'PY'
import json,sys
p=sys.argv[1]
with open(p,'r',encoding='utf-8') as f: d=json.load(f)
cfg = d['config'] if isinstance(d,dict) and 'config' in d else d
print(json.dumps(cfg, ensure_ascii=False, separators=(',',':')))
PY
}

parse_connectors() { tr -d '\r\n' | grep -oE '"[^"]+"' | tr -d '"'; }

fetch_connectors() {
  local out code raw
  out="$(mktemp)"
  code="$(${CURL} "${BASE_URL}/connectors" -o "${out}" -w '%{http_code}' || true)"
  raw="$(cat "${out}" 2>/dev/null || true)"
  echo "[DEBUG] GET /connectors -> HTTP ${code} body=${raw}"
  if [ "$code" != "200" ]; then CONNECTORS_RAW=""; return 1; fi
  CONNECTORS_RAW="$(printf '%s' "$raw" | parse_connectors)"
  return 0
}

delete_connector() {
  local name="$1" code
  for i in $(seq 1 8); do
    code="$(${CURL} -o /dev/null -w '%{http_code}' -X DELETE \
      "${BASE_URL}/connectors/${name}?forward=true" || true)"
    case "$code" in
      200|204|404) echo "[OK] ${name} deleted (HTTP ${code})"; return 0 ;;
      409|5??)     echo "[WARN] ${name} delete retry ${i}/8 (HTTP ${code})"; sleep 2 ;;
      *)           echo "[WARN] ${name} delete failed (HTTP ${code})"; return 1 ;;
    esac
  done
  echo "[ERROR] ${name} delete exhausted retries"; return 1
}

upsert_file() {
  local file="$1" name body code out
  name="$(name_from_path "$file")"
  body="$(compact_config_from_file "$file")"
  out="$(mktemp)"
  code="$(printf '%s' "$body" | ${CURL} -o "${out}" -w '%{http_code}' \
         -H 'Content-Type: application/json' \
         -X PUT --data-binary @- \
         "${BASE_URL}/connectors/${name}/config?forward=true" || true)"
  echo "[DEBUG] PUT /connectors/${name}/config -> HTTP ${code} body=$(head -c 400 "${out}")"
  case "$code" in
    200|201) echo "[OK] upsert ${name}";;
    *)       echo "[WARN] upsert ${name} failed (HTTP ${code})"; return 1;;
  esac
}

reconcile_once() {
  local dir="/connectors"
  shopt -s nullglob
  local files=("${dir}"/*.json)
  shopt -u nullglob

  # (A) 파일 기반 Upsert
  if [ ${#files[@]} -gt 0 ]; then
    echo "[INFO] Upsert ${#files[@]} connector(s) from ${dir}"
    for f in "${files[@]}"; do
      upsert_file "$f" || true
    done
  else
    echo "[INFO] No connector JSON files found → skip upsert"
  fi

  # (B) 현재 커넥터 조회
  fetch_connectors || true
  if [ -z "${CONNECTORS_RAW:-}" ]; then
    echo "[INFO] Remote connectors: (none)"
    return 0
  fi
  echo "[INFO] Remote connectors:"; for n in ${CONNECTORS_RAW}; do echo "  - $n"; done

  # (C) 파일에 없는 커넥터는 삭제
  in_files() { local x="$1"; for f in "${files[@]}"; do [ "$(basename "$f" .json)" = "$x" ] && return 0; done; return 1; }
  for cur in ${CONNECTORS_RAW}; do
    if ! in_files "$cur"; then
      echo "[INFO] Deleting unmanaged connector: ${cur}"
      delete_connector "${cur}" || true
    fi
  done
}

echo "[INFO] Connect REST base = ${BASE_URL}"

/etc/confluent/docker/run &
RUN_PID=$!

if ! wait_connect_ready; then
  echo "[FATAL] REST not ready; stopping worker"
  kill "$RUN_PID" 2>/dev/null || true
  exit 1
fi

reconcile_once

wait "$RUN_PID"
