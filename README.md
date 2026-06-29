# 🐘 postgres-override

Script de tuning automático do PostgreSQL para instalações [Ticketz](https://github.com/ticketz-oss/ticketz) via `ticketz-docker-acme`.

## 📋 Sobre

Este script detecta os recursos da VPS (RAM, tipo de disco) e gera/atualiza o arquivo `docker-compose.override.yaml` dentro de `~/ticketz-docker-acme`, aplicando parâmetros otimizados ao serviço `postgres`.

- ✅ Detecta RAM total, vCPUs e tipo de disco (SSD/HDD)
- ✅ Calcula `shared_buffers`, `effective_cache_size`, `work_mem` e `maintenance_work_mem`
- ✅ Ajusta `random_page_cost` e `effective_io_concurrency` conforme o disco
- ✅ Preserva configurações existentes de outros serviços no override
- ✅ Faz backup automático do override anterior
- ✅ Pergunta antes de aplicar e oferece reinício do PostgreSQL

> ⚠️ **Compatibilidade**: Desenvolvido para instalações Ticketz via auto-instalador `ticketz-docker-acme`. Ajuste o caminho no script se necessário.

## 🏗️ Arquitetura

```
~/ticketz-docker-acme/          instalação Ticketz (auto-instalador)
  docker-compose.override.yaml  <- gerado/atualizado por este script
~/postgres-override/            este projeto
  postgres-override.sh
  README.md
  LICENSE
  CONTRIBUTING.md
```

## 🚀 Instalação

### Pré-requisitos

- Linux com Docker e Docker Compose
- Python 3 instalado
- Instalação Ticketz via `ticketz-docker-acme` em `~/ticketz-docker-acme`

### Setup

```bash
# Clone o repositório
git clone https://github.com/leostrongGG/postgres-override.git ~/postgres-override
cd ~/postgres-override
chmod +x postgres-override.sh
```

## 🛠️ Uso

```bash
cd ~/postgres-override
./postgres-override.sh
```

O script irá:

1. Mostrar os recursos detectados da VPS
2. Exibir os parâmetros calculados
3. Previsualizar o conteúdo final do `docker-compose.override.yaml`
4. Perguntar se deseja aplicar
5. Perguntar se deseja reiniciar toda a stack Ticketz (usando `sudo docker compose`)

## ⚙️ Fórmulas de cálculo

| Parâmetro | Fórmula | Observação |
|---|---|---|
| `shared_buffers` | `25% da RAM` | Limitado a `4GB` para cargas OLTP do Ticketz |
| `effective_cache_size` | `75% da RAM` | Estimativa de cache disponível no SO |
| `work_mem` | `25% da RAM / 100` | Limitado entre `16MB` e `64MB` |
| `maintenance_work_mem` | `~3% da RAM` | Limitado a `512MB` para evitar pressão no `/dev/shm` |
| `random_page_cost` | `1.1` (SSD) / `4.0` (HDD) | — |
| `effective_io_concurrency` | `200` (SSD) / `2` (HDD) | — |
| `shm_size` | fixo em `256mb` | Valor seguro para PostgreSQL 16 com Docker |

## 📝 Exemplo de saída

Para uma VPS com 16 GB de RAM e SSD:

```yaml
services:
  postgres:
    shm_size: '256mb'
    command: >
      postgres
      -c shared_buffers=4GB
      -c effective_cache_size=12GB
      -c work_mem=32MB
      -c maintenance_work_mem=512MB
      -c random_page_cost=1.1
      -c effective_io_concurrency=200
```

## 🔄 Merge com override existente

Se `~/ticketz-docker-acme/docker-compose.override.yaml` já existir, o script:

- Preserva outros serviços configurados
- Substitui apenas `shm_size` e `command` dentro de `services.postgres`
- Mantém backups anteriores em `~/ticketz-docker-acme/.postgres-override-backups/`

## 📄 Licença

MIT — veja [LICENSE](LICENSE) para mais detalhes.
