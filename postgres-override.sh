#!/bin/bash
# postgres-override.sh
# Gera/ajusta docker-compose.override.yaml com tuning do PostgreSQL
# para instalacoes Ticketz via ticketz-docker-acme.
#
# O script detecta recursos da VPS (RAM, vCPUs, disco) e cria/atualiza
# o arquivo ~/ticketz-docker-acme/docker-compose.override.yaml preservando
# configuracoes existentes de outros servicos.

set -euo pipefail

TARGET_DIR="${HOME}/ticketz-docker-acme"
OVERRIDE_FILE="${TARGET_DIR}/docker-compose.override.yaml"
BACKUP_DIR="${TARGET_DIR}/.postgres-override-backups"

# -----------------------------------------------------------------------------
# Funcoes utilitarias
# -----------------------------------------------------------------------------

bytes_to_mb() {
    local bytes="$1"
    echo "$(( (bytes + 524288) / 1048576 ))"
}

bytes_to_gb_rounded() {
    local bytes="$1"
    echo "$(( (bytes + 536870912) / 1073741824 ))"
}

format_mb() {
    local mb="$1"
    if [[ "$mb" -ge 1024 ]]; then
        echo "$((mb / 1024))GB"
    else
        echo "${mb}MB"
    fi
}

round_mb() {
    local mb="$1"
    # arredonda para multiplo de 64 MB
    echo "$(( (mb + 32) / 64 * 64 ))"
}

# -----------------------------------------------------------------------------
# Deteccao de recursos
# -----------------------------------------------------------------------------

detect_ram() {
    local kbytes
    kbytes=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    echo "$(( kbytes * 1024 ))"
}

detect_cpus() {
    nproc
}

detect_disk_type() {
    # retorna 'ssd' se detectar ROTA=0 em disco raiz, 'hdd' caso contrario
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*\]//')
    if [[ -z "$root_dev" ]]; then
        echo "ssd"
        return
    fi
    # remove particao
    local disk="$root_dev"
    disk="${disk%[0-9]*}"
    disk="${disk%p}"
    if [[ -z "$disk" ]]; then
        echo "ssd"
        return
    fi
    local rota
    rota=$(lsblk -d -no ROTA "$disk" 2>/dev/null | tr -d ' ')
    if [[ "$rota" == "0" ]]; then
        echo "ssd"
    else
        echo "hdd"
    fi
}

detect_disk_size() {
    df -B1 --output=size / | tail -n1 | tr -d ' '
}

# -----------------------------------------------------------------------------
# Calculo dos parametros PostgreSQL
# -----------------------------------------------------------------------------

calculate_params() {
    local ram_bytes="$1"
    local disk_type="$2"

    local ram_mb
    ram_mb=$(bytes_to_mb "$ram_bytes")

    # shared_buffers = 25% da RAM (limite pratico de 4GB para Ticketz OLTP)
    local shared_mb=$(( ram_mb / 4 ))
    if [[ "$shared_mb" -gt 4096 ]]; then
        shared_mb=4096
    fi
    shared_mb=$(round_mb "$shared_mb")

    # effective_cache_size = 75% da RAM
    local cache_mb=$(( ram_mb * 3 / 4 ))
    cache_mb=$(round_mb "$cache_mb")

    # work_mem = 25% da RAM / max_connections (padrao 100)
    # limitado entre 16MB e 64MB para evitar excesso
    local work_mb=$(( ram_mb / 4 / 100 ))
    if [[ "$work_mb" -lt 16 ]]; then
        work_mb=16
    elif [[ "$work_mb" -gt 64 ]]; then
        work_mb=64
    fi
    work_mb=$(round_mb "$work_mb")

    # maintenance_work_mem = ~3% da RAM, limitado a 512MB por seguranca
    # (evita estourar /dev/shm quando shm_size=256mb em operacoes de manutencao)
    local maint_mb=$(( ram_mb * 3 / 100 ))
    if [[ "$maint_mb" -gt 512 ]]; then
        maint_mb=512
    elif [[ "$maint_mb" -lt 128 ]]; then
        maint_mb=128
    fi
    maint_mb=$(round_mb "$maint_mb")

    # Parametros de I/O
    local rpc="4.0"
    local eio="2"
    if [[ "$disk_type" == "ssd" ]]; then
        rpc="1.1"
        eio="200"
    fi

    cat <<EOF
RAM_TOTAL_MB=${ram_mb}
DISK_TYPE=${disk_type}
SHARED_BUFFERS=$(format_mb "$shared_mb")
EFFECTIVE_CACHE_SIZE=$(format_mb "$cache_mb")
WORK_MEM=$(format_mb "$work_mb")
MAINTENANCE_WORK_MEM=$(format_mb "$maint_mb")
RANDOM_PAGE_COST=${rpc}
EFFECTIVE_IO_CONCURRENCY=${eio}
EOF
}

