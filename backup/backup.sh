#!/usr/bin/env bash
# =====================================================================
# Повне резервне копіювання бази driving_school
#
#   ./backup.sh [каталог_копій] [днів_зберігання]
#
# Що робить:
#   1. mysqldump з --single-transaction: узгоджений знімок InnoDB без
#      блокування таблиць - менеджери продовжують працювати під час копіювання;
#   2. разом із даними зберігає процедури, функції, тригери, представлення;
#   3. --source-data=2 записує в копію позицію бінарного журналу на момент
#      знімка (потрібно для відновлення на будь-який момент часу, PITR);
#   4. стискає копію gzip і рахує контрольну суму SHA-256;
#   5. перевіряє цілісність архіву і видаляє копії, старші за N днів.
#
# Розклад (cron, щодня о 02:30):
#   30 2 * * * /opt/driving_school/backup.sh /var/backups/driving_school 14 >> /var/log/ds_backup.log 2>&1
# =====================================================================
set -euo pipefail

BACKUP_DIR="${1:-./backups}"
KEEP_DAYS="${2:-14}"
DB="driving_school"
CNF="$(dirname "$0")/backup.cnf"
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
FILE="$BACKUP_DIR/${DB}_${STAMP}.sql.gz"

[ -f "$CNF" ] || { echo "Немає $CNF (див. backup.cnf.example)"; exit 1; }
mkdir -p "$BACKUP_DIR"

echo "[$(date '+%F %T')] Початок резервного копіювання $DB"

mysqldump --defaults-extra-file="$CNF" \
    --single-transaction \
    --routines --triggers --events \
    --source-data=2 \
    --set-gtid-purged=OFF \
    --no-tablespaces \
    --hex-blob \
    --databases "$DB" \
  | gzip -9 > "$FILE"

# Перевірка: архів читається, а дамп завершився штатно
gzip -t "$FILE"
zcat "$FILE" | tail -1 | grep -q "Dump completed" \
    || { echo "ПОМИЛКА: дамп неповний"; rm -f "$FILE"; exit 1; }

sha256sum "$FILE" > "$FILE.sha256"
echo "[$(date '+%F %T')] Готово: $FILE ($(du -h "$FILE" | cut -f1))"

# Ротація: видалити копії, старші за KEEP_DAYS днів
find "$BACKUP_DIR" -name "${DB}_*.sql.gz*" -type f -mtime +"$KEEP_DAYS" -print -delete \
    | sed 's/^/  видалено стару копію: /'
