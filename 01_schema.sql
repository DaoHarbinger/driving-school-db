-- =====================================================================
-- Курсова робота: ІС для автоматизації роботи автошколи «Автошкола»
-- СУБД: MySQL 8.0+
-- Файл 1: створення бази даних, таблиць, обмежень та індексів
-- =====================================================================

-- Кодування з'єднання: без цього клієнт може працювати в latin1,
-- і кирилиця збережеться подвійно закодованою («кракозябри» в інших клієнтах)
SET NAMES utf8mb4;

DROP DATABASE IF EXISTS driving_school;
CREATE DATABASE driving_school
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;
USE driving_school;

-- ---------------------------------------------------------------------
-- ДОВІДНИКИ
-- ---------------------------------------------------------------------

CREATE TABLE document_types (
    document_type_id TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    code             VARCHAR(20)  NOT NULL,
    name             VARCHAR(80)  NOT NULL,
    PRIMARY KEY (document_type_id),
    UNIQUE KEY uq_document_types_code (code)
) ENGINE=InnoDB COMMENT='Довідник типів документів';

-- Логіка БД спирається на КОДИ статусів ('studying', 'graduated', 'expelled', 'leave'),
-- а не на числові ідентифікатори. Системні статуси захищені від видалення тригером.
CREATE TABLE enrollment_statuses (
    status_id TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    code      VARCHAR(20) NOT NULL,
    name      VARCHAR(50) NOT NULL,
    is_system BOOLEAN NOT NULL DEFAULT FALSE COMMENT 'Системний статус, на який спирається логіка БД',
    PRIMARY KEY (status_id),
    UNIQUE KEY uq_enrollment_statuses_code (code)
) ENGINE=InnoDB COMMENT='Довідник статусів зарахування';

CREATE TABLE exam_types (
    exam_type_id TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    code         VARCHAR(20) NOT NULL,
    name         VARCHAR(80) NOT NULL,
    pass_score   TINYINT UNSIGNED NULL COMMENT 'Прохідний бал; NULL = іспит без балу (залік/незалік)',
    PRIMARY KEY (exam_type_id),
    UNIQUE KEY uq_exam_types_code (code),
    CONSTRAINT ck_exam_types_pass CHECK (pass_score IS NULL OR pass_score BETWEEN 1 AND 100)
) ENGINE=InnoDB COMMENT='Довідник типів іспитів';

CREATE TABLE payment_methods (
    method_id TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name      VARCHAR(50) NOT NULL,
    PRIMARY KEY (method_id),
    UNIQUE KEY uq_payment_methods_name (name)
) ENGINE=InnoDB COMMENT='Довідник способів оплати';

-- ---------------------------------------------------------------------
-- ОСНОВНІ СУТНОСТІ
-- ---------------------------------------------------------------------

-- Категорії навчання та параметри допуску до іспиту.
-- price - поточна (прейскурантна) ціна; фактична ціна курсанта фіксується в enrollments.agreed_price
CREATE TABLE categories (
    category_id        TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    code               VARCHAR(5)    NOT NULL,
    name               VARCHAR(100)  NOT NULL,
    price              DECIMAL(10,2) NOT NULL COMMENT 'Поточна ціна курсу за прейскурантом',
    theory_hours_min   SMALLINT UNSIGNED NOT NULL COMMENT 'Мінімум годин теорії для допуску до іспиту',
    practice_hours_min SMALLINT UNSIGNED NOT NULL COMMENT 'Мінімум годин практики для допуску до іспиту',
    PRIMARY KEY (category_id),
    UNIQUE KEY uq_categories_code (code),
    CONSTRAINT ck_categories_price CHECK (price > 0),
    CONSTRAINT ck_categories_hours CHECK (theory_hours_min > 0 AND practice_hours_min > 0)
) ENGINE=InnoDB COMMENT='Категорії навчання';

