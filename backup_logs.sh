#!/bin/bash
set -u

BACKUP_DIR="/backup"

usage() {
    echo "Для использования нужно ввести - $0 путь к папке, лимит МБ, порог %, кол-во файлов" >&2
    echo "Пример - $0 /log 100 65 4" >&2
}

if [ $# -ne 4 ]; then
    usage
    exit 1
fi

LOG_DIR="$1"
LIMIT_MB="$2"
THRESHOLD="$3"
NUM_FILES="$4"

if ! [[ "$LIMIT_MB" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! [[ "$THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! [[ "$NUM_FILES" =~ ^[0-9]+$ ]]; then
    echo "Ошибка - лимит и порог должны быть положительными числами!" >&2
    echo "Ошибка - кол-во файлов должно быть целым положительным числом!" >&2
    exit 1
fi

if [ ! -d "$LOG_DIR" ]; then
    echo "Ошибка - папка '$LOG_DIR' не существует" >&2
    exit 1
fi

LOG_SIZE=$(du -sk "$LOG_DIR" | cut -f1)
JUST_SIZE=$(du -sh "$LOG_DIR" | cut -f1)

PERCENT=$(awk -v size="$LOG_SIZE" -v limit="$LIMIT_MB" 'BEGIN {printf "%.2f", (size / (limit * 1024)) * 100}')
echo "Текущий размер папки '$LOG_DIR' : '$JUST_SIZE' (занято '$PERCENT'% от лимита $LIMIT_MB МБ, порог - '$THRESHOLD'%)"

if awk -v p="$PERCENT" -v t="$THRESHOLD" 'BEGIN {exit !(p >= t)}'; then
    echo "Порог превышен, архивируем $NUM_FILES старых файлов"
    mkdir -p "$BACKUP_DIR"

    if [ ! -w "$BACKUP_DIR" ]; then
        echo "Ошибка - нет прав на запись в папку '$BACKUP_DIR'!" >&2
        exit 2
    fi

    mapfile -t OLD_FILES < <(find "$LOG_DIR" -type f -printf '%T@ %p\n' | sort -n | head -n "$NUM_FILES" | cut -d' ' -f2-)

    if [ ${#OLD_FILES[@]} -eq 0 ]; then
        echo "В папке нет файлов для архивации"
        exit 0
    fi

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    ARCHIVE="${BACKUP_DIR}/log_backup_${TIMESTAMP}.tar.gz"

    if tar -czf "$ARCHIVE" -C "$LOG_DIR" "${OLD_FILES[@]/$LOG_DIR\//}"; then
        if ! tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
            echo "Ошибка - архив создан, но поврежден! Файлы не удалены." >&2
            exit 2
        fi

        echo "Архив создан: $ARCHIVE"
        echo "В архив вошло ${#OLD_FILES[@]} файлов"

        DELETED=0
        for file in "${OLD_FILES[@]}"; do
            if rm -f "$file"; then
                DELETED=$((DELETED + 1))
            else
                echo "Не удалось удалить '$file'" >&2
            fi
        done
        echo "Удалено '$DELETED' оригиналов"
    else
        echo "Ошибка - не удалось создать архив. Файлы не тронуты" >&2
        exit 2
    fi
else
    echo "Порог не превышен и архивация не требуется"
fi
exit 0
