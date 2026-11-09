-- =====================================================================
-- Встановлення бази даних «Автошкола» повністю, однією командою:
--   cd <папка зі скриптами>
--   mysql -u root -p --default-character-set=utf8mb4 < install.sql
-- (у MySQL Workbench: File -> Run SQL Script для кожного файлу по черзі)
-- =====================================================================
SOURCE 01_schema.sql;
SOURCE 02_triggers_schedule.sql;
SOURCE 03_triggers_integrity.sql;
SOURCE 04_seed.sql;
SOURCE 05_audit.sql;
SOURCE 06_reports.sql;
SOURCE 07_security.sql;
SELECT 'База driving_school встановлена' AS result;
-- Окремо (за потреби):
--   08_performance.sql      - дослідження індексів (створює driving_school_perf)
--   99_tests_triggers.sql   - тести тригерів: на ЧИСТІЙ базі після 01-03, з --force
--   98_test_race_condition.sql - тест паралельних сесій (два термінали)
--   backup/                 - резервне копіювання, відновлення, PITR
