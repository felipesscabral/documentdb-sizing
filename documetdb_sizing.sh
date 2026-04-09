#!/bin/bash
# =============================================================================
# collect_documentdb_sizing.sh
# Coleta informações de sizing de clusters Amazon DocumentDB
# Requisitos: aws cli v2, mongosh (ou mongo), jq
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURAÇÃO
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-us-east-1}"
OUTPUT_DIR="./docdb_sizing_$(date +%Y%m%d_%H%M%S)"
REPORT_FILE="$OUTPUT_DIR/sizing_report.json"
CSV_FILE="$OUTPUT_DIR/sizing_summary.csv"

# Credenciais do DocumentDB (serão preenchidas via AWS Secrets Manager ou manual)
DOCDB_USER="${DOCDB_USER:-}"
DOCDB_PASS="${DOCDB_PASS:-}"
TLS_CA_FILE="${TLS_CA_FILE:-/tmp/global-bundle.pem}"

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# FUNÇÕES UTILITÁRIAS
# ---------------------------------------------------------------------------
log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "ERRO: $*" >&2; exit 1; }

command -v aws     >/dev/null 2>&1 || die "aws cli não encontrado"
command -v mongosh >/dev/null 2>&1 || command -v mongo >/dev/null 2>&1 || die "mongosh/mongo não encontrado"
command -v jq      >/dev/null 2>&1 || die "jq não encontrado"

MONGO_BIN=$(command -v mongosh 2>/dev/null || command -v mongo)

# ---------------------------------------------------------------------------
# BAIXA O CERTIFICADO TLS DA AWS (se necessário)
# ---------------------------------------------------------------------------
if [[ ! -f "$TLS_CA_FILE" ]]; then
  log "Baixando certificado TLS global da AWS..."
  curl -sSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o "$TLS_CA_FILE"
fi

# ---------------------------------------------------------------------------
# DESCOBRE TODOS OS CLUSTERS DOCUMENTDB NA REGIÃO
# ---------------------------------------------------------------------------
log "Listando clusters DocumentDB na região $AWS_REGION..."

CLUSTERS=$(aws docdb describe-db-clusters \
  --region "$AWS_REGION" \
  --query "DBClusters[?Engine=='docdb'].[DBClusterIdentifier,Endpoint,Port,EngineVersion,MultiAZ,DBClusterMembers[0].DBInstanceIdentifier]" \
  --output json)

CLUSTER_COUNT=$(echo "$CLUSTERS" | jq 'length')
log "Encontrado(s) $CLUSTER_COUNT cluster(s)."

# Se não tiver usuário ainda, tenta buscar do Secrets Manager
fetch_credentials() {
  local cluster_id="$1"
  # Tenta padrão de nome de secret: docdb/<cluster-id>/credentials
  local secret_id="docdb/${cluster_id}/credentials"
  log "Buscando credenciais no Secrets Manager: $secret_id"
  local secret
  secret=$(aws secretsmanager get-secret-value \
    --region "$AWS_REGION" \
    --secret-id "$secret_id" \
    --query SecretString --output text 2>/dev/null || echo "{}")
  DOCDB_USER=$(echo "$secret" | jq -r '.username // empty')
  DOCDB_PASS=$(echo "$secret" | jq -r '.password // empty')
}

