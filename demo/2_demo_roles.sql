-- =====================================================================
-- ДЕМОНСТРАЦІЯ РОЛЕЙ. Виконувати в ОКРЕМИХ підключеннях Workbench
-- (на головній сторінці: «+» -> Username: ..., Store in Vault... -> пароль).
-- Підключення створити заздалегідь, до захисту.
-- =====================================================================

-- ---------------- Підключення: instr_bondarenko / Instr_2026_ds! ----------------
USE driving_school;
-- «Інструктор бачить лише СВОЇ заняття» (зокрема щойно заплановане о 10:00)
SELECT starts_at, student, vehicle, status FROM v_my_practice
 WHERE starts_at >= '2026-11-13' AND starts_at < '2026-11-14' ORDER BY starts_at;
-- «А до платежів доступу немає» -> SELECT command denied
SELECT * FROM payments;

-- ---------------- Підключення: acc_iryna / Acc_2026_ds! ----------------
USE driving_school;
-- «Бухгалтер бачить ПІБ і телефон курсанта...»
SELECT full_name, phone FROM students LIMIT 5;
-- «...але не дату народження та адресу» -> denied for column 'birth_date'
SELECT full_name, birth_date FROM students LIMIT 5;
-- «Бухгалтер може додати коментар до платежу...»
UPDATE payments SET note = 'Звірено з банківською випискою' WHERE payment_id = 2;
-- «...але не змінити суму» -> denied for column 'amount'
UPDATE payments SET amount = 1 WHERE payment_id = 2;

-- Далі повернутися до підключення root і виконати КРОК 8 (журнал аудиту):
-- там буде запис changed_by = acc_iryna@localhost.