CREATE TABLE students (
    student_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    full_name     VARCHAR(120) NOT NULL,
    birth_date    DATE         NOT NULL,
    phone         VARCHAR(20)  NOT NULL,
    email         VARCHAR(100) NULL,
    address       VARCHAR(200) NULL,
    registered_at DATE         NOT NULL DEFAULT (CURRENT_DATE),
    PRIMARY KEY (student_id),
    UNIQUE KEY uq_students_phone (phone),
    KEY ix_students_full_name (full_name),
    CONSTRAINT ck_students_birth CHECK (birth_date < registered_at)
) ENGINE=InnoDB COMMENT='Курсанти автошколи';

CREATE TABLE documents (
    document_id      INT UNSIGNED NOT NULL AUTO_INCREMENT,
    student_id       INT UNSIGNED NOT NULL,
    document_type_id TINYINT UNSIGNED NOT NULL,
    number           VARCHAR(40) NOT NULL,
    issue_date       DATE NOT NULL,
    valid_until      DATE NULL COMMENT 'NULL = безстроковий',
    PRIMARY KEY (document_id),
    KEY ix_documents_student (student_id, document_type_id),
    CONSTRAINT fk_documents_student FOREIGN KEY (student_id)
        REFERENCES students (student_id) ON DELETE CASCADE,
    CONSTRAINT fk_documents_type FOREIGN KEY (document_type_id)
        REFERENCES document_types (document_type_id),
    CONSTRAINT ck_documents_dates CHECK (valid_until IS NULL OR valid_until >= issue_date)
) ENGINE=InnoDB COMMENT='Документи курсантів';

CREATE TABLE employees (
    employee_id      INT UNSIGNED NOT NULL AUTO_INCREMENT,
    full_name        VARCHAR(120) NOT NULL,
    phone            VARCHAR(20)  NOT NULL,
    role             ENUM('teacher','instructor') NOT NULL COMMENT 'teacher - викладач теорії, instructor - інструктор з водіння',
    hire_date        DATE NOT NULL,
    experience_years TINYINT UNSIGNED NOT NULL DEFAULT 0,
    is_active        BOOLEAN NOT NULL DEFAULT TRUE,
    db_login         VARCHAR(32) NULL COMMENT 'Логін MySQL співробітника: для обмеження доступу до "своїх" рядків',
    PRIMARY KEY (employee_id),
    UNIQUE KEY uq_employees_phone (phone),
    UNIQUE KEY uq_employees_login (db_login)
) ENGINE=InnoDB COMMENT='Співробітники автошколи';

-- Кваліфікація: які категорії співробітник має право викладати (M:N)
CREATE TABLE employee_categories (
    employee_id  INT UNSIGNED NOT NULL,
    category_id  TINYINT UNSIGNED NOT NULL,
    granted_date DATE NOT NULL,
    valid_until  DATE NULL COMMENT 'NULL = безстроково',
    PRIMARY KEY (employee_id, category_id),
    CONSTRAINT fk_empcat_employee FOREIGN KEY (employee_id)
        REFERENCES employees (employee_id) ON DELETE CASCADE,
    CONSTRAINT fk_empcat_category FOREIGN KEY (category_id)
        REFERENCES categories (category_id),
    CONSTRAINT ck_empcat_dates CHECK (valid_until IS NULL OR valid_until >= granted_date)
) ENGINE=InnoDB COMMENT='Категорії, які може викладати співробітник';

