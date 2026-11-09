-- =====================================================================
-- Файл 8: дослідження продуктивності та індексів
--
-- На робочій базі (~600 занять) різниця між запитом з індексом і без
-- непомітна: MySQL прочитає маленьку таблицю за мілісекунду будь-як.
-- Тому створюється ОКРЕМА база driving_school_perf з тією самою структурою
-- таблиць (CREATE TABLE ... LIKE копіює стовпці та індекси, але не тригери
-- і не зовнішні ключі) і наповнюється синтетичним навантаженням,
-- що відповідає ~10 рокам роботи великої автошколи:
--   practice_lessons - 500 000 занять, 60 інструкторів, 80 авто
--   payments         - 300 000 платежів, 20 000 зарахувань
--   students         - 100 000 курсантів
--
-- Для кожного запиту порівнюється план (EXPLAIN) і фактичний час
-- (EXPLAIN ANALYZE) з індексом та з примусовим ігноруванням індексу
-- (IGNORE INDEX), що імітує таблицю без індексу.
-- Робочу базу driving_school скрипт не змінює.
-- =====================================================================

SET NAMES utf8mb4;
DROP DATABASE IF EXISTS driving_school_perf;
CREATE DATABASE driving_school_perf CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE driving_school_perf;

CREATE TABLE practice_lessons LIKE driving_school.practice_lessons;
CREATE TABLE payments         LIKE driving_school.payments;
CREATE TABLE students         LIKE driving_school.students;

SET SESSION cte_max_recursion_depth = 1000000;

-- 500 000 занять: щоп'ять хвилин нове заняття, починаючи з 2016 року
INSERT INTO practice_lessons (enrollment_id, instructor_id, vehicle_id, starts_at, duration_hours, status)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 500000)
SELECT 1 + n % 20000,
       1 + n % 60,
       1 + n % 80,
       TIMESTAMP('2016-01-01 07:00:00') + INTERVAL n * 10 MINUTE,
       2.0,
       ELT(1 + n % 20, 'done','done','done','done','done','done','done','done','done','done',
                       'done','done','done','done','done','done','missed','cancelled','done','planned')
  FROM seq;

INSERT INTO payments (enrollment_id, kind, amount, paid_at, method_id)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 300000)
SELECT 1 + n % 20000, IF(n % 50 = 0, 'refund', 'payment'), 1000 + n % 5000,
       TIMESTAMP('2016-01-01 10:00:00') + INTERVAL n * 17 MINUTE, 1 + n % 3
  FROM seq;

INSERT INTO students (full_name, birth_date, phone, registered_at)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 100000)
SELECT CONCAT(ELT(1 + n % 12, 'Шевченко','Бойко','Коваленко','Ткачук','Мороз','Лисенко',
                              'Поліщук','Гончаренко','Петренко','Марченко','Вовк','Савчук'),
              ' ', ELT(1 + n % 8, 'Олександр','Дмитро','Анна','Марія','Іван','Олена','Тарас','Юлія'),
              ' ', n),
       DATE('1975-01-01') + INTERVAL n % 11000 DAY,
       CONCAT('+38050', LPAD(n, 7, '0')),
       DATE('2016-01-01') + INTERVAL n % 3600 DAY
  FROM seq;

ANALYZE TABLE practice_lessons, payments, students;

SELECT 'practice_lessons' AS table_name, COUNT(*) AS row_count FROM practice_lessons
UNION ALL SELECT 'payments', COUNT(*) FROM payments
UNION ALL SELECT 'students', COUNT(*) FROM students;

-- =====================================================================
-- ЗАПИТ 1. Розклад інструктора на тиждень (задача 2)
--   Індекс ix_practice_instructor (instructor_id, starts_at):
--   спершу відбір за інструктором, потім діапазон дат - читаються лише
--   потрібні рядки.
-- =====================================================================
SELECT '--- Q1 з індексом ix_practice_instructor' AS step;
EXPLAIN ANALYZE
SELECT lesson_id, starts_at, status
  FROM practice_lessons
 WHERE instructor_id = 17
   AND starts_at >= '2024-03-04' AND starts_at < '2024-03-11';

SELECT '--- Q1 без індексу (повне сканування таблиці)' AS step;
EXPLAIN ANALYZE
SELECT lesson_id, starts_at, status
  FROM practice_lessons IGNORE INDEX (ix_practice_instructor, ix_practice_vehicle, ix_practice_enrollment)
 WHERE instructor_id = 17
   AND starts_at >= '2024-03-04' AND starts_at < '2024-03-11';

-- =====================================================================
-- ЗАПИТ 2. Перевірка накладки в тригері (виконується при КОЖНОМУ записі)
--   Саме цей запит найважливіше прискорити: він стоїть на шляху кожної
--   вставки, а з FOR UPDATE ще й тримає блокування - чим довше він
--   працює, тим довше чекають інші менеджери.
-- =====================================================================
SELECT '--- Q2 з індексом' AS step;
EXPLAIN ANALYZE
SELECT COUNT(*) FROM practice_lessons
 WHERE instructor_id = 17 AND status <> 'cancelled'
   AND starts_at < '2024-03-05 12:00' AND ends_at > '2024-03-05 10:00';

