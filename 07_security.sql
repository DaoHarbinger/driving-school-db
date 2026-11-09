-- =====================================================================
-- Файл 7: розмежування доступу (ролі, користувачі, права)
--
-- Принцип найменших привілеїв: кожна роль отримує лише ті права,
-- що потрібні для її задач.
--
--   Роль            Хто                 Що може
--   r_admin         адміністратор БД    усе в межах бази driving_school
--   r_manager       менеджер            курсанти, групи, зарахування, розклад, іспити;
--                                       платежі - лише через процедуру зарахування
--   r_accountant    бухгалтер           платежі та повернення, боржники;
--                                       з даних курсантів бачить лише ПІБ і телефон
--   r_instructor    інструктор          ЛИШЕ свій розклад практики; відмітка
--                                       проведено / пропущено для своїх занять
--   r_teacher       викладач теорії     ЛИШЕ свої заняття; відмітка відвідуваності
--   r_auditor       аудитор             лише читання журналу аудиту
--   r_backup        служба резервування мінімальні права для mysqldump
--
-- Обмеження на рівні рядків (row-level security): MySQL не має його
-- вбудовано, тому реалізовано через представлення з умовою
-- employees.db_login = логін поточного користувача (USER()) та процедури,
-- які перевіряють, що заняття належить співробітнику.
-- Представлення і процедури виконуються з правами власника (SQL SECURITY DEFINER),
-- тому користувачу не потрібен доступ до базових таблиць.
--
-- УВАГА: паролі нижче навчальні. У реальній системі їх задають окремо
-- і не зберігають у скриптах у відкритому вигляді.
-- =====================================================================

SET NAMES utf8mb4;
USE driving_school;

-- ---------------------------------------------------------------------
-- 1. Зв'язок співробітників з логінами MySQL
-- ---------------------------------------------------------------------
UPDATE employees SET db_login = 'teacher_kovalchuk'  WHERE employee_id = 1;
UPDATE employees SET db_login = 'teacher_melnyk'     WHERE employee_id = 2;
UPDATE employees SET db_login = 'teacher_shevchuk'   WHERE employee_id = 3;
UPDATE employees SET db_login = 'instr_bondarenko'   WHERE employee_id = 4;
UPDATE employees SET db_login = 'instr_tkachenko'    WHERE employee_id = 5;
UPDATE employees SET db_login = 'instr_kravchenko'   WHERE employee_id = 6;
UPDATE employees SET db_login = 'instr_savchenko'    WHERE employee_id = 8;
UPDATE employees SET db_login = 'instr_rudenko'      WHERE employee_id = 9;

-- ---------------------------------------------------------------------
-- 2. Представлення та процедури "лише свої рядки"
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_my_practice;
DROP VIEW IF EXISTS v_my_theory;
DROP VIEW IF EXISTS v_my_theory_students;
DROP PROCEDURE IF EXISTS sp_my_mark_practice;
DROP PROCEDURE IF EXISTS sp_my_mark_attendance;

-- USER() повертає логін, під яким підключився користувач ('instr_bondarenko@localhost'),
-- навіть усередині представлення з SQL SECURITY DEFINER (CURRENT_USER() повернув би власника).
CREATE SQL SECURITY DEFINER VIEW v_my_practice AS
SELECT pl.lesson_id,
       pl.starts_at,
       pl.ends_at,
       s.full_name    AS student,
       s.phone        AS student_phone,
       g.name         AS group_name,
       CONCAT(v.make, ' ', v.model, ' (', v.plate_number, ')') AS vehicle,
       pl.status
  FROM practice_lessons pl
  JOIN employees em  ON em.employee_id  = pl.instructor_id
  JOIN enrollments e ON e.enrollment_id = pl.enrollment_id
  JOIN students s    ON s.student_id    = e.student_id
  JOIN study_groups g ON g.group_id     = e.group_id
  JOIN vehicles v    ON v.vehicle_id    = pl.vehicle_id
 WHERE em.db_login = SUBSTRING_INDEX(USER(), '@', 1);

