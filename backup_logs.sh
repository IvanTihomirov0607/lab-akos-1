#!/bin/bash
#Проверка аргументов
if [ $# -ne 3 ]; then
    echo "Для использования нужно - $0 путь к папке, порог %, кол-во файлов"
    echo "Пример - $0 /log 65 4"
    exit 1
fi

LOG_DIR="$1"
THRESHOLD="$2"
NUM_FILES="$3"

#Проверка существования папки
if [ ! -d "$LOG_DIR" ]; then
    echo "Ошибка - папка '$LOG_DIR' не существует"
    exit 1
fi

#Нахождение размеров и процента
LOG_SIZE=$(du -sk "$LOG_DIR" | cut -f1)
#cut -f1 - берет первое поле

TOTAL_SIZE=$(df -k "$LOG_DIR" | tail -n 1 | awk '{print $2}')
#tail -n 1 - берет последнюю строку, awk {print $2} - берет второе поле

PERCENT=$(awk "BEGIN {printf \"%.2f\", ($LOG_SIZE / $TOTAL_SIZE) * 100}")
echo "Папка '$LOG_DIR' занята на '$PERCENT'% (порог: '$THRESHOLD'%)"

#Сравнение с порогом
EXCEEDED=$(awk "BEGIN {print ($PERCENT > $THRESHOLD) ? 1 : 0}")
#? 1 : 0 - оператор который при сравнении выводит 1 или 0

if [ "$EXCEEDED" -eq 1 ]; then
    echo "Порог превышен, архивируем $NUM_FILES старых файлов"
    mkdir -p /backup

    #Поиск M старых файлов
    mapfile -t OLD_FILES < <(find "$LOG_DIR" -type f -printf '%T@ %p\n' | sort -n | head -n "$NUM_FILES" | cut -d' ' -f2-)

    #Проверка что файлы нашлись
    if [ ${#OLD_FILES[@]} -eq 0 ]; then
        echo "В папке нет файлов для архивации"
        exit 0
    fi
    #Создаем архив
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    ARHIVE="/backup/log_backup_${TIMESTAMP}.tar.gz"

    #Архивирование
    tar -czf "$ARHIVE" -C "$LOG_DIR" "${OLD_FILES[@]/$LOG_DIR\//}"

    echo "Архив создан: $ARHIVE"
    echo "В архив вошло ${#OLD_FILES[@]} файлов"
else
    echo "Порог не превышен и архивация не требуется"
fi
