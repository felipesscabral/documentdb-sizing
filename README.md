# collect_documentdb_sizing.sh

Script bash de código aberto, disponibilizado exclusivamente como exemplo, para coleta completa de métricas de sizing de clusters Amazon DocumentDB, com foco em subsidiar processos de migração e dimensionamento para MongoDB Atlas.

Combina AWS CLI v2 — para descoberta de clusters e coleta de métricas no CloudWatch — com mongosh — para coleta interna de databases, collections e índices — sem dependências adicionais além dessas ferramentas.

Este material é fornecido apenas para fins de referência. Sua utilização, adaptação e execução são de inteira responsabilidade do usuário. Os desenvolvedores e mantenedores deste código não assumem qualquer responsabilidade por problemas, falhas, impactos, perdas ou danos decorrentes de seu uso, inclusive em ambientes de teste ou produção.
---

## O que é coletado

### Por cluster

| Categoria | Dados |
|---|---|
| **Infraestrutura** | Cluster ID, endpoint, porta, versão do engine, Multi-AZ |
| **CloudWatch (7 dias)** | CPU avg/max, FreeableMemory avg, VolumeReadIOPs avg, DatabaseConnections avg |

### Por database

| Campo | Descrição |
|---|---|
| `size_mb` | Tamanho dos dados (dataSize) em MB |
| `storage_mb` | Tamanho em disco (storageSize) em MB |
| `index_size_mb` | Tamanho total dos índices em MB |

### Por collection

| Campo | Descrição |
|---|---|
| `doc_count` | Quantidade de documentos |
| `size_mb` | Tamanho dos dados em MB |
| `storage_mb` | Tamanho em disco em MB |
| `avg_doc_kb` | Tamanho médio de documento em KB |
| `index_size_mb` | Tamanho total dos índices da collection em MB |
| `index_count` | Quantidade de índices |

### Por índice

| Campo | Descrição |
|---|---|
| `index_name` | Nome do índice |
| `composition` | Composição legível: `campo:ASC, outro:DESC` |
| `fields` | Campos separados por ` \| ` |
| `directions` | Direções separadas por ` \| ` (ASC / DESC / text / 2dsphere) |
| `unique` | Se o índice é único |
| `sparse` | Se o índice é sparse |
| `ttl_seconds` | Valor de `expireAfterSeconds` (TTL index) |
| `partial_filter` | Expressão de filtro parcial, se houver |

### Métricas CloudWatch coletadas

| Métrica | Estatísticas | Namespace |
|---|---|---|
| `CPUUtilization` | Average, Maximum | `AWS/DocDB` |
| `FreeableMemory` | Average | `AWS/DocDB` |
| `VolumeReadIOPs` | Average | `AWS/DocDB` |
| `DatabaseConnections` | Average | `AWS/DocDB` |

> As métricas são coletadas por **instância primária** de cada cluster com granularidade horária nos últimos **7 dias**.

---

## Pré-requisitos

| Ferramenta | Versão mínima | Instalação |
|---|---|---|
| `aws cli` | v2 | [docs.aws.amazon.com/cli](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| `mongosh` | qualquer | [mongodb.com/try/download/shell](https://www.mongodb.com/try/download/shell) |
| `jq` | 1.6+ | `apt install jq` / `yum install jq` / `brew install jq` |
| `curl` | qualquer | Pré-instalado na maioria dos sistemas |

### Permissões IAM necessárias

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBClusters",
        "secretsmanager:GetSecretValue",
        "cloudwatch:GetMetricStatistics"
      ],
      "Resource": "*"
    }
  ]
}
```

> `secretsmanager:GetSecretValue` é necessário apenas se as credenciais forem gerenciadas via AWS Secrets Manager. Caso contrário, pode ser omitida.

> Todas as ações são **somente leitura**. Nenhuma escrita ou modificação é realizada nos clusters.

### Conectividade de rede

- A máquina que executar o script precisa ter acesso à **porta 27017** (ou a porta configurada) dos clusters DocumentDB
- Se os clusters estiverem em **VPC privada**, execute a partir de uma instância EC2 na mesma VPC ou via **AWS Systems Manager Session Manager**
- O **Security Group** do cluster deve permitir inbound na porta do cluster a partir do IP ou SG da máquina de coleta

---

## Instalação

```bash
git clone <repo-url>
cd <repo>
chmod +x collect_documentdb_sizing.sh
```

### Certificado TLS

O script baixa automaticamente o certificado global da AWS na primeira execução. Em ambientes sem acesso à internet, faça o download manual:

```bash
curl -sSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
     -o /tmp/global-bundle.pem

export TLS_CA_FILE=/tmp/global-bundle.pem
```

---

## Uso

```bash
# Configuração mínima — credenciais via variável de ambiente
DOCDB_USER=admin DOCDB_PASS='suaSenha' AWS_REGION=us-east-1 \
  ./collect_documentdb_sizing.sh

# Com credenciais no AWS Secrets Manager (padrão automático)
# O script busca o secret: docdb/<cluster-id>/credentials
# Campos esperados: { "username": "...", "password": "..." }
AWS_REGION=sa-east-1 ./collect_documentdb_sizing.sh

# Com perfil AWS específico
AWS_PROFILE=minha-conta AWS_REGION=us-east-1 \
  ./collect_documentdb_sizing.sh