CREATE SQL SECURITY DEFINER VIEW v_my_theory AS
SELECT tl.lesson_id, tl.starts_at, tl.ends_at, g.name AS group_name, tl.topic, tl.status
  FROM theory_lessons tl
  JOIN employees em   ON em.employee_id = tl.teacher_id
  JOIN study_groups g ON g.group_id     = tl.group_id
 WHERE em.db_login = SUBSTRING_INDEX(USER(), '@', 1);

-- Список курсантів на заняттях викладача (для відмітки відвідуваності)
CREATE SQL SECURITY DEFINER VIEW v_my_theory_students AS
SELECT tl.lesson_id, tl.starts_at, e.enrollment_id, s.full_name AS student,
       ta.present, ta.absence_reason
  FROM theory_lessons tl
  JOIN employees em  ON em.employee_id = tl.teacher_id
  JOIN enrollments e ON e.group_id     = tl.group_id
  JOIN enrollment_statuses st ON st.status_id = e.status_id AND st.code = 'studying'
  JOIN students s    ON s.student_id   = e.student_id
  LEFT JOIN theory_attendance ta ON ta.lesson_id = tl.lesson_id AND ta.enrollment_id = e.enrollment_id
 WHERE em.db_login = SUBSTRING_INDEX(USER(), '@', 1)
   AND tl.status <> 'cancelled'
   AND e.enrolled_on <= DATE(tl.starts_at);   -- лише ті, хто вже був у групі на дату заняття

DELIMITER $$

