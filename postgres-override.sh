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
    # arredonda para o proximo multiplo de 64 MB (nunca zero)
    echo "$(( (mb + 63) / 64 * 64 ))"
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
    # retorna 'ssd' se detectar disco nao-rotacional (SSD/NVMe), 'hdd' caso contrario
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*\]//')
    if [[ -z "$root_dev" ]]; then
        echo "ssd"
        return
    fi

    # Resolve LVM/loop/virtio para o disco fisico pai
    local base_dev="$root_dev"
    base_dev="${base_dev%[0-9]*}"      # remove numero da particao
    base_dev="${base_dev%p}"           # remove 'p' final de nvme

    local base_name
    base_name=$(basename "$base_dev" 2>/dev/null || echo "")

    # Se for LVM (mapper) ou dm-X, procura o disco fisico pai via lsblk
    if [[ "$root_dev" == /dev/mapper/* ]] || [[ "$base_name" == dm-* ]]; then
        local pkname
        pkname=$(lsblk -n -o PKNAME "$root_dev" 2>/dev/null | head -n1 | tr -d ' ')
        if [[ -n "$pkname" ]]; then
            base_name="$pkname"
        fi
    fi

    # 1. NVMe e sempre SSD
    if [[ "$base_name" == nvme* ]]; then
        echo "ssd"
        return
    fi

    # 2. Verifica /sys/block/<dev>/queue/rotational
    local sys_path="/sys/block/${base_name}/queue/rotational"
    if [[ -f "$sys_path" ]]; then
        local rota
        rota=$(cat "$sys_path" 2>/dev/null | tr -d ' ')
        if [[ "$rota" == "0" ]]; then
            echo "ssd"
            return
        elif [[ "$rota" == "1" ]]; then
            echo "hdd"
            return
        fi
    fi

    # 3. Tenta lsblk -d -no ROTA
    local rota_lsblk
    rota_lsblk=$(lsblk -d -no ROTA "/dev/${base_name}" 2>/dev/null | tr -d ' ')
    if [[ "$rota_lsblk" == "0" ]]; then
        echo "ssd"
        return
    elif [[ "$rota_lsblk" == "1" ]]; then
        echo "hdd"
        return
    fi

    # 4. Verifica modelo do disco por palavras-chave de SSD
    local model
    model=$(lsblk -d -no MODEL "/dev/${base_name}" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if [[ -z "$model" ]]; then
        model=$(cat "/sys/block/${base_name}/device/model" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    fi
    if [[ "$model" =~ (ssd|nvme|solid|flash|intel|samsung|kingston|wd|sandisk|micron|crucial|seagate.*firecuda) ]]; then
        echo "ssd"
        return
    fi

    # 5. Se nao conseguiu determinar, assume SSD para ambiente de nuvem/VPS
    # (a maioria das VPS modernas usa SSD/NVMe, mesmo que virtualizado reporte ROTA=1)
    echo "ssd"
}

detect_disk_size() {
    df -B1 --output=size / | tail -n1 | tr -d ' '
}

# -----------------------------------------------------------------------------
# Calculo dos parametros PostgreSQL
# -----------------------------------------------------------------------------

MIN_RAM_MB=$(( 8 * 1024 ))

calculate_params() {
    local ram_bytes="$1"
    local disk_type="$2"

    local ram_mb
    ram_mb=$(bytes_to_mb "$ram_bytes")

    if [[ "$ram_mb" -lt "$MIN_RAM_MB" ]]; then
        echo "ERRO: Este script foi projetado para VPS com no minimo 8 GB de RAM." >&2
        echo "       RAM detectada: $(format_mb "$ram_mb")." >&2
        echo "       Instalacoes Ticketz com menos de 8 GB nao precisam deste tuning." >&2
        return 1
    fi

    # Valores baseados em proporcao e experiencia pratica com Ticketz
    local shared_mb cache_mb work_mb maint_mb

    shared_mb=$(( ram_mb / 4 ))
    cache_mb=$(( ram_mb * 3 / 4 ))
    work_mb=32

    # maintenance_work_mem conforme faixa de RAM
    if [[ "$ram_mb" -ge 32768 ]]; then
        maint_mb=1024
    elif [[ "$ram_mb" -ge 16384 ]]; then
        maint_mb=512
    else
        maint_mb=256
    fi

    # Limites praticos para Ticketz (OLTP)
    if [[ "$shared_mb" -gt 8192 ]]; then
        shared_mb=8192
    fi
    if [[ "$cache_mb" -gt 24576 ]]; then
        cache_mb=24576
    fi

    # Arredonda para multiplo de 64 MB
    shared_mb=$(round_mb "$shared_mb")
    cache_mb=$(round_mb "$cache_mb")

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

def merge_yaml(content):
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

with open(existing_path, 'r') as f:
    original = f.read()

with open(output_path, 'w') as f:
    f.write(merge_yaml(original))
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
    if ! calculate_params "$ram_bytes" "$disk_type" > "$params_file"; then
        rm -f "$params_file"
        exit 1
    fi

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

    read -r -p "Deseja reiniciar toda a stack Ticketz para aplicar? [s/N] " restart
    if [[ "$restart" =~ ^[Ss]$ ]]; then
        echo "Reiniciando toda a stack Ticketz..."
        (
            cd "$TARGET_DIR" || exit 1
            sudo docker compose stop
            sudo docker compose up -d
        )
        echo "OK: stack Ticketz reiniciada."
    else
        echo "Reinicie manualmente quando possivel:"
        echo "  cd ${TARGET_DIR} && sudo docker compose stop && sudo docker compose up -d"
    fi
}

main "$@"