-- Автомобілі.
-- default_instructor_id - лише інструктор "за замовчуванням" (для зручності планування).
-- Хто ФАКТИЧНО їздив на авто в конкретний день, зберігається в practice_lessons.instructor_id,
-- тому історія не втрачається при заміні чи звільненні інструктора.
CREATE TABLE vehicles (
    vehicle_id            INT UNSIGNED NOT NULL AUTO_INCREMENT,
    plate_number          VARCHAR(12) NOT NULL,
    make                  VARCHAR(40) NOT NULL,
    model                 VARCHAR(40) NOT NULL,
    production_year       SMALLINT UNSIGNED NOT NULL,
    transmission          ENUM('manual','automatic') NOT NULL DEFAULT 'manual',
    category_id           TINYINT UNSIGNED NOT NULL,
    default_instructor_id INT UNSIGNED NULL COMMENT 'Інструктор за замовчуванням (не історичний факт)',
    next_service_date     DATE NOT NULL COMMENT 'Дата наступного технічного обслуговування',
    is_active             BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (vehicle_id),
    UNIQUE KEY uq_vehicles_plate (plate_number),
    KEY ix_vehicles_service (next_service_date),
    CONSTRAINT fk_vehicles_category FOREIGN KEY (category_id)
        REFERENCES categories (category_id),
    CONSTRAINT fk_vehicles_instructor FOREIGN KEY (default_instructor_id)
        REFERENCES employees (employee_id) ON DELETE SET NULL,
    CONSTRAINT ck_vehicles_year CHECK (production_year BETWEEN 1990 AND 2100)
) ENGINE=InnoDB COMMENT='Навчальні автомобілі';

CREATE TABLE study_groups (
    group_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    name        VARCHAR(30) NOT NULL,
    category_id TINYINT UNSIGNED NOT NULL,
    start_date  DATE NOT NULL,
    end_date    DATE NOT NULL,
    shift       ENUM('morning','evening') NOT NULL,
    max_students TINYINT UNSIGNED NOT NULL DEFAULT 20 COMMENT 'Максимальна кількість курсантів, що навчаються',
    PRIMARY KEY (group_id),
    UNIQUE KEY uq_groups_name (name),
    KEY ix_groups_category (category_id),
    CONSTRAINT fk_groups_category FOREIGN KEY (category_id)
        REFERENCES categories (category_id),
    CONSTRAINT ck_groups_dates CHECK (end_date > start_date),
    CONSTRAINT ck_groups_max CHECK (max_students BETWEEN 1 AND 40)
) ENGINE=InnoDB COMMENT='Навчальні групи';

-- Зарахування. agreed_price фіксує ціну на момент зарахування:
-- зміна прейскуранту в categories не змінює борг уже зарахованих курсантів.
-- status_id не має DEFAULT: якщо його не вказано, тригер trg_enrollments_bi
-- підставляє статус за кодом 'studying' (не залежить від порядку вставки довідника).
CREATE TABLE enrollments (
    enrollment_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    student_id    INT UNSIGNED NOT NULL,
    group_id      INT UNSIGNED NOT NULL,
    enrolled_on   DATE NOT NULL,
    agreed_price  DECIMAL(10,2) NOT NULL COMMENT 'Ціна курсу на момент зарахування (з урахуванням знижки)',
    discount_note VARCHAR(100) NULL COMMENT 'Підстава знижки, якщо є',
    status_id     TINYINT UNSIGNED NOT NULL,
    PRIMARY KEY (enrollment_id),
    UNIQUE KEY uq_enrollments_student_group (student_id, group_id),
    KEY ix_enrollments_group (group_id),
    CONSTRAINT fk_enrollments_student FOREIGN KEY (student_id)
        REFERENCES students (student_id),
    CONSTRAINT fk_enrollments_group FOREIGN KEY (group_id)
        REFERENCES study_groups (group_id),
    CONSTRAINT fk_enrollments_status FOREIGN KEY (status_id)
        REFERENCES enrollment_statuses (status_id),
    CONSTRAINT ck_enrollments_price CHECK (agreed_price >= 0)
) ENGINE=InnoDB COMMENT='Зарахування курсантів до груп';

-- ---------------------------------------------------------------------
-- ЗАНЯТТЯ ТА ВІДВІДУВАНІСТЬ
-- ---------------------------------------------------------------------