# -----------------------------------------------------------------------------
# Geracao do conteudo YAML do servico postgres
# -----------------------------------------------------------------------------

generate_postgres_yaml() {
    local sb="$1"
    local ecs="$2"
    local wm="$3"
    local mwm="$4"
    local rpc="$5"
    local eio="$6"

    cat <<EOF
  postgres:
    shm_size: '256mb'
    command: >
      postgres
      -c shared_buffers=${sb}
      -c effective_cache_size=${ecs}
      -c work_mem=${wm}
      -c maintenance_work_mem=${mwm}
      -c random_page_cost=${rpc}
      -c effective_io_concurrency=${eio}
EOF
}

# -----------------------------------------------------------------------------
# Merge do override existente com o novo bloco postgres
# -----------------------------------------------------------------------------

merge_override() {
    local existing_file="$1"
    local postgres_yaml="$2"
    local output_file="$3"

    python3 - "$existing_file" "$postgres_yaml" "$output_file" <<'PYEOF'
import sys
import re

existing_path = sys.argv[1]
postgres_yaml = sys.argv[2]
output_path = sys.argv[3]

postgres_block = postgres_yaml.rstrip() + "\n"

def fallback_merge(content):
    lines = content.splitlines()
    out = []
    i = 0
    inside_services = False
    inside_postgres = False
    postgres_indent = None
    inserted = False

    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip()
        indent = len(line) - len(stripped)

        if not inside_services:
            if re.match(r'^services:\s*$', stripped):
                inside_services = True
                out.append(line)
                i += 1
                continue
            out.append(line)
            i += 1
            continue

        # dentro de services
        if inside_postgres:
            # pula ate encontrar proximo servico ou fim do bloco services
            if line == '':
                out.append(line)
                i += 1
                continue
            if indent <= postgres_indent:
                # terminou o bloco postgres, insere o novo
                out.append(postgres_block)
                inserted = True
                inside_postgres = False
                out.append(line)
                i += 1
                continue
            i += 1
            continue

        # procurando postgres dentro de services
        if re.match(r'^postgres:\s*$', stripped) and indent == 2:
            inside_postgres = True
            postgres_indent = indent
            i += 1
            continue

        # se encontrou outro servico no nivel 2 e ainda nao inseriu postgres,
        # insere antes dele
        if indent == 2 and not inserted and re.match(r'^[a-zA-Z0-9_-]+:\s*$', stripped):
            out.append(postgres_block)
            inserted = True
            out.append(line)
            i += 1
            continue

        out.append(line)
        i += 1

    # Se estava dentro de postgres no final, insere o novo bloco
    if inside_postgres and not inserted:
        out.append(postgres_block)
        inserted = True

    # Se nunca entrou em services, adiciona services no topo
    if not inside_services:
        out.insert(0, postgres_block)
        out.insert(0, "services:")
        inserted = True

    # Se services existe mas nao achou postgres, adiciona no final
    if inside_services and not inserted:
        # remove linhas em branco no final
        while out and out[-1] == '':
            out.pop()
        out.append(postgres_block)

    return "\n".join(out) + "\n"

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False

with open(existing_path, 'r') as f:
    original = f.read()

if HAS_YAML:
    try:
        data = yaml.safe_load(original) or {}
        if not isinstance(data, dict):
            data = {}
        if 'services' not in data or data['services'] is None:
            data['services'] = {}

        # Preserva chaves customizadas de postgres, mas sobrescreve shm_size/command
        existing_postgres = data.get('services', {}).get('postgres', {}) or {}
        new_postgres = {k: v for k, v in existing_postgres.items() if k not in ('shm_size', 'command')}

        # Reconstroi command como lista de strings para manter formato legivel
        new_postgres['shm_size'] = '256mb'
        new_postgres['command'] = (
            "postgres\n"
            "-c shared_buffers={SHARED_BUFFERS}\n"
            "-c effective_cache_size={EFFECTIVE_CACHE_SIZE}\n"
            "-c work_mem={WORK_MEM}\n"
            "-c maintenance_work_mem={MAINTENANCE_WORK_MEM}\n"
            "-c random_page_cost={RANDOM_PAGE_COST}\n"
            "-c effective_io_concurrency={EFFECTIVE_IO_CONCURRENCY}"
        )
        data['services']['postgres'] = new_postgres

        with open(output_path, 'w') as f:
            yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
    except yaml.YAMLError as e:
        print(f"AVISO: YAML invalido ({e}). Usando merge manual.", file=sys.stderr)
        with open(output_path, 'w') as f:
            f.write(fallback_merge(original))
else:
    with open(output_path, 'w') as f:
        f.write(fallback_merge(original))
PYEOF
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    echo "==================================================================="
    echo "  PostgreSQL Override Generator para Ticketz"
    echo "==================================================================="
    echo ""

    # Verifica dependencias
    if ! command -v python3 &>/dev/null; then
        echo "ERRO: python3 nao encontrado. Instale python3 para continuar."
        exit 1
    fi

    # Verifica destino
    if [[ ! -d "$TARGET_DIR" ]]; then
        echo "ERRO: Diretorio ${TARGET_DIR} nao encontrado."
        echo "Este script deve ser executado em um servidor com a instalacao ticketz-docker-acme."
        exit 1
    fi

    # Detecta recursos
    local ram_bytes cpus disk_type disk_bytes
    ram_bytes=$(detect_ram)
    cpus=$(detect_cpus)
    disk_type=$(detect_disk_type)
    disk_bytes=$(detect_disk_size)

    local ram_gb disk_gb
    ram_gb=$(bytes_to_gb_rounded "$ram_bytes")
    disk_gb=$(bytes_to_gb_rounded "$disk_bytes")

    echo "Recursos detectados:"
    echo "  - RAM: ${ram_gb} GB"
    echo "  - vCPUs: ${cpus}"
    echo "  - Disco raiz: ${disk_gb} GB (${disk_type})"
    echo ""

    # Calcula parametros
    local params_file
    params_file=$(mktemp)
    calculate_params "$ram_bytes" "$disk_type" > "$params_file"

    local SHARED_BUFFERS EFFECTIVE_CACHE_SIZE WORK_MEM MAINTENANCE_WORK_MEM RANDOM_PAGE_COST EFFECTIVE_IO_CONCURRENCY
    # shellcheck source=/dev/null
    source "$params_file"
    rm -f "$params_file"

    echo "Parametros calculados para PostgreSQL:"
    echo "  - shared_buffers=${SHARED_BUFFERS}"
    echo "  - effective_cache_size=${EFFECTIVE_CACHE_SIZE}"
    echo "  - work_mem=${WORK_MEM}"
    echo "  - maintenance_work_mem=${MAINTENANCE_WORK_MEM}"
    echo "  - random_page_cost=${RANDOM_PAGE_COST}"
    echo "  - effective_io_concurrency=${EFFECTIVE_IO_CONCURRENCY}"
    echo ""

    # Gera YAML do postgres
    local postgres_yaml
    postgres_yaml=$(generate_postgres_yaml "$SHARED_BUFFERS" "$EFFECTIVE_CACHE_SIZE" "$WORK_MEM" "$MAINTENANCE_WORK_MEM" "$RANDOM_PAGE_COST" "$EFFECTIVE_IO_CONCURRENCY")

    # Previsualiza override final
    local tmp_override
    tmp_override=$(mktemp)

    if [[ -f "$OVERRIDE_FILE" ]]; then
        echo "Arquivo existente encontrado: ${OVERRIDE_FILE}"
        echo "Realizando merge (preservando outros servicos)..."
        echo ""

        # Backup
        mkdir -p "$BACKUP_DIR"
        cp "$OVERRIDE_FILE" "${BACKUP_DIR}/docker-compose.override-$(date +%Y%m%d-%H%M%S).yaml"

        merge_override "$OVERRIDE_FILE" "$postgres_yaml" "$tmp_override"
    else
        echo "Criando novo ${OVERRIDE_FILE}..."
        {
            echo "services:"
            echo "$postgres_yaml"
        } > "$tmp_override"
    fi

    echo "--- Conteudo final ---"
    cat "$tmp_override"
    echo "--- Fim do conteudo ---"
    echo ""

    # Confirma
    read -r -p "Aplicar este conteudo em ${OVERRIDE_FILE}? [s/N] " confirm
    if [[ ! "$confirm" =~ ^[Ss]$ ]]; then
        echo "Abortado pelo usuario."
        rm -f "$tmp_override"
        exit 0
    fi

    mv "$tmp_override" "$OVERRIDE_FILE"
    echo ""
    echo "OK: ${OVERRIDE_FILE} atualizado com sucesso."

    read -r -p "Deseja reiniciar o servico postgres para aplicar? [s/N] " restart
    if [[ "$restart" =~ ^[Ss]$ ]]; then
        echo "Reiniciando postgres..."
        (cd "$TARGET_DIR" && docker compose restart postgres)
        echo "OK: postgres reiniciado."
    else
        echo "Reinicie manualmente quando possivel:"
        echo "  cd ${TARGET_DIR} && docker compose restart postgres"
    fi
}

main "$@"