-- Індекс використано, але діапазон відкритий зліва (instructor_id = 17 AND starts_at < ...):
-- прочитано всі заняття інструктора ДО цієї дати - тисячі рядків замість кількох.
-- Тривалість заняття <= 4 год (CHECK), тому перетин можливий лише із заняттями,
-- що почалися не раніше ніж за 4 год. Нижня межа робить діапазон вузьким.
SELECT '--- Q2b з індексом і нижньою межею (так тепер у тригері)' AS step;
EXPLAIN ANALYZE
SELECT COUNT(*) FROM practice_lessons
 WHERE instructor_id = 17 AND status <> 'cancelled'
   AND starts_at > '2024-03-05 10:00' - INTERVAL 4 HOUR
   AND starts_at < '2024-03-05 12:00' AND ends_at > '2024-03-05 10:00';

SELECT '--- Q2 без індексу' AS step;
EXPLAIN ANALYZE
SELECT COUNT(*) FROM practice_lessons IGNORE INDEX (ix_practice_instructor, ix_practice_vehicle, ix_practice_enrollment)
 WHERE instructor_id = 17 AND status <> 'cancelled'
   AND starts_at < '2024-03-05 12:00' AND ends_at > '2024-03-05 10:00';

-- =====================================================================
-- ЗАПИТ 3. Функція над стовпцем ламає використання індексу
--   DATE(starts_at) = '...' - індекс по starts_at не може бути використаний
--   як діапазон, бо MySQL мусить обчислити DATE() для кожного рядка
--   інструктора. Еквівалентна умова-діапазон використовує обидві частини
--   складеного індексу. (За результатами цього дослідження умову денного
--   ліміту в тригері переписано на діапазон.)
-- =====================================================================
SELECT '--- Q3a DATE(starts_at) = ... (функція над стовпцем)' AS step;
EXPLAIN ANALYZE
SELECT COALESCE(SUM(duration_hours), 0) FROM practice_lessons
 WHERE instructor_id = 17 AND status <> 'cancelled'
   AND DATE(starts_at) = '2024-03-05';

SELECT '--- Q3b starts_at >= d AND starts_at < d + 1 (діапазон)' AS step;
EXPLAIN ANALYZE
SELECT COALESCE(SUM(duration_hours), 0) FROM practice_lessons
 WHERE instructor_id = 17 AND status <> 'cancelled'
   AND starts_at >= '2024-03-05' AND starts_at < '2024-03-06';

-- =====================================================================
-- ЗАПИТ 4. Історія оплат і баланс курсанта (задача 9)
--   ix_payments_enrollment (enrollment_id, paid_at): відбір і сортування
--   за датою без окремого етапу сортування (filesort).
-- =====================================================================
SELECT '--- Q4 з індексом ix_payments_enrollment' AS step;
EXPLAIN ANALYZE
SELECT paid_at, kind, amount FROM payments
 WHERE enrollment_id = 4242 ORDER BY paid_at;

SELECT '--- Q4 без індексу' AS step;
EXPLAIN ANALYZE
SELECT paid_at, kind, amount FROM payments IGNORE INDEX (ix_payments_enrollment)
 WHERE enrollment_id = 4242 ORDER BY paid_at;

-- =====================================================================
-- ЗАПИТ 5. Пошук курсанта за прізвищем
--   LIKE 'Петренко Іван 4%' - префікс, індекс ix_students_full_name працює.
--   LIKE '%енко Іван 4%'    - шаблон з % на початку, індекс НЕ допомагає:
--   B-дерево впорядковане з першого символу.
-- =====================================================================
SELECT '--- Q5a префіксний пошук' AS step;
EXPLAIN ANALYZE
SELECT student_id, full_name FROM students WHERE full_name LIKE 'Петренко Іван 4%';

SELECT '--- Q5b пошук за підрядком (% на початку)' AS step;
EXPLAIN ANALYZE
SELECT student_id, full_name FROM students WHERE full_name LIKE '%енко Іван 4%';

-- =====================================================================
-- ЗАПИТ 6. Порядок стовпців у складеному індексі
--   Класичне правило: складений індекс (instructor_id, starts_at) працює
--   з лівого краю, тож для запиту ЛИШЕ за датою він не призначений.
--   MySQL 8.0.13+ вміє skip scan: перебирає кожне значення instructor_id
--   (їх лише 60) і в кожному робить діапазонний пошук за датою. Це краще
--   за повне сканування, але окремий індекс (starts_at) все одно швидший.
--   Skip scan ефективний лише за малої кількості різних значень першого
--   стовпця; для 10 000 інструкторів він втратив би сенс.
-- =====================================================================
SELECT '--- Q6a лише за датою, без індексу по starts_at' AS step;
EXPLAIN ANALYZE
SELECT COUNT(*) FROM practice_lessons
 WHERE starts_at >= '2024-03-05' AND starts_at < '2024-03-06';

CREATE INDEX ix_practice_starts ON practice_lessons (starts_at);
ANALYZE TABLE practice_lessons;

SELECT '--- Q6b після CREATE INDEX ix_practice_starts (starts_at)' AS step;
EXPLAIN ANALYZE
SELECT COUNT(*) FROM practice_lessons
 WHERE starts_at >= '2024-03-05' AND starts_at < '2024-03-06';

-- Ціна індексу: місце на диску (і уповільнення INSERT/UPDATE)
SELECT index_name,
       ROUND(stat_value * @@innodb_page_size / 1024 / 1024, 1) AS size_mb
  FROM mysql.innodb_index_stats
 WHERE database_name = 'driving_school_perf' AND table_name = 'practice_lessons'
   AND stat_name = 'size'
 ORDER BY index_name;

-- Після дослідження тестову базу можна видалити:
-- DROP DATABASE driving_school_perf;