CREATE TABLE theory_lessons (
    lesson_id      INT UNSIGNED NOT NULL AUTO_INCREMENT,
    group_id       INT UNSIGNED NOT NULL,
    teacher_id     INT UNSIGNED NOT NULL,
    starts_at      DATETIME NOT NULL,
    duration_hours DECIMAL(3,1) NOT NULL DEFAULT 2.0,
    ends_at        DATETIME GENERATED ALWAYS AS
                   (starts_at + INTERVAL ROUND(duration_hours * 60) MINUTE) STORED,
    topic          VARCHAR(150) NOT NULL,
    status         ENUM('planned','done','cancelled') NOT NULL DEFAULT 'planned'
                   COMMENT 'planned - заплановано, done - проведено, cancelled - скасовано (не займає слот)',
    PRIMARY KEY (lesson_id),
    KEY ix_theory_group (group_id, starts_at),
    KEY ix_theory_teacher (teacher_id, starts_at),
    CONSTRAINT fk_theory_group FOREIGN KEY (group_id)
        REFERENCES study_groups (group_id),
    CONSTRAINT fk_theory_teacher FOREIGN KEY (teacher_id)
        REFERENCES employees (employee_id),
    CONSTRAINT ck_theory_duration CHECK (duration_hours > 0 AND duration_hours <= 6)
) ENGINE=InnoDB COMMENT='Теоретичні заняття';

CREATE TABLE theory_attendance (
    lesson_id     INT UNSIGNED NOT NULL,
    enrollment_id INT UNSIGNED NOT NULL,
    present       BOOLEAN NOT NULL,
    absence_reason ENUM('illness','excused','unexcused') NULL
                   COMMENT 'illness - хвороба, excused - поважна причина, unexcused - без поважної причини',
    PRIMARY KEY (lesson_id, enrollment_id),
    KEY ix_attendance_enrollment (enrollment_id),
    CONSTRAINT fk_attendance_lesson FOREIGN KEY (lesson_id)
        REFERENCES theory_lessons (lesson_id) ON DELETE CASCADE,
    CONSTRAINT fk_attendance_enrollment FOREIGN KEY (enrollment_id)
        REFERENCES enrollments (enrollment_id) ON DELETE CASCADE,
    -- присутній -> причини немає; відсутній -> причина обов'язкова
    CONSTRAINT ck_attendance_reason CHECK (
        (present = TRUE  AND absence_reason IS NULL) OR
        (present = FALSE AND absence_reason IS NOT NULL))
) ENGINE=InnoDB COMMENT='Відвідуваність теоретичних занять';

-- Практичні заняття. instructor_id - ФАКТИЧНИЙ інструктор цього заняття (історія закріплень).
-- ends_at обчислюється автоматично і використовується для перевірки накладок.
CREATE TABLE practice_lessons (
    lesson_id      INT UNSIGNED NOT NULL AUTO_INCREMENT,
    enrollment_id  INT UNSIGNED NOT NULL,
    instructor_id  INT UNSIGNED NOT NULL,
    vehicle_id     INT UNSIGNED NOT NULL,
    starts_at      DATETIME NOT NULL,
    duration_hours DECIMAL(3,1) NOT NULL DEFAULT 1.0,
    ends_at        DATETIME GENERATED ALWAYS AS
                   (starts_at + INTERVAL ROUND(duration_hours * 60) MINUTE) STORED,
    status         ENUM('planned','done','missed','cancelled') NOT NULL DEFAULT 'planned'
                   COMMENT 'planned - заплановано, done - проведено, missed - пропущено курсантом, cancelled - скасовано',
    PRIMARY KEY (lesson_id),
    KEY ix_practice_instructor (instructor_id, starts_at),
    KEY ix_practice_vehicle (vehicle_id, starts_at),
    KEY ix_practice_enrollment (enrollment_id, status),
    CONSTRAINT fk_practice_enrollment FOREIGN KEY (enrollment_id)
        REFERENCES enrollments (enrollment_id),
    CONSTRAINT fk_practice_instructor FOREIGN KEY (instructor_id)
        REFERENCES employees (employee_id),
    CONSTRAINT fk_practice_vehicle FOREIGN KEY (vehicle_id)
        REFERENCES vehicles (vehicle_id),
    CONSTRAINT ck_practice_duration CHECK (duration_hours > 0 AND duration_hours <= 4)
) ENGINE=InnoDB COMMENT='Практичні заняття з водіння';

