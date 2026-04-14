# collect_documentdb_sizing

Script bash de código aberto para coleta completa de métricas de sizing de clusters Amazon DocumentDB, com foco em subsidiar processos de migração e dimensionamento para MongoDB Atlas.

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
| `size_mb` | Tamanho dos dados em MB (`storageSize` — o DocumentDB não expõe `dataSize`) |
| `storage_mb` | Tamanho em disco (storageSize) em MB |
| `index_size_mb` | Tamanho total dos índices em MB |

### Por collection

| Campo | Descrição |
|---|---|
| `doc_count` | Quantidade de documentos ativos (documentos expirados por TTL não são contados) |
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

| Métrica | Dimensão | Estatísticas | Namespace |
|---|---|---|---|
| `CPUUtilization` | DBInstanceIdentifier | Average, Maximum | `AWS/DocDB` |
| `FreeableMemory` | DBInstanceIdentifier | Average | `AWS/DocDB` |
| `VolumeReadIOPs` | DBClusterIdentifier | Average | `AWS/DocDB` |
| `DatabaseConnections` | DBInstanceIdentifier | Average | `AWS/DocDB` |

> As métricas são coletadas pela **instância primária** de cada cluster com granularidade horária nos últimos **7 dias**.

---

## Pré-requisitos

| Ferramenta | Versão mínima | Instalação |
|---|---|---|
| `aws cli` | v2 | [docs.aws.amazon.com/cli](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| `mongosh` | qualquer | [mongodb.com/try/download/shell](https://www.mongodb.com/try/download/shell) |
| `jq` | 1.6+ | `apt install jq` / `yum install jq` / `brew install jq` |
| `curl` | qualquer | Pré-instalado na maioria dos sistemas |
| `python3` | 3.x | Pré-instalado na maioria dos sistemas |
| `session-manager-plugin` | qualquer | Apenas se usar modo túnel SSM — ver seção abaixo |

### Permissões IAM necessárias

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "docdb:DescribeDBClusters",
        "cloudwatch:GetMetricStatistics",
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "*"
    }
  ]
}
```

> `secretsmanager:GetSecretValue` é necessário apenas se as credenciais forem gerenciadas via AWS Secrets Manager.
> `ssm:StartSession` é necessário apenas no modo túnel SSM.

> Todas as ações são **somente leitura**. Nenhuma escrita ou modificação é realizada nos clusters.

---

## Conectividade de rede

O DocumentDB **não possui endpoint público** — por design da AWS, só é acessível de dentro da VPC. O script suporta dois modos de conectividade, selecionados automaticamente pela variável `EC2_INSTANCE_ID`:

| Situação | Modo | O que fazer |
|---|---|---|
| Rodando em EC2 / EKS / Lambda na mesma VPC | **Direto** | Não define `EC2_INSTANCE_ID` |
| Tem VPN ou Direct Connect para a VPC | **Direto** | Não define `EC2_INSTANCE_ID` |
| Máquina local sem VPN (laptop, CI externo) | **Túnel SSM** | Define `EC2_INSTANCE_ID=<id-de-ec2-na-vpc>` |

### Modo túnel SSM

Quando `EC2_INSTANCE_ID` está definido, o script abre automaticamente um túnel SSM para cada cluster e conecta via `localhost`, sem necessidade de SSH key ou VPN.

**Pré-requisito do túnel:**

```bash
# macOS
brew install --cask session-manager-plugin

# Linux — consulte:
# https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
```

**Permissão IAM adicional para o túnel:**

```json
{
  "Effect": "Allow",
  "Action": ["ssm:StartSession"],
  "Resource": "*"
}
```

**Requisito na EC2 usada como ponto de salto:**
- Ter o SSM Agent ativo (padrão em Amazon Linux 2 / 2023)
- Ter a policy `AmazonSSMManagedInstanceCore` na role da instância
- Ter acesso de rede ao Security Group do DocumentDB na porta 27017

---

## Instalação

```bash
git clone <repo-url>
cd documentdb-sizing
chmod +x collect_documentdb_sizing
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

