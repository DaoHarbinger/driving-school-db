-- =====================================================================
-- Порівняння відновленої бази з робочою: кількість рядків і контрольні
-- суми кожної таблиці. Розбіжність = копія неповна або пошкоджена.
-- (Якщо після створення копії в робочу базу вносили зміни - розбіжності
--  в цих таблицях очікувані.)
-- =====================================================================
SET NAMES utf8mb4;

CHECKSUM TABLE
  driving_school.students,           driving_school_restore.students,
  driving_school.enrollments,        driving_school_restore.enrollments,
  driving_school.practice_lessons,   driving_school_restore.practice_lessons,
  driving_school.theory_attendance,  driving_school_restore.theory_attendance,
  driving_school.payments,           driving_school_restore.payments,
  driving_school.exams,              driving_school_restore.exams,
  driving_school.audit_log,          driving_school_restore.audit_log;

-- Логічна перевірка: бізнес-показники збігаються
SELECT 'робоча'      AS db, (SELECT SUM(amount) FROM driving_school.payments WHERE kind='payment') AS paid_total,
       (SELECT COUNT(*) FROM driving_school.v_debtors) AS debtors
UNION ALL
SELECT 'відновлена', (SELECT SUM(amount) FROM driving_school_restore.payments WHERE kind='payment'),
       (SELECT COUNT(*) FROM driving_school_restore.v_debtors);

-- Тригери у відновленій базі працюють (накладка має бути відхилена)
-- CALL driving_school_restore.sp_book_practice(...);
