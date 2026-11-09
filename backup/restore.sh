#!/usr/bin/env bash
# =====================================================================
# Відновлення бази з резервної копії + перевірка
#
#   ./restore.sh <файл.sql.gz> [цільова_база]
#
# За замовчуванням відновлює у ТЕСТОВУ базу driving_school_restore,
# щоб перевірити копію, не чіпаючи робочу базу. Для відновлення робочої
# бази вкажіть цільову базу driving_school явно.
# Виконується адміністратором (root): у дампі є DEFINER процедур і тригерів.
# =====================================================================
set -euo pipefail

FILE="${1:?Вкажіть файл резервної копії}"
TARGET="${2:-driving_school_restore}"
SRC_DB="driving_school"

# 1. Контрольна сума: копія не пошкоджена після створення
if [ -f "$FILE.sha256" ]; then
    sha256sum -c "$FILE.sha256" >/dev/null && echo "Контрольна сума: OK"
fi

# 2. Відновлення. Дамп створено з --databases, тому в ньому є
#    CREATE DATABASE / USE driving_school - для іншої цільової бази
#    ці рядки замінюються на льоту.
echo "Відновлення у базу $TARGET ..."
mysql -uroot -e "DROP DATABASE IF EXISTS \`$TARGET\`"
zcat "$FILE" \
  | sed -e "s/^CREATE DATABASE \/\*!32312 IF NOT EXISTS\*\/ \`$SRC_DB\`/CREATE DATABASE \`$TARGET\`/" \
        -e "s/^USE \`$SRC_DB\`;/USE \`$TARGET\`;/" \
  | mysql -uroot --default-character-set=utf8mb4

# 3. Перевірка відновленої бази
mysql -uroot --default-character-set=utf8mb4 -t -e "
SELECT 'таблиць' AS object, COUNT(*) AS cnt FROM information_schema.TABLES
 WHERE TABLE_SCHEMA = '$TARGET' AND TABLE_TYPE = 'BASE TABLE'
UNION ALL SELECT 'представлень', COUNT(*) FROM information_schema.VIEWS    WHERE TABLE_SCHEMA = '$TARGET'
UNION ALL SELECT 'процедур і функцій', COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '$TARGET'
UNION ALL SELECT 'тригерів', COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = '$TARGET';"
echo "Відновлення завершено. Порівняння з робочою базою: mysql -uroot < verify_restore.sql"