### Modo direto — dentro da VPC ou com VPN

```bash
# Credenciais via variável de ambiente
DOCDB_USER=admin DOCDB_PASS='suaSenha' AWS_REGION=us-east-1 \
  ./collect_documentdb_sizing

# Credenciais via AWS Secrets Manager (padrão automático)
# O script busca o secret: docdb/<cluster-id>/credentials
AWS_REGION=sa-east-1 ./collect_documentdb_sizing

# Com perfil AWS específico
AWS_PROFILE=minha-conta AWS_REGION=us-east-1 \
  ./collect_documentdb_sizing
```

### Modo túnel SSM — máquina local sem VPN

```bash
# Define EC2_INSTANCE_ID com o ID de uma instância EC2 na mesma VPC do DocumentDB
EC2_INSTANCE_ID=i-0abc1234def567890 \
DOCDB_USER=admin DOCDB_PASS='suaSenha' AWS_REGION=us-east-1 \
  ./collect_documentdb_sizing
```

O script abre um túnel SSM por cluster automaticamente, coleta os dados e encerra os túneis ao final.

### Variáveis de ambiente

| Variável | Padrão | Descrição |
|---|---|---|
| `AWS_REGION` | `us-east-1` | Região AWS onde os clusters estão |
| `DOCDB_USER` | _(vazio)_ | Usuário do DocumentDB |
| `DOCDB_PASS` | _(vazio)_ | Senha do DocumentDB |
| `TLS_CA_FILE` | `/tmp/global-bundle.pem` | Caminho para o certificado TLS da AWS |
| `AWS_PROFILE` | _(default)_ | Perfil do AWS CLI a utilizar |
| `EC2_INSTANCE_ID` | _(vazio)_ | ID de EC2 na VPC para túnel SSM (modo local sem VPN) |
| `SSM_TUNNEL_BASE_PORT` | `47017` | Porta local inicial para os túneis SSM |

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

**Script não retorna nada / "nenhum cluster coletado"**

A causa mais comum é falta de conectividade de rede com o DocumentDB (que não tem endpoint público).

- Se estiver fora da VPC sem VPN: defina `EC2_INSTANCE_ID` para usar o modo túnel SSM
- Verifique se as credenciais estão corretas (`DOCDB_USER` / `DOCDB_PASS`)
- Confirme que o Security Group do cluster permite inbound na porta 27017

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

**`session-manager-plugin not found`** (modo túnel SSM)

```bash
# macOS
brew install --cask session-manager-plugin
```

**Túnel SSM falha ao abrir**

Verifique o log gerado em `docdb_sizing_*/ssm_tunnel_<cluster>.log`. Causas comuns:

- A EC2 não tem o SSM Agent ativo ou não tem a policy `AmazonSSMManagedInstanceCore`
- A EC2 não tem acesso de rede ao endpoint do DocumentDB
- O documento `AWS-StartPortForwardingSessionToRemoteHost` não está disponível na região

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

- O script é **somente leitura** — nenhuma escrita ou modificação é realizada nos clusters ou databases
- Databases de sistema (`admin`, `local`, `config`, `system`) são automaticamente ignorados
- O DocumentDB não retorna `dataSize` em `db.stats()` — o campo `size_mb` usa `storageSize` como substituto
- Collections com TTL index podem apresentar `doc_count` menor que o total inserido — documentos expirados já foram removidos pelo DocumentDB
- Em clusters com muitas collections, a execução pode levar alguns minutos por cluster
- As métricas CloudWatch usam granularidade **horária** com janela de **7 dias**
- Em ambientes **Multi-AZ**, as métricas são coletadas apenas da instância primária
- `iops_avg` pode aparecer como `0` em clusters recém-criados — o CloudWatch leva algumas horas para acumular datapoints