```

### Variáveis de ambiente

| Variável | Padrão | Descrição |
|---|---|---|
| `AWS_REGION` | `us-east-1` | Região AWS onde os clusters estão |
| `DOCDB_USER` | _(vazio)_ | Usuário do DocumentDB |
| `DOCDB_PASS` | _(vazio)_ | Senha do DocumentDB |
| `TLS_CA_FILE` | `/tmp/global-bundle.pem` | Caminho para o certificado TLS da AWS |
| `AWS_PROFILE` | _(default)_ | Perfil do AWS CLI a utilizar |

### Credenciais via Secrets Manager

Se `DOCDB_USER` e `DOCDB_PASS` não forem definidos, o script tenta buscar automaticamente as credenciais no Secrets Manager usando o padrão:

```
docdb/<cluster-id>/credentials
```

O secret deve conter:

```json
{
  "username": "admin",
  "password": "suaSenha"
}
```

---

## Arquivos de saída

Os arquivos são gerados em um diretório com timestamp: `docdb_sizing_YYYYMMDD_HHMMSS/`

| Arquivo | Conteúdo |
|---|---|
| `<cluster-id>.json` | Dados brutos completos por cluster: CloudWatch + todos os databases, collections e índices |
| `sizing_report.json` | Consolidado de todos os clusters em um único JSON |
| `sizing_summary.csv` | **Uma linha por collection** — doc_count, tamanhos, índices |
| `indexes_detail.csv` | **Uma linha por índice** — composição, campos, direções e flags |

### Exemplo de `sizing_summary.csv`

```
cluster_id,database,collection,doc_count,size_mb,storage_mb,avg_doc_kb,index_size_mb,index_count
my-cluster,orders,transactions,2500000,1024.5,1280.0,0.42,128.3,4
my-cluster,orders,customers,180000,45.2,56.0,0.26,12.1,3
```

### Exemplo de `indexes_detail.csv`

```
cluster_id,database,collection,index_name,composition,fields,directions,unique,sparse,ttl_seconds,partial_filter
my-cluster,orders,transactions,_id_,"_id:ASC",_id,ASC,false,false,,
my-cluster,orders,transactions,status_createdAt,"status:ASC, createdAt:DESC",status | createdAt,ASC | DESC,false,false,,
my-cluster,orders,transactions,session_ttl,"sessionToken:ASC",sessionToken,ASC,false,false,3600,
```

---

## Interpretação dos dados para sizing MongoDB Atlas

### Dimensionamento de cluster

| Métrica DocumentDB | Uso no sizing Atlas |
|---|---|
| Soma de `storage_mb` de todas as collections | Storage mínimo do cluster |
| `avg_doc_kb` | Tamanho médio de documento MongoDB (sem alterações de modelo) |
| `cpu_avg_pct` / `cpu_max_pct` | Baseline para escolha de tier de instância |
| `free_mem_avg_mb` | Avalia se o working set cabe em memória |
| `connections_avg` | Dimensionamento do connection pool no Atlas |
| `iops_avg` | Referência de IOPS para storage tier do Atlas |

### Análise de índices

| Sinal | Implicação |
|---|---|
| `index_size_mb` > 30% de `storage_mb` na collection | Alto overhead de índices — candidato a revisão |
| Índices com mesmos `fields` em ordens diferentes | Sobreposição de índices — consolidar no Atlas |
| `unique = false` em campos que deveriam ser únicos | Risco de integridade — adicionar constraint no Atlas |
| `ttl_seconds` presente | Recriar como TTL index no Atlas (`expireAfterSeconds`) |
| `partial_filter` presente | Recriar como partial index no Atlas — oportunidade de otimizar memória |
| `directions` com `text` | Recriar como Atlas Search index para melhor performance |
| `directions` com `2dsphere` | Recriar como índice geoespacial no Atlas |

### Alertas de atenção

- **`cpu_max_pct` > 85%** — picos de CPU; investigar queries sem índice antes de migrar
- **`free_mem_avg_mb` < 20% da RAM da instância** — working set maior que memória; considerar tier superior no Atlas
- **`index_count` > 10 em uma collection** — revisar quais índices são realmente usados; alto custo de escrita
- **`avg_doc_kb` > 50** — documentos grandes; avaliar compressão Zstandard disponível no Atlas

---

## Troubleshooting

**`MongoServerError: not authorized`**

O usuário não tem permissão de leitura. Conceda o role mínimo necessário:

```javascript
db.getSiblingDB('admin').grantRolesToUser('seuUsuario', [
  { role: 'readAnyDatabase', db: 'admin' }
])
```

**`SSL handshake failed` / `certificate verify failed`**

O certificado TLS não foi encontrado ou está corrompido:

```bash
# Verificar se existe
ls -la $TLS_CA_FILE

# Baixar novamente
curl -sSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
     -o /tmp/global-bundle.pem
```

**`An error occurred (AccessDeniedException)` — Secrets Manager**

A role IAM não tem permissão para acessar o secret. Use variáveis de ambiente como alternativa:

```bash
export DOCDB_USER=admin
export DOCDB_PASS='suaSenha'
```

**Cluster não aparece na listagem**

Confirme a região e o engine do cluster:

```bash
aws docdb describe-db-clusters \
  --region $AWS_REGION \
  --query 'DBClusters[*].[DBClusterIdentifier,Engine,Status]' \
  --output table
```

**`mongosh: command not found`**

```bash
# Amazon Linux
sudo yum install -y mongodb-mongosh

# Ubuntu / Debian
wget -qO - https://www.mongodb.org/static/pgp/server-7.0.asc | sudo apt-key add -
sudo apt-get install -y mongodb-mongosh

# macOS
brew install mongosh
```

---

## Notas

- O script é **somente leitura** e não realiza nenhuma alteração nos clusters ou databases
- Databases de sistema (`admin`, `local`, `config`, `system`) são automaticamente ignorados
- Em clusters com muitas collections, a execução pode levar alguns minutos por cluster
- As métricas CloudWatch usam granularidade **horária** com janela de **7 dias** — suficiente para identificar picos de workload
- Em ambientes **Multi-AZ**, o script coleta métricas apenas da instância primária