-- ---------------------------------------------------------------------
-- ІСПИТИ ТА ОПЛАТА
-- ---------------------------------------------------------------------

CREATE TABLE exams (
    exam_id       INT UNSIGNED NOT NULL AUTO_INCREMENT,
    enrollment_id INT UNSIGNED NOT NULL,
    exam_type_id  TINYINT UNSIGNED NOT NULL,
    exam_date     DATE NOT NULL,
    attempt_no    TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT 'Розраховується тригером',
    score         TINYINT UNSIGNED NULL COMMENT 'Бал 0-100; NULL для практичного іспиту (оцінюється заліком)',
    passed        BOOLEAN NOT NULL COMMENT 'Бальний іспит: обчислює тригер (score >= pass_score). Залік: обов''язково вказує екзаменатор (без DEFAULT, щоб пропуск не перетворився на "не склав")',
    PRIMARY KEY (exam_id),
    UNIQUE KEY uq_exams_attempt (enrollment_id, exam_type_id, attempt_no),
    CONSTRAINT fk_exams_enrollment FOREIGN KEY (enrollment_id)
        REFERENCES enrollments (enrollment_id),
    CONSTRAINT fk_exams_type FOREIGN KEY (exam_type_id)
        REFERENCES exam_types (exam_type_id),
    CONSTRAINT ck_exams_score CHECK (score IS NULL OR score BETWEEN 0 AND 100)
) ENGINE=InnoDB COMMENT='Іспити курсантів';

-- Платежі та повернення. amount завжди > 0, напрямок задає kind:
-- баланс = SUM(payment) - SUM(refund). Так CHECK залишається простим і зрозумілим,
-- а повернення не маскуються під "від'ємну оплату".
CREATE TABLE payments (
    payment_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    enrollment_id INT UNSIGNED NOT NULL,
    kind          ENUM('payment','refund') NOT NULL DEFAULT 'payment'
                  COMMENT 'payment - оплата, refund - повернення коштів',
    amount        DECIMAL(10,2) NOT NULL,
    paid_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                  COMMENT 'За замовчуванням - поточний момент; можна передати власну дату (внесення оплати заднім числом за квитанцією)',
    method_id     TINYINT UNSIGNED NOT NULL,
    note          VARCHAR(150) NULL COMMENT 'Коментар, напр. підстава повернення',
    PRIMARY KEY (payment_id),
    KEY ix_payments_enrollment (enrollment_id, paid_at),
    CONSTRAINT fk_payments_enrollment FOREIGN KEY (enrollment_id)
        REFERENCES enrollments (enrollment_id),
    CONSTRAINT fk_payments_method FOREIGN KEY (method_id)
        REFERENCES payment_methods (method_id),
    CONSTRAINT ck_payments_amount CHECK (amount > 0)
) ENGINE=InnoDB COMMENT='Платежі за навчання';

-- ---------------------------------------------------------------------
-- СЛУЖБОВА ТАБЛИЦЯ АУДИТУ (заповнюється тригерами)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    table_name VARCHAR(64) NOT NULL,
    operation  ENUM('INSERT','UPDATE','DELETE') NOT NULL,
    record_id  INT UNSIGNED NOT NULL,
    changed_by VARCHAR(100) NOT NULL,
    changed_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    old_value  JSON NULL,
    new_value  JSON NULL,
    PRIMARY KEY (audit_id),
    KEY ix_audit_table_record (table_name, record_id),
    KEY ix_audit_changed_at (changed_at)
) ENGINE=InnoDB COMMENT='Журнал аудиту змін';
