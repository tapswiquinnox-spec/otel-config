#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-signoz-system}"
CONFIGMAP_NAME="${CONFIGMAP_NAME:-signoz-otel-collector}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIVE_CM_FILE="$SCRIPT_DIR/signoz-otel-collector-live.yaml"
UPDATED_CM_FILE="$SCRIPT_DIR/signoz-otel-collector-updated.yaml"
TMP_PATCH_FILE="$SCRIPT_DIR/signoz-otel-collector-patch.json"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

echo "==> Validating prerequisites"
require_cmd kubectl
require_cmd python

echo "==> Fetching live ConfigMap from cluster"
kubectl get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" -o yaml > "$LIVE_CM_FILE"

echo "==> Building patch payload for data.otel-collector-config.yaml only"
python - "$TMP_PATCH_FILE" <<'PY'
import json
import sys
from pathlib import Path

patch_path = Path(sys.argv[1])
collector_cfg = """connectors:
  signozmeter:
    dimensions:
    - name: service.name
    - name: deployment.environment
    - name: host.name
    metrics_flush_interval: 1h
exporters:
  clickhouselogsexporter:
    dsn: tcp://${env:CLICKHOUSE_USER}:${env:CLICKHOUSE_PASSWORD}@${env:CLICKHOUSE_HOST}:${env:CLICKHOUSE_PORT}/${env:CLICKHOUSE_LOG_DATABASE}
    timeout: 10s
    use_new_schema: true
  clickhousetraces:
    datasource: tcp://${env:CLICKHOUSE_USER}:${env:CLICKHOUSE_PASSWORD}@${env:CLICKHOUSE_HOST}:${env:CLICKHOUSE_PORT}/${env:CLICKHOUSE_TRACE_DATABASE}
    low_cardinal_exception_grouping: ${env:LOW_CARDINAL_EXCEPTION_GROUPING}
    use_new_schema: true
  metadataexporter:
    cache:
      provider: in_memory
    dsn: tcp://${env:CLICKHOUSE_USER}:${env:CLICKHOUSE_PASSWORD}@${env:CLICKHOUSE_HOST}:${env:CLICKHOUSE_PORT}/signoz_metadata
    enabled: true
    tenant_id: ${env:TENANT_ID}
    timeout: 10s
  signozclickhousemeter:
    dsn: tcp://${env:CLICKHOUSE_USER}:${env:CLICKHOUSE_PASSWORD}@${env:CLICKHOUSE_HOST}:${env:CLICKHOUSE_PORT}/${env:CLICKHOUSE_METER_DATABASE}
    sending_queue:
      enabled: false
    timeout: 45s
  signozclickhousemetrics:
    dsn: tcp://${env:CLICKHOUSE_USER}:${env:CLICKHOUSE_PASSWORD}@${env:CLICKHOUSE_HOST}:${env:CLICKHOUSE_PORT}/${env:CLICKHOUSE_DATABASE}
    timeout: 45s
  kafka:
    brokers:
      - topology-kafka-kafka-bootstrap.sentinel.svc.cluster.local:9092
    topic: traces-topic
    encoding: otlp_json
    partition_traces_by_id: true
  kafka/metrics:
    brokers:
      - topology-kafka-kafka-bootstrap.sentinel.svc.cluster.local:9092
    topic: otel-metrics-topic
    encoding: otlp_json
    partition_traces_by_id: false
  kafka/logs:
    brokers:
      - topology-kafka-kafka-bootstrap.sentinel.svc.cluster.local:9092
    topic: otel-logs-topic
    encoding: otlp_json
    partition_traces_by_id: false
    producer:
      compression: snappy
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  pprof:
    endpoint: localhost:1777
  zpages:
    endpoint: localhost:55679
processors:
  batch:
    send_batch_size: 1024
    send_batch_max_size: 2048
    timeout: 5s
  batch/logs:
    send_batch_size: 16
    send_batch_max_size: 32
    timeout: 1s
  batch/meter:
    send_batch_max_size: 2048
    send_batch_size: 1024
    timeout: 5s
  signozspanmetrics/delta:
    aggregation_temporality: AGGREGATION_TEMPORALITY_DELTA
    dimensions:
    - default: default
      name: service.namespace
    - default: default
      name: deployment.environment
    - name: signoz.collector.id
    dimensions_cache_size: 100000
    latency_histogram_buckets:
    - 100us
    - 1ms
    - 2ms
    - 6ms
    - 10ms
    - 50ms
    - 100ms
    - 250ms
    - 500ms
    - 1000ms
    - 1400ms
    - 2000ms
    - 5s
    - 10s
    - 20s
    - 40s
    - 60s
    metrics_exporter: signozclickhousemetrics
receivers:
  httplogreceiver/heroku:
    endpoint: 0.0.0.0:8081
    source: heroku
  httplogreceiver/json:
    endpoint: 0.0.0.0:8082
    source: json
  jaeger:
    protocols:
      grpc:
        endpoint: 0.0.0.0:14250
      thrift_http:
        endpoint: 0.0.0.0:14268
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        max_recv_msg_size_mib: 16
      http:
        endpoint: 0.0.0.0:4318
service:
  extensions:
  - health_check
  - zpages
  - pprof
  pipelines:
    logs:
      exporters:
      - clickhouselogsexporter
      - metadataexporter
      - signozmeter
      - kafka/logs
      processors:
      - batch/logs
      receivers:
      - otlp
      - httplogreceiver/heroku
      - httplogreceiver/json
    metrics:
      exporters:
      - metadataexporter
      - signozclickhousemetrics
      - signozmeter
      - kafka/metrics
      processors:
      - batch
      receivers:
      - otlp
    metrics/meter:
      exporters:
      - signozclickhousemeter
      - kafka/metrics
      processors:
      - batch/meter
      receivers:
      - signozmeter
    traces:
      exporters:
      - clickhousetraces
      - kafka
      - metadataexporter
      - signozmeter
      processors:
      - signozspanmetrics/delta
      - batch
      receivers:
      - otlp
      - jaeger
  telemetry:
    logs:
      encoding: json
"""

patch = {
    "data": {
        "otel-collector-config.yaml": collector_cfg
    }
}
patch_path.write_text(json.dumps(patch), encoding="utf-8")
PY

echo "==> Patching ConfigMap (only data.otel-collector-config.yaml)"
kubectl patch configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" --type merge --patch-file "$TMP_PATCH_FILE"

echo "==> Saving updated ConfigMap locally"
kubectl get configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" -o yaml > "$UPDATED_CM_FILE"

echo "==> Done"
echo "Live snapshot   : $LIVE_CM_FILE"
echo "Updated snapshot: $UPDATED_CM_FILE"
