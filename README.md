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
- **Mínimo de 8 GB de RAM** (VPS menores não precisam deste tuning)

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

> ⚠️ **Requisito mínimo**: 8 GB de RAM. VPS com menos memória não devem usar este script.

| RAM total | `shared_buffers` | `effective_cache_size` | `work_mem` | `maintenance_work_mem` |
|---|---:|---:|---:|---:|
| 8 GB | 2 GB | 6 GB | 32 MB | 256 MB |
| 12 GB | 3 GB | 9 GB | 32 MB | 256 MB |
| 16 GB | 4 GB | 12 GB | 32 MB | 512 MB |
| 24 GB | 6 GB | 18 GB | 32 MB | 512 MB |
| 32 GB+ | 8 GB | 24 GB | 32 MB | 1 GB |

| Parâmetro | Valor | Observação |
|---|---|---|
| `random_page_cost` | `1.1` (SSD) / `4.0` (HDD) | Custo de leitura aleatória de disco |
| `effective_io_concurrency` | `200` (SSD) / `2` (HDD) | Paralelismo de I/O estimado |
| `shm_size` | `256mb` | Valor seguro para PostgreSQL 16 com Docker |

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
