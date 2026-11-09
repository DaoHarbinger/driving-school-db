#!/usr/bin/env bash
# =====================================================================
# Демонстрація відновлення на момент часу (Point-In-Time Recovery, PITR)
#
# Сценарій:
#   02:30  нічна повна копія (backup.sh)
#   09:15  бухгалтер приймає оплату, менеджер реєструє нового курсанта
#   09:40  АВАРІЯ: менеджер виконує UPDATE documents ... без WHERE -
#          усі медичні довідки стали простроченими, запис на практику зупинено
#
# Відновлення лише з нічної копії втратить ранкову оплату і курсанта.
# PITR: повна копія + бінарний журнал від позиції копії ДО моменту аварії.
#
# УВАГА: скрипт перезаписує базу driving_school. Запускати лише на
# навчальному сервері.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"
WORK="${1:-./pitr_work}"
rm -rf "$WORK"; mkdir -p "$WORK"
SQL="mysql -uroot --default-character-set=utf8mb4 driving_school"

q() { $SQL -N -e "$1"; }
state() {
    echo "    оплат за квитанцією PITR-1: $(q "SELECT COUNT(*) FROM payments WHERE note = 'Квитанція PITR-1'")"
    echo "    курсант «Ранковий»:          $(q "SELECT COUNT(*) FROM students WHERE full_name LIKE 'Ранковий%'")"
    echo "    чинних меддовідок:          $(q "SELECT COUNT(*) FROM documents d JOIN document_types t USING(document_type_id) WHERE t.code='medical' AND d.valid_until >= CURDATE()")"
}

echo "1) Нічна повна копія"
./backup.sh "$WORK" 14 >/dev/null
FULL=$(ls "$WORK"/*.sql.gz)
# позиція бінарного журналу, записана mysqldump (--source-data=2)
# (head закриває канал раніше, ніж zcat допише файл -> SIGPIPE; при pipefail це не помилка)
HEADER=$(zcat "$FULL" | head -n 40 || true)
BINLOG_FILE=$(grep -m1 -oP "(SOURCE|MASTER)_LOG_FILE='\K[^']+" <<< "$HEADER")
BINLOG_POS=$( grep -m1 -oP "(SOURCE|MASTER)_LOG_POS=\K[0-9]+"  <<< "$HEADER")
echo "   копія: $(basename "$FULL"), позиція журналу: $BINLOG_FILE:$BINLOG_POS"
state

echo "2) Робочий ранок: зміни ПІСЛЯ копії"
$SQL -e "INSERT INTO payments (enrollment_id, kind, amount, method_id, note)
         VALUES (12, 'payment', 1000, 2, 'Квитанція PITR-1');
         INSERT INTO students (full_name, birth_date, phone)
         VALUES ('Ранковий Курсант Петрович', '2000-02-02', '+380507770001');"
state
sleep 2
ACCIDENT_TIME=$(date '+%F %T')
sleep 1

echo "3) АВАРІЯ о $ACCIDENT_TIME: UPDATE без WHERE"
# (варіант valid_until = '2020-01-01' заблокує CHECK ck_documents_dates: обмеження
#  цілісності відсікають частину помилок; ця - формально коректна, тому проходить)
$SQL -e "UPDATE documents SET valid_until = issue_date WHERE document_type_id = 2 OR 1 = 1;"
state

echo "4) Відновлення: повна копія + журнал до $ACCIDENT_TIME"
# журнали від файлу з копії до поточного
mysql -uroot -N -e "FLUSH BINARY LOGS"
DATADIR=$(mysql -uroot -N -e "SELECT @@datadir")
BASENAME=$(basename "$(mysql -uroot -N -e "SELECT @@log_bin_basename")")
LOGS=$(ls "$DATADIR"/"$BASENAME".[0-9]* | awk -v f="$BINLOG_FILE" '{n=$0; sub(".*/","",n); if (n>=f) print $0}')

# 4а) повна копія (без запису в журнал: відновлення не має потрапити в binlog)
zcat "$FULL" | mysql -uroot --default-character-set=utf8mb4 --init-command="SET sql_log_bin = 0"
# 4б) повтор подій журналу від позиції копії до моменту аварії
mysqlbinlog --disable-log-bin --database=driving_school \
            --start-position="$BINLOG_POS" --stop-datetime="$ACCIDENT_TIME" \
            $LOGS | mysql -uroot --default-character-set=utf8mb4

echo "5) Результат: ранкові зміни збережено, аварійний UPDATE не застосовано"
state
