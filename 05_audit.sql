-- =====================================================================
-- Файл 5: аудит змін та захист фінансових записів
--   - журнал змін платежів, зарахувань (статус, ціна, група) та іспитів
--   - платежі не можна видаляти або змінювати суму: виправлення робиться
--     поверненням (refund), як у бухгалтерії ("сторно"), а не правкою історії
--   - журнал аудиту доступний лише для додавання (append-only)
-- Завантажувати після 04_seed.sql: тестові дані в журнал не потрапляють.
-- changed_by = USER(): реальний логін, під яким підключився користувач
-- (CURRENT_USER() у тригері повернув би власника тригера).
-- =====================================================================

SET NAMES utf8mb4;
USE driving_school;

DROP TRIGGER IF EXISTS trg_payments_ai;
DROP TRIGGER IF EXISTS trg_payments_bu_protect;
DROP TRIGGER IF EXISTS trg_payments_au;
DROP TRIGGER IF EXISTS trg_payments_bd;
DROP TRIGGER IF EXISTS trg_enrollments_ai;
DROP TRIGGER IF EXISTS trg_enrollments_au;
DROP TRIGGER IF EXISTS trg_practice_au;
DROP TRIGGER IF EXISTS trg_exams_ai;
DROP TRIGGER IF EXISTS trg_exams_au;
DROP TRIGGER IF EXISTS trg_exams_bd;
DROP TRIGGER IF EXISTS trg_students_au;
DROP TRIGGER IF EXISTS trg_employees_ai;
DROP TRIGGER IF EXISTS trg_employees_au;
DROP TRIGGER IF EXISTS trg_vehicles_ai;
DROP TRIGGER IF EXISTS trg_vehicles_au;
DROP TRIGGER IF EXISTS trg_audit_bu;
DROP TRIGGER IF EXISTS trg_audit_bd;

DELIMITER $$

-- ---------------------------------------------------------------------
-- ПЛАТЕЖІ
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_payments_ai
AFTER INSERT ON payments
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, operation, record_id, changed_by, new_value)
    VALUES ('payments', 'INSERT', NEW.payment_id, USER(),
            JSON_OBJECT('enrollment_id', NEW.enrollment_id, 'kind', NEW.kind,
                        'amount', NEW.amount, 'paid_at', NEW.paid_at,
                        'method_id', NEW.method_id, 'note', NEW.note));
END$$

-- Фінансово значущі поля змінювати не можна; дозволено лише виправити коментар
CREATE TRIGGER trg_payments_bu_protect
BEFORE UPDATE ON payments
FOR EACH ROW
BEGIN
    IF NEW.enrollment_id <> OLD.enrollment_id OR NEW.kind <> OLD.kind
       OR NEW.amount <> OLD.amount OR NEW.paid_at <> OLD.paid_at
       OR NEW.method_id <> OLD.method_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Платіж змінювати не можна: для виправлення оформіть повернення (refund)';
    END IF;
END$$

CREATE TRIGGER trg_payments_au
AFTER UPDATE ON payments
FOR EACH ROW
BEGIN
    -- лише реальна зміна (UPDATE ... SET note = note не засмічує журнал);
    -- <=> - NULL-safe порівняння, бо note може бути NULL
    IF NOT (NEW.note <=> OLD.note) THEN
        INSERT INTO audit_log (table_name, operation, record_id, changed_by, old_value, new_value)
        VALUES ('payments', 'UPDATE', NEW.payment_id, USER(),
                JSON_OBJECT('note', OLD.note), JSON_OBJECT('note', NEW.note));
    END IF;
END$$

CREATE TRIGGER trg_payments_bd
BEFORE DELETE ON payments
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Платежі не видаляються: для виправлення оформіть повернення (refund)';
END$$

-- ---------------------------------------------------------------------
-- ЗАРАХУВАННЯ: фіксуються зарахування, зміна статусу, групи, ціни
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_enrollments_ai
AFTER INSERT ON enrollments
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, operation, record_id, changed_by, new_value)
    VALUES ('enrollments', 'INSERT', NEW.enrollment_id, USER(),
            JSON_OBJECT('student_id', NEW.student_id, 'group_id', NEW.group_id,
                        'status', (SELECT code FROM enrollment_statuses WHERE status_id = NEW.status_id),
                        'agreed_price', NEW.agreed_price, 'discount_note', NEW.discount_note));
