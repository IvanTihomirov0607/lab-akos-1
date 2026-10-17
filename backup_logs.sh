#!/bin/bash
set -u

BACKUP_DIR="/backup"

usage() {
    echo "Для использования нужно ввести - $0 путь к папке, порог %, кол-во файлов" >&2
    echo "Пример - $0 /log 65 4" >&2
}

if [ $# -ne 3 ]; then
    usage
    exit 1
fi

LOG_DIR="$1"
THRESHOLD="$2"
NUM_FILES="$3"

if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || ! [[ "$NUM_FILES" =~ ^[0-9]+$ ]]; then
    echo "Ошибка - порог и кол-во файлов должны быть введены целыми положительными числами!" >&2
    exit 1
fi

#Проверка существования папки
if [ ! -d "$LOG_DIR" ]; then
    echo "Ошибка - папка '$LOG_DIR' не существует" >&2
    exit 1
fi

#нахождение размеров и процента
LOG_SIZE=$(du -sk "$LOG_DIR" | cut -f1)
TOTAL_SIZE=$(df -k "$LOG_DIR" | tail -n 1 | awk '{print $2}')
JUST_SIZE=$(du -sh "$LOG_DIR" | cut -f1)

PERCENT=$(awk -v size="$LOG_SIZE" -v total="$TOTAL_SIZE" 'BEGIN {printf "%.2f", (size / total) * 100}')
echo "Текущий размер папки '$LOG_DIR' : '$JUST_SIZE' (занято '$PERCENT'%, порог - '$THRESHOLD'%)"

if awk -v p="$PERCENT" -v t="$THRESHOLD" 'BEGIN {exit !(p >= t)}'; then
    echo "Порог превышен, архивируем $NUM_FILES старых файлов"
    mkdir -p "$BACKUP_DIR"

    if [ ! -w "$BACKUP_DIR" ]; then
        echo "Ошибка - нет прав на запись в папку '$BACKUP_DIR'!" >&2
        exit 2
    fi

    #Поиск М старых файлов
    mapfile -t OLD_FILES < <(find "$LOG_DIR" -type f -printf '%T@ %p\n' | sort -n | head -n "$NUM_FILES" | cut -d' ' -f2-)

    #Проверка что файлы нашлись
    if [ ${#OLD_FILES[@]} -eq 0 ]; then
        echo "В папке нет файлов для архивации"
        exit 0
    fi

    #Создаем архив
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    ARCHIVE="${BACKUP_DIR}/log_backup_${TIMESTAMP}.tar.gz"

    #Архивирование
    if tar -czf "$ARCHIVE" -C "$LOG_DIR" "${OLD_FILES[@]/$LOG_DIR\//}"; then

        if ! tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
            echo "Ошибка - архив создан, но поврежден! Файлы не удалены." >&2
            exit 2
        fi

        echo "Архив создан: $ARCHIVE"
        echo "В архив вошло ${#OLD_FILES[@]} файлов"

        #Удаление оригиналов после успешной архивации
        DELETED=0 #считаем кол-во уд файлов
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