-- Інструктор відмічає своє заняття як проведене або пропущене курсантом
CREATE PROCEDURE sp_my_mark_practice(
    IN p_lesson_id INT UNSIGNED,
    IN p_status    VARCHAR(10)          -- 'done' або 'missed'
)
SQL SECURITY DEFINER
MODIFIES SQL DATA
BEGIN
    DECLARE v_owner     VARCHAR(32) DEFAULT NULL;
    DECLARE v_starts_at DATETIME    DEFAULT NULL;

    IF p_status NOT IN ('done', 'missed') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Допустимі статуси: done, missed';
    END IF;

    SELECT em.db_login, pl.starts_at INTO v_owner, v_starts_at
      FROM practice_lessons pl
      JOIN employees em ON em.employee_id = pl.instructor_id
     WHERE pl.lesson_id = p_lesson_id;

    -- NULL-safe: заняття не існує АБО належить іншому інструктору -
    -- однакове повідомлення, щоб не розкривати чужі дані
    IF v_owner IS NULL OR v_owner <> SUBSTRING_INDEX(USER(), '@', 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Заняття не знайдено серед ваших занять';
    END IF;
    IF v_starts_at > NOW() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Не можна відмітити заняття, яке ще не почалося';
    END IF;

    UPDATE practice_lessons SET status = p_status WHERE lesson_id = p_lesson_id;
END$$

-- Викладач відмічає відвідуваність на своєму занятті (вставка або виправлення)
CREATE PROCEDURE sp_my_mark_attendance(
    IN p_lesson_id     INT UNSIGNED,
    IN p_enrollment_id INT UNSIGNED,
    IN p_present       BOOLEAN,
    IN p_reason        VARCHAR(10)      -- NULL, якщо присутній
)
SQL SECURITY DEFINER
MODIFIES SQL DATA
BEGIN
    DECLARE v_owner VARCHAR(32) DEFAULT NULL;

    SELECT em.db_login INTO v_owner
      FROM theory_lessons tl
      JOIN employees em ON em.employee_id = tl.teacher_id
     WHERE tl.lesson_id = p_lesson_id;

    IF v_owner IS NULL OR v_owner <> SUBSTRING_INDEX(USER(), '@', 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Заняття не знайдено серед ваших занять';
    END IF;

    -- решту правил (група курсанта, скасування, дата, причина) перевіряють тригер і CHECK
    INSERT INTO theory_attendance (lesson_id, enrollment_id, present, absence_reason)
    VALUES (p_lesson_id, p_enrollment_id, p_present, IF(p_present, NULL, p_reason))
    ON DUPLICATE KEY UPDATE present = VALUES(present), absence_reason = VALUES(absence_reason);
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- 3. Ролі
-- ---------------------------------------------------------------------
-- Перед перестворенням ролей видаляються ВСІ облікові записи ІС, зокрема
-- створені через інтерфейс (sp_create_account): вони зберігаються не в базі
-- driving_school, а в системній базі mysql, і без цього кроку після
-- перевстановлення лишилися б «осиротілими» - без ролей і прав.
-- Облікові записи, не пов'язані з ролями ІС (root тощо), не зачіпаються.
DROP PROCEDURE IF EXISTS tmp_drop_is_accounts;
DELIMITER $$
CREATE PROCEDURE tmp_drop_is_accounts()
BEGIN
    DECLARE v_done  BOOLEAN DEFAULT FALSE;
    DECLARE v_login VARCHAR(32);
    DECLARE cur CURSOR FOR SELECT login FROM tmp_is_accounts;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = TRUE;

    -- спершу копія списку: курсор не повинен читати таблицю, яку змінює DROP USER
    DROP TEMPORARY TABLE IF EXISTS tmp_is_accounts;
    CREATE TEMPORARY TABLE tmp_is_accounts AS
    SELECT DISTINCT TO_USER AS login
      FROM mysql.role_edges
     WHERE TO_HOST = 'localhost'
       AND FROM_USER IN ('r_admin', 'r_manager', 'r_accountant', 'r_instructor',
                         'r_teacher', 'r_auditor', 'r_backup');
    OPEN cur;
    drop_loop: LOOP
        FETCH cur INTO v_login;
        IF v_done THEN LEAVE drop_loop; END IF;
        SET @ds_sql = CONCAT('DROP USER IF EXISTS ', QUOTE(v_login), '@''localhost''');
        PREPARE st FROM @ds_sql; EXECUTE st; DEALLOCATE PREPARE st;
    END LOOP;
    CLOSE cur;
    SET @ds_sql = NULL;
    DROP TEMPORARY TABLE tmp_is_accounts;
END$$
DELIMITER ;
CALL tmp_drop_is_accounts();
DROP PROCEDURE tmp_drop_is_accounts;

DROP ROLE IF EXISTS r_admin, r_manager, r_accountant, r_instructor, r_teacher, r_auditor, r_backup;
CREATE ROLE r_admin, r_manager, r_accountant, r_instructor, r_teacher, r_auditor, r_backup;

-- Адміністратор: усе в межах бази (але не глобальні права сервера)
GRANT ALL PRIVILEGES ON driving_school.* TO r_admin;

-- Менеджер: робота з курсантами, групами, розкладом, іспитами
GRANT SELECT ON driving_school.categories          TO r_manager;
GRANT SELECT ON driving_school.document_types      TO r_manager;
GRANT SELECT ON driving_school.enrollment_statuses TO r_manager;
GRANT SELECT ON driving_school.exam_types          TO r_manager;
GRANT SELECT ON driving_school.payment_methods     TO r_manager;
GRANT SELECT ON driving_school.employees           TO r_manager;
GRANT SELECT ON driving_school.employee_categories TO r_manager;
GRANT SELECT ON driving_school.vehicles            TO r_manager;
GRANT SELECT, INSERT, UPDATE         ON driving_school.students          TO r_manager;
GRANT SELECT, INSERT, UPDATE, DELETE ON driving_school.documents         TO r_manager;
GRANT SELECT, INSERT, UPDATE         ON driving_school.study_groups      TO r_manager;
GRANT SELECT, INSERT, UPDATE         ON driving_school.enrollments       TO r_manager;
GRANT SELECT, INSERT, UPDATE         ON driving_school.theory_lessons    TO r_manager;
GRANT SELECT, INSERT, UPDATE         ON driving_school.theory_attendance TO r_manager;
GRANT SELECT, INSERT, UPDATE         ON driving_school.practice_lessons  TO r_manager;
GRANT SELECT, INSERT, UPDATE         ON driving_school.exams             TO r_manager;
GRANT SELECT ON driving_school.v_students              TO r_manager;
GRANT SELECT ON driving_school.v_enrollment_progress   TO r_manager;
GRANT SELECT ON driving_school.v_exam_admission        TO r_manager;
GRANT SELECT ON driving_school.v_exam_results_by_group TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_students_list         TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_instructor_schedule   TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_instructor_free_slots TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_book_practice         TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_cancel_practice       TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_record_exam           TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_change_enrollment_status TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_cancel_theory         TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_vehicle_service_done  TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_check_admission       TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_attendance_report     TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_absent_list           TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_medical_issues        TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_instructor_workload   TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_vehicles_service_due  TO r_manager;
GRANT EXECUTE ON PROCEDURE driving_school.sp_enroll_student        TO r_manager;

-- Бухгалтер: фінанси. Колонкові права: з таблиці курсантів - лише ПІБ і телефон
GRANT SELECT (student_id, full_name, phone) ON driving_school.students TO r_accountant;
GRANT SELECT ON driving_school.enrollments     TO r_accountant;
GRANT SELECT ON driving_school.study_groups    TO r_accountant;
GRANT SELECT ON driving_school.payment_methods TO r_accountant;
GRANT SELECT, INSERT ON driving_school.payments TO r_accountant;
GRANT UPDATE (note)  ON driving_school.payments TO r_accountant;   -- лише коментар
GRANT SELECT ON driving_school.v_debtors TO r_accountant;
GRANT EXECUTE ON PROCEDURE driving_school.sp_payment_history TO r_accountant;

-- Інструктор: лише своє
GRANT SELECT ON driving_school.v_my_practice TO r_instructor;
GRANT EXECUTE ON PROCEDURE driving_school.sp_my_mark_practice TO r_instructor;

-- Викладач теорії: лише своє
GRANT SELECT ON driving_school.v_my_theory          TO r_teacher;
GRANT SELECT ON driving_school.v_my_theory_students TO r_teacher;
GRANT EXECUTE ON PROCEDURE driving_school.sp_my_mark_attendance TO r_teacher;

-- Аудитор: лише читання журналу
GRANT SELECT ON driving_school.audit_log TO r_auditor;

-- Резервне копіювання (mysqldump --single-transaction --routines --triggers --events --source-data)
--   SHOW_ROUTINE       - вивантаження процедур і функцій
--   RELOAD             - коротке FLUSH TABLES WITH READ LOCK для фіксації позиції binlog
--   REPLICATION CLIENT - SHOW BINARY LOG STATUS (позиція журналу для PITR)
-- Права на зміну даних (INSERT/UPDATE/DELETE) роль не має.
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON driving_school.* TO r_backup;
GRANT SHOW_ROUTINE, RELOAD, REPLICATION CLIENT ON *.* TO r_backup;

-- ---------------------------------------------------------------------
-- 4. Користувачі
--   FAILED_LOGIN_ATTEMPTS / PASSWORD_LOCK_TIME: блокування на 1 день після 5 невдалих спроб
--   PASSWORD EXPIRE INTERVAL: примусова зміна пароля
-- ---------------------------------------------------------------------
DROP USER IF EXISTS
  'ds_admin'@'localhost', 'manager_olena'@'localhost', 'acc_iryna'@'localhost',
  'instr_bondarenko'@'localhost', 'instr_tkachenko'@'localhost', 'instr_kravchenko'@'localhost',
  'instr_savchenko'@'localhost', 'instr_rudenko'@'localhost',
  'teacher_kovalchuk'@'localhost', 'teacher_melnyk'@'localhost', 'teacher_shevchuk'@'localhost',
  'auditor'@'localhost', 'backup_agent'@'localhost';

CREATE USER 'ds_admin'@'localhost'      IDENTIFIED BY 'Adm!n_2026_ds'
    PASSWORD EXPIRE INTERVAL 90 DAY FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
CREATE USER 'manager_olena'@'localhost' IDENTIFIED BY 'Mngr_2026_ds!'
    PASSWORD EXPIRE INTERVAL 180 DAY FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
CREATE USER 'acc_iryna'@'localhost'     IDENTIFIED BY 'Acc_2026_ds!'
    PASSWORD EXPIRE INTERVAL 180 DAY FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
CREATE USER 'instr_bondarenko'@'localhost'  IDENTIFIED BY 'Instr_2026_ds!' FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
CREATE USER 'instr_tkachenko'@'localhost'   IDENTIFIED BY 'Instr_2026_ds!' FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
CREATE USER 'instr_kravchenko'@'localhost'  IDENTIFIED BY 'Instr_2026_ds!' FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
CREATE USER 'instr_savchenko'@'localhost'   IDENTIFIED BY 'Instr_2026_ds!' FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
CREATE USER 'instr_rudenko'@'localhost'     IDENTIFIED BY 'Instr_2026_ds!' FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
CREATE USER 'teacher_kovalchuk'@'localhost' IDENTIFIED BY 'Teach_2026_ds!' FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
CREATE USER 'teacher_melnyk'@'localhost'    IDENTIFIED BY 'Teach_2026_ds!' FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
CREATE USER 'teacher_shevchuk'@'localhost'  IDENTIFIED BY 'Teach_2026_ds!' FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
CREATE USER 'auditor'@'localhost'       IDENTIFIED BY 'Audit_2026_ds!' FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
CREATE USER 'backup_agent'@'localhost'  IDENTIFIED BY 'Bkp_2026_ds!';

GRANT r_admin      TO 'ds_admin'@'localhost';
GRANT r_manager    TO 'manager_olena'@'localhost';
GRANT r_accountant TO 'acc_iryna'@'localhost';
GRANT r_instructor TO 'instr_bondarenko'@'localhost', 'instr_tkachenko'@'localhost',
                      'instr_kravchenko'@'localhost', 'instr_savchenko'@'localhost',
                      'instr_rudenko'@'localhost';
GRANT r_teacher    TO 'teacher_kovalchuk'@'localhost', 'teacher_melnyk'@'localhost',
                      'teacher_shevchuk'@'localhost';
GRANT r_auditor    TO 'auditor'@'localhost';
GRANT r_backup     TO 'backup_agent'@'localhost';

-- Ролі активуються автоматично при вході
SET DEFAULT ROLE ALL TO
  'ds_admin'@'localhost', 'manager_olena'@'localhost', 'acc_iryna'@'localhost',
  'instr_bondarenko'@'localhost', 'instr_tkachenko'@'localhost', 'instr_kravchenko'@'localhost',
  'instr_savchenko'@'localhost', 'instr_rudenko'@'localhost',
  'teacher_kovalchuk'@'localhost', 'teacher_melnyk'@'localhost', 'teacher_shevchuk'@'localhost',
  'auditor'@'localhost', 'backup_agent'@'localhost';

-- Перевірка: які права має роль
-- SHOW GRANTS FOR r_accountant;
-- SHOW GRANTS FOR 'acc_iryna'@'localhost' USING r_accountant;

-- Розблокування облікового запису після 5 невдалих спроб входу (виконує адміністратор):
-- ALTER USER 'auditor'@'localhost' ACCOUNT UNLOCK;

-- =====================================================================
-- 5. Керування обліковими записами для адміністратора ІС
--
-- Створювати користувачів MySQL може лише root (глобальне право CREATE USER).
-- Видавати це право адміністратору ІС небезпечно: він зміг би створити
-- будь-кого з будь-якими правами. Тому root створює процедури з
-- SQL SECURITY DEFINER, які виконують лише вузьку, перевірену дію:
--   * дозволені тільки 5 ролей (адміністратора чи резервного копіювання
--     через інтерфейс створити неможливо);
--   * логін перевіряється регулярним виразом - SQL-ін'єкція в динамічний
--     запит неможлива; пароль екранується функцією QUOTE();
--   * роль має відповідати посаді співробітника (r_instructor - лише
--     для інструктора, r_teacher - лише для викладача);
--   * блокувати можна лише облікові записи з цими 5 ролями
--     (не root і не ds_admin).
-- Права EXECUTE на ці процедури має лише r_admin.
-- =====================================================================
DROP PROCEDURE IF EXISTS sp_create_account;
DROP PROCEDURE IF EXISTS sp_set_account_locked;
DROP PROCEDURE IF EXISTS sp_list_accounts;

DELIMITER $$

CREATE PROCEDURE sp_create_account(
    IN p_login       VARCHAR(32),
    IN p_password    VARCHAR(100),
    IN p_role        VARCHAR(20),
    IN p_employee_id INT UNSIGNED     -- обов'язково для r_instructor / r_teacher, інакше NULL
)
SQL SECURITY DEFINER
MODIFIES SQL DATA
BEGIN
    DECLARE v_emp_role  VARCHAR(20) DEFAULT NULL;
    DECLARE v_emp_login VARCHAR(32) DEFAULT NULL;
    DECLARE v_created   BOOLEAN DEFAULT FALSE;

    -- CREATE USER не відкочується транзакцією, тому при помилці на
    -- наступних кроках щойно створений користувач видаляється вручну
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @ds_sql = NULL;
        IF v_created THEN
            SET @ds_sql = CONCAT('DROP USER IF EXISTS ', QUOTE(p_login), '@''localhost''');
            PREPARE st FROM @ds_sql; EXECUTE st; DEALLOCATE PREPARE st;
            SET @ds_sql = NULL;
        END IF;
        RESIGNAL;
    END;

    IF p_login IS NULL OR NOT REGEXP_LIKE(p_login, '^[a-z][a-z0-9_]{2,31}$', 'c') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Логін: 3-32 символи (малі латинські літери, цифри, _), починається з літери';
    END IF;
    IF p_role IS NULL OR p_role NOT IN ('r_manager', 'r_accountant', 'r_instructor', 'r_teacher', 'r_auditor') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Недопустима роль';
    END IF;
    IF p_password IS NULL OR CHAR_LENGTH(p_password) < 10
       OR NOT REGEXP_LIKE(p_password, '[0-9]') OR NOT REGEXP_LIKE(p_password, '[[:alpha:]]') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Пароль: щонайменше 10 символів, серед них літери й цифри';
    END IF;
    IF EXISTS (SELECT 1 FROM mysql.user WHERE User = p_login) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Обліковий запис з таким логіном уже існує';
    END IF;

    IF p_role IN ('r_instructor', 'r_teacher') THEN
        IF p_employee_id IS NULL THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Для інструктора або викладача оберіть співробітника';
        END IF;
        SELECT role, db_login INTO v_emp_role, v_emp_login
          FROM employees WHERE employee_id = p_employee_id;
        IF v_emp_role IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Співробітника не знайдено';
        END IF;
        IF (p_role = 'r_instructor' AND v_emp_role <> 'instructor')
           OR (p_role = 'r_teacher' AND v_emp_role <> 'teacher') THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Роль облікового запису не відповідає посаді співробітника';
        END IF;
        IF v_emp_login IS NOT NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'У співробітника вже є обліковий запис';
        END IF;
    ELSEIF p_employee_id IS NOT NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'До співробітника прив''язуються лише ролі інструктора та викладача';
    END IF;

    -- Динамічний SQL (CREATE USER не приймає параметрів-заповнювачів).
    -- PREPARE вимагає сесійну змінну; після використання вона очищається,
    -- щоб пароль не лишався в сесії.
    SET @ds_sql = CONCAT('CREATE USER ', QUOTE(p_login), '@''localhost'' IDENTIFIED BY ', QUOTE(p_password),
                         ' PASSWORD EXPIRE INTERVAL 180 DAY FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1');
    PREPARE st FROM @ds_sql; EXECUTE st; DEALLOCATE PREPARE st;
    SET @ds_sql = NULL;
    SET v_created = TRUE;

    SET @ds_sql = CONCAT('GRANT ', p_role, ' TO ', QUOTE(p_login), '@''localhost''');
    PREPARE st FROM @ds_sql; EXECUTE st; DEALLOCATE PREPARE st;
    SET @ds_sql = CONCAT('ALTER USER ', QUOTE(p_login), '@''localhost'' DEFAULT ROLE ', p_role);
    PREPARE st FROM @ds_sql; EXECUTE st; DEALLOCATE PREPARE st;
    SET @ds_sql = NULL;

    IF p_employee_id IS NOT NULL THEN
        UPDATE employees SET db_login = p_login WHERE employee_id = p_employee_id;
    END IF;
END$$

-- Блокування / розблокування облікового запису (звільнення, відпустка,
-- або розблокування після 5 невдалих спроб входу)
CREATE PROCEDURE sp_set_account_locked(IN p_login VARCHAR(32), IN p_locked BOOLEAN)
SQL SECURITY DEFINER
MODIFIES SQL DATA
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM mysql.role_edges
         WHERE TO_USER = p_login AND TO_HOST = 'localhost'
           AND FROM_USER IN ('r_manager', 'r_accountant', 'r_instructor', 'r_teacher', 'r_auditor')) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Обліковий запис не знайдено або його не можна змінювати з інтерфейсу';
    END IF;
    -- p_login уже перевірено (існує в role_edges), QUOTE() - додатковий захист
    SET @ds_sql = CONCAT('ALTER USER ', QUOTE(p_login), '@''localhost'' ACCOUNT ',
                         IF(p_locked, 'LOCK', 'UNLOCK'));
    PREPARE st FROM @ds_sql; EXECUTE st; DEALLOCATE PREPARE st;
    SET @ds_sql = NULL;
END$$

-- Перелік облікових записів ІС з ролями та станом
CREATE PROCEDURE sp_list_accounts()
SQL SECURITY DEFINER
READS SQL DATA
BEGIN
    SELECT u.User                     AS login,
           re.FROM_USER               AS role,
           e.full_name                AS employee,
           (u.account_locked = 'Y')   AS locked,
           u.password_last_changed    AS password_changed
      FROM mysql.user u
      JOIN mysql.role_edges re ON re.TO_USER = u.User AND re.TO_HOST = u.Host
      LEFT JOIN driving_school.employees e ON e.db_login = u.User
     WHERE u.Host = 'localhost'
       AND re.FROM_USER IN ('r_admin', 'r_manager', 'r_accountant', 'r_instructor', 'r_teacher', 'r_auditor')
     ORDER BY FIELD(re.FROM_USER, 'r_admin', 'r_manager', 'r_accountant', 'r_instructor', 'r_teacher', 'r_auditor'),
              u.User;
END$$

DELIMITER ;

GRANT EXECUTE ON PROCEDURE driving_school.sp_create_account     TO r_admin;
GRANT EXECUTE ON PROCEDURE driving_school.sp_set_account_locked TO r_admin;
GRANT EXECUTE ON PROCEDURE driving_school.sp_list_accounts      TO r_admin;