END$$

CREATE TRIGGER trg_enrollments_au
AFTER UPDATE ON enrollments
FOR EACH ROW
BEGIN
    -- NULL-safe порівняння <=> : discount_note може бути NULL
    IF NOT (NEW.status_id <=> OLD.status_id AND NEW.group_id <=> OLD.group_id
            AND NEW.agreed_price <=> OLD.agreed_price AND NEW.discount_note <=> OLD.discount_note) THEN
        INSERT INTO audit_log (table_name, operation, record_id, changed_by, old_value, new_value)
        VALUES ('enrollments', 'UPDATE', NEW.enrollment_id, USER(),
                JSON_OBJECT('status', (SELECT code FROM enrollment_statuses WHERE status_id = OLD.status_id),
                            'group_id', OLD.group_id, 'agreed_price', OLD.agreed_price,
                            'discount_note', OLD.discount_note),
                JSON_OBJECT('status', (SELECT code FROM enrollment_statuses WHERE status_id = NEW.status_id),
                            'group_id', NEW.group_id, 'agreed_price', NEW.agreed_price,
                            'discount_note', NEW.discount_note));
    END IF;
END$$

-- ---------------------------------------------------------------------
-- ПРАКТИЧНІ ЗАНЯТТЯ: журналюється зміна статусу (скасування, відмітка
-- «проведено» / «пропущено») і перенесення - видно, хто це зробив
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_practice_au
AFTER UPDATE ON practice_lessons
FOR EACH ROW
BEGIN
    IF NOT (NEW.status <=> OLD.status AND NEW.starts_at <=> OLD.starts_at
            AND NEW.instructor_id <=> OLD.instructor_id AND NEW.vehicle_id <=> OLD.vehicle_id) THEN
        INSERT INTO audit_log (table_name, operation, record_id, changed_by, old_value, new_value)
        VALUES ('practice_lessons', 'UPDATE', NEW.lesson_id, USER(),
                JSON_OBJECT('status', OLD.status, 'starts_at', OLD.starts_at,
                            'instructor_id', OLD.instructor_id, 'vehicle_id', OLD.vehicle_id),
                JSON_OBJECT('status', NEW.status, 'starts_at', NEW.starts_at,
                            'instructor_id', NEW.instructor_id, 'vehicle_id', NEW.vehicle_id));
    END IF;
END$$

-- ---------------------------------------------------------------------
-- ІСПИТИ: результати не видаляються, виправлення балу журналюється
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_exams_ai
AFTER INSERT ON exams
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, operation, record_id, changed_by, new_value)
    VALUES ('exams', 'INSERT', NEW.exam_id, USER(),
            JSON_OBJECT('enrollment_id', NEW.enrollment_id, 'exam_type_id', NEW.exam_type_id,
                        'attempt_no', NEW.attempt_no, 'score', NEW.score, 'passed', NEW.passed));
END$$

CREATE TRIGGER trg_exams_au
AFTER UPDATE ON exams
FOR EACH ROW
BEGIN
    IF NOT (NEW.score <=> OLD.score AND NEW.passed <=> OLD.passed AND NEW.exam_date <=> OLD.exam_date) THEN
        INSERT INTO audit_log (table_name, operation, record_id, changed_by, old_value, new_value)
        VALUES ('exams', 'UPDATE', NEW.exam_id, USER(),
                JSON_OBJECT('score', OLD.score, 'passed', OLD.passed, 'exam_date', OLD.exam_date),
                JSON_OBJECT('score', NEW.score, 'passed', NEW.passed, 'exam_date', NEW.exam_date));
    END IF;
END$$

CREATE TRIGGER trg_exams_bd
BEFORE DELETE ON exams
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Результати іспитів не видаляються';
END$$