# ---------------------------------------------------------------------------
# SCRIPT JAVASCRIPT EXECUTADO DENTRO DO MONGOSH
# Coleta: databases, collections, índices, tamanhos, cardinalidade
# ---------------------------------------------------------------------------
MONGO_SCRIPT=$(cat <<'JSEOF'
// Retorna todos os dados de sizing em JSON
var result = { clusters_ts: new Date().toISOString(), databases: [] };

var adminDbs = db.adminCommand({ listDatabases: 1 });
adminDbs.databases.forEach(function(dbInfo) {
  var dbName = dbInfo.name;
  if (["admin","local","config","system"].indexOf(dbName) !== -1) return;

  var targetDb  = db.getSiblingDB(dbName);
  var dbStats   = targetDb.stats(1024 * 1024); // em MB
  var collNames = targetDb.getCollectionNames();

  var dbEntry = {
    name:          dbName,
    size_mb:       dbStats.dataSize   || 0,
    storage_mb:    dbStats.storageSize || 0,
    index_size_mb: dbStats.indexSize  || 0,
    collections:   []
  };

  collNames.forEach(function(collName) {
    var coll      = targetDb.getCollection(collName);
    var collStats = coll.stats(1024 * 1024);
    var indexes   = coll.getIndexes();
    var indexDetails = [];

    indexes.forEach(function(idx) {
      // Tamanho individual de cada índice via $indexStats (DocumentDB compat.)
      var idxSizeMb = 0;
      try {
        var idxStats = coll.aggregate([
          { $indexStats: {} },
          { $match: { name: idx.name } }
        ]).toArray();
        if (idxStats.length > 0 && idxStats[0].host) {
          // tamanho não disponível diretamente no $indexStats; usa proporção
        }
      } catch(e) {}

      // Desmonta o objeto key em arrays legíveis
      // ex: { status: 1, createdAt: -1 }  →  fields: ["status","createdAt"]
      //                                       directions: ["ASC","DESC"]
      var fields     = [];
      var directions = [];
      Object.keys(idx.key).forEach(function(field) {
        fields.push(field);
        var dir = idx.key[field];
        if      (dir ===  1)        directions.push("ASC");
        else if (dir === -1)        directions.push("DESC");
        else if (dir === "2dsphere") directions.push("2dsphere");
        else if (dir === "text")    directions.push("text");
        else                        directions.push(String(dir));
      });

      indexDetails.push({
        name:             idx.name,
        fields:           fields,           // ["campo1","campo2"]
        directions:       directions,        // ["ASC","DESC"]
        fields_str:       fields.join(" | "),      // "campo1 | campo2"
        composition_str:  fields.map(function(f,i){ return f+":"+directions[i]; }).join(", "),
        unique:           idx.unique   || false,
        sparse:           idx.sparse   || false,
        background:       idx.background || false,
        expireAfterSeconds:         idx.expireAfterSeconds || null,
        partialFilterExpression:    idx.partialFilterExpression || null
      });
    });

    dbEntry.collections.push({
      name:          collName,
      doc_count:     collStats.count        || 0,
      size_mb:       collStats.size         || 0,
      avg_doc_kb:    collStats.avgObjSize   ? (collStats.avgObjSize / 1024).toFixed(2) : 0,
      storage_mb:    collStats.storageSize  || 0,
      index_size_mb: collStats.totalIndexSize || 0,
      index_count:   indexes.length,
      indexes:       indexDetails
    });
  });

  result.databases.push(dbEntry);
});

print(JSON.stringify(result, null, 2));
JSEOF
)

# ---------------------------------------------------------------------------
# ITERA SOBRE CADA CLUSTER
# ---------------------------------------------------------------------------
ALL_RESULTS="[]"

echo "$CLUSTERS" | jq -c '.[]' | while IFS= read -r cluster_row; do
  CLUSTER_ID=$(echo "$cluster_row" | jq -r '.[0]')
  ENDPOINT=$(echo   "$cluster_row" | jq -r '.[1]')
  PORT=$(echo       "$cluster_row" | jq -r '.[2]')
  ENGINE_VER=$(echo "$cluster_row" | jq -r '.[3]')
  MULTI_AZ=$(echo   "$cluster_row" | jq -r '.[4]')

  log "============================================================"
  log "Cluster: $CLUSTER_ID | Endpoint: $ENDPOINT:$PORT | v$ENGINE_VER"

  # Busca credenciais se não foram passadas por variável de ambiente
  if [[ -z "$DOCDB_USER" || -z "$DOCDB_PASS" ]]; then
    fetch_credentials "$CLUSTER_ID"
  fi

  if [[ -z "$DOCDB_USER" || -z "$DOCDB_PASS" ]]; then
    log "AVISO: credenciais não encontradas para $CLUSTER_ID — pulando."
    continue
  fi

  # Coleta métricas via CloudWatch (instância primária)
  log "Coletando métricas CloudWatch..."
  INSTANCE_ID=$(echo "$cluster_row" | jq -r '.[5]')
  END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  START_TIME=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-7d   +%Y-%m-%dT%H:%M:%SZ)  # macOS fallback

  get_cw_metric() {
    local metric="$1"
    aws cloudwatch get-metric-statistics \
      --region "$AWS_REGION" \
      --namespace "AWS/DocDB" \
      --metric-name "$metric" \
      --dimensions Name=DBInstanceIdentifier,Value="$INSTANCE_ID" \
      --start-time "$START_TIME" \
      --end-time   "$END_TIME" \
      --period 3600 \
      --statistics Average Maximum \
      --query 'sort_by(Datapoints, &Timestamp)[-1].[Average,Maximum]' \
      --output json 2>/dev/null || echo "[0,0]"
  }

  CW_CPU=$(get_cw_metric "CPUUtilization")
  CW_MEM=$(get_cw_metric "FreeableMemory")
  CW_IOPS=$(get_cw_metric "VolumeReadIOPs")
  CW_CONN=$(get_cw_metric "DatabaseConnections")

  # Coleta métricas internas via mongosh
  log "Conectando ao cluster e coletando métricas de bancos/coleções..."
  CONN_STRING="mongodb://${DOCDB_USER}:${DOCDB_PASS}@${ENDPOINT}:${PORT}/?tls=true&tlsCAFile=${TLS_CA_FILE}&retryWrites=false"

  MONGO_OUT=$("$MONGO_BIN" "$CONN_STRING" --quiet --eval "$MONGO_SCRIPT" 2>/dev/null) || {
    log "AVISO: falha ao conectar em $CLUSTER_ID"
    continue
  }

  # Salva JSON bruto por cluster
  CLUSTER_FILE="$OUTPUT_DIR/${CLUSTER_ID}.json"
  echo "$MONGO_OUT" | jq \
    --arg cluster_id "$CLUSTER_ID" \
    --arg endpoint   "$ENDPOINT" \
    --arg port       "$PORT" \
    --arg engine_ver "$ENGINE_VER" \
    --arg multi_az   "$MULTI_AZ" \
    --argjson cw_cpu  "$CW_CPU" \
    --argjson cw_mem  "$CW_MEM" \
    --argjson cw_iops "$CW_IOPS" \
    --argjson cw_conn "$CW_CONN" \
    '{
      cluster_id:  $cluster_id,
      endpoint:    $endpoint,
      port:        $port,
      engine_ver:  $engine_ver,
      multi_az:    $multi_az,
      cloudwatch: {
        cpu_avg_pct:     $cw_cpu[0],
        cpu_max_pct:     $cw_cpu[1],
        free_mem_avg_mb: ($cw_mem[0] / 1048576),
        iops_avg:        $cw_iops[0],
        connections_avg: $cw_conn[0]
      },
      data: .
    }' > "$CLUSTER_FILE"

  log "Salvo: $CLUSTER_FILE"