-- ---------------------------------------------------------------------
-- ОСОБИСТІ ДАНІ КУРСАНТІВ: хто й що змінив (телефон, email, адреса ...)
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_students_au
AFTER UPDATE ON students
FOR EACH ROW
BEGIN
    IF NOT (NEW.full_name <=> OLD.full_name AND NEW.birth_date <=> OLD.birth_date AND NEW.phone <=> OLD.phone
            AND NEW.email <=> OLD.email AND NEW.address <=> OLD.address) THEN
        INSERT INTO audit_log (table_name, operation, record_id, changed_by, old_value, new_value)
        VALUES ('students', 'UPDATE', NEW.student_id, USER(),
                JSON_OBJECT('full_name', OLD.full_name, 'birth_date', OLD.birth_date, 'phone', OLD.phone,
                            'email', OLD.email, 'address', OLD.address),
                JSON_OBJECT('full_name', NEW.full_name, 'birth_date', NEW.birth_date, 'phone', NEW.phone,
                            'email', NEW.email, 'address', NEW.address));
    END IF;
END$$

-- ---------------------------------------------------------------------
-- ПЕРСОНАЛ: прийняття, звільнення, повернення
-- (зміна лише db_login не журналюється: її робить процедура створення
--  облікового запису, а сам обліковий запис видно в sp_list_accounts)
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_employees_ai
AFTER INSERT ON employees
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, operation, record_id, changed_by, new_value)
    VALUES ('employees', 'INSERT', NEW.employee_id, USER(),
            JSON_OBJECT('full_name', NEW.full_name, 'role', NEW.role, 'hire_date', NEW.hire_date));
END$$

CREATE TRIGGER trg_employees_au
AFTER UPDATE ON employees
FOR EACH ROW
BEGIN
    IF NOT (NEW.is_active <=> OLD.is_active AND NEW.role <=> OLD.role
            AND NEW.full_name <=> OLD.full_name AND NEW.phone <=> OLD.phone) THEN
        INSERT INTO audit_log (table_name, operation, record_id, changed_by, old_value, new_value)
        VALUES ('employees', 'UPDATE', NEW.employee_id, USER(),
                JSON_OBJECT('is_active', OLD.is_active, 'role', OLD.role, 'full_name', OLD.full_name, 'phone', OLD.phone),
                JSON_OBJECT('is_active', NEW.is_active, 'role', NEW.role, 'full_name', NEW.full_name, 'phone', NEW.phone));
    END IF;
END$$

-- ---------------------------------------------------------------------
-- АВТОМОБІЛІ: нове авто, ТО, закріплення інструктора, списання
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_vehicles_ai
AFTER INSERT ON vehicles
FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, operation, record_id, changed_by, new_value)
    VALUES ('vehicles', 'INSERT', NEW.vehicle_id, USER(),
            JSON_OBJECT('plate_number', NEW.plate_number, 'category_id', NEW.category_id,
                        'default_instructor_id', NEW.default_instructor_id, 'next_service_date', NEW.next_service_date));
END$$

CREATE TRIGGER trg_vehicles_au
AFTER UPDATE ON vehicles
FOR EACH ROW
BEGIN
    IF NOT (NEW.is_active <=> OLD.is_active AND NEW.next_service_date <=> OLD.next_service_date
            AND NEW.default_instructor_id <=> OLD.default_instructor_id) THEN
        INSERT INTO audit_log (table_name, operation, record_id, changed_by, old_value, new_value)
        VALUES ('vehicles', 'UPDATE', NEW.vehicle_id, USER(),
                JSON_OBJECT('plate_number', OLD.plate_number, 'is_active', OLD.is_active,
                            'next_service_date', OLD.next_service_date, 'default_instructor_id', OLD.default_instructor_id),
                JSON_OBJECT('plate_number', NEW.plate_number, 'is_active', NEW.is_active,
                            'next_service_date', NEW.next_service_date, 'default_instructor_id', NEW.default_instructor_id));
    END IF;
END$$

-- ---------------------------------------------------------------------
-- ЖУРНАЛ АУДИТУ: лише додавання
-- (захист на рівні БД; додатково в 07_security.sql жодна роль, крім
--  адміністратора, не має прав UPDATE/DELETE на audit_log)
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_audit_bu
BEFORE UPDATE ON audit_log
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Журнал аудиту не можна змінювати';
END$$

CREATE TRIGGER trg_audit_bd
BEFORE DELETE ON audit_log
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Записи журналу аудиту не можна видаляти';
END$$

DELIMITER ;