done

# ---------------------------------------------------------------------------
# CONSOLIDA TODOS OS ARQUIVOS EM UM RELATÓRIO ÚNICO
# ---------------------------------------------------------------------------
log "Consolidando relatório final..."
jq -s '.' "$OUTPUT_DIR"/*.json > "$REPORT_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# GERA CSV RESUMO (nível collection)
# ---------------------------------------------------------------------------
log "Gerando CSV de resumo (collections)..."
echo "cluster_id,database,collection,doc_count,size_mb,storage_mb,avg_doc_kb,index_size_mb,index_count" > "$CSV_FILE"

jq -r '.[] |
  .cluster_id as $cid |
  .data.databases[] |
  .name as $db |
  .collections[] |
  [$cid, $db, .name, .doc_count, .size_mb, .storage_mb, .avg_doc_kb, .index_size_mb, .index_count] |
  @csv' "$REPORT_FILE" >> "$CSV_FILE" 2>/dev/null || true

# CSV detalhado de índices (uma linha por índice)
INDEX_CSV="$OUTPUT_DIR/indexes_detail.csv"
log "Gerando CSV detalhado de índices..."
echo "cluster_id,database,collection,index_name,composition,fields,directions,unique,sparse,ttl_seconds,partial_filter" > "$INDEX_CSV"

jq -r '.[] |
  .cluster_id as $cid |
  .data.databases[] |
  .name as $db |
  .collections[] |
  .name as $coll |
  .indexes[] |
  [
    $cid,
    $db,
    $coll,
    .name,
    .composition_str,
    .fields_str,
    (.directions | join(" | ")),
    (.unique     | tostring),
    (.sparse     | tostring),
    (.expireAfterSeconds | if . == null then "" else tostring end),
    (.partialFilterExpression | if . == null then "" else tostring end)
  ] |
  @csv' "$REPORT_FILE" >> "$INDEX_CSV" 2>/dev/null || true

# ---------------------------------------------------------------------------
# SUMÁRIO NO TERMINAL
# ---------------------------------------------------------------------------
log "============================================================"
log "SUMÁRIO"
log "============================================================"
jq -r '.[] | "Cluster: \(.cluster_id)\n  CPU avg/max: \(.cloudwatch.cpu_avg_pct | floor)% / \(.cloudwatch.cpu_max_pct | floor)%\n  Conexões avg: \(.cloudwatch.connections_avg | floor)\n  Databases: \(.data.databases | length)\n  Collections: \(.data.databases[].collections | length) (por db)\n"' \
  "$REPORT_FILE" 2>/dev/null || log "(sem dados para exibir)"

log "Arquivos gerados em: $OUTPUT_DIR"
log "  Relatório JSON : $REPORT_FILE"
log "  Resumo CSV     : $CSV_FILE"
log "  Índices CSV    : $INDEX_CSV"
