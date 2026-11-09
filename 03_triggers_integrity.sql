-- =====================================================================
-- Файл 3: тригери цілісності даних
--   - захист системних статусів зарахування
--   - статус і ціна за замовчуванням при зарахуванні (без "магічних" id)
--   - контроль місткості групи (max_students)
--   - контроль оплат і повернень коштів
--   - контроль відвідуваності теорії
--   - узгодженість іспитів: номер спроби, бал і результат
--
-- Правила, яких дотримуються всі процедури й тригери:
--   * лише локальні змінні (DECLARE), ніколи сесійні @змінні: @змінна живе
--     всю сесію, і якщо SELECT ... INTO не знайде рядка, у ній залишиться
--     значення з попереднього виклику;
--   * NULL-safe: SELECT ... INTO, що не знайшов рядка, залишає змінну NULL,
--     а порівняння з NULL дає NULL (не TRUE), тому перевірка "мовчки" пройшла б.
--     Існування кожного рядка перевіряється явно (IS NULL) з зрозумілим повідомленням.
-- =====================================================================

-- Кодування з'єднання: без цього клієнт може працювати в latin1,
-- і кирилиця збережеться подвійно закодованою («кракозябри» в інших клієнтах)
SET NAMES utf8mb4;
USE driving_school;

DROP TRIGGER IF EXISTS trg_statuses_bd;
DROP TRIGGER IF EXISTS trg_statuses_bu;
DROP TRIGGER IF EXISTS trg_enrollments_bi;
DROP TRIGGER IF EXISTS trg_enrollments_bu;
DROP TRIGGER IF EXISTS trg_payments_bi;
DROP TRIGGER IF EXISTS trg_employees_bu;
DROP TRIGGER IF EXISTS trg_vehicles_bi;
DROP TRIGGER IF EXISTS trg_vehicles_bu;
DROP PROCEDURE IF EXISTS sp_check_vehicle_instructor;
DROP PROCEDURE IF EXISTS sp_check_same_category;
DROP TRIGGER IF EXISTS trg_attendance_bi;
DROP TRIGGER IF EXISTS trg_attendance_bu;
DROP TRIGGER IF EXISTS trg_attendance_ai;
DROP TRIGGER IF EXISTS trg_exams_bi;
DROP TRIGGER IF EXISTS trg_exams_bu;
DROP PROCEDURE IF EXISTS sp_check_group_capacity;
DROP PROCEDURE IF EXISTS sp_check_attendance;
DROP PROCEDURE IF EXISTS sp_exam_resolve_passed;

DELIMITER $$

-- ---------------------------------------------------------------------
-- 1. Системні статуси не можна видалити або змінити їхній код
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_statuses_bd
BEFORE DELETE ON enrollment_statuses
FOR EACH ROW
BEGIN
    IF OLD.is_system THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Системний статус зарахування не можна видалити';
    END IF;
END$$

CREATE TRIGGER trg_statuses_bu
BEFORE UPDATE ON enrollment_statuses
FOR EACH ROW
BEGIN
    IF OLD.is_system AND (NEW.code <> OLD.code OR NOT NEW.is_system) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Код системного статусу змінювати не можна';
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 2. Місткість групи: курсантів зі статусом 'studying' <= max_students.
--    Рядок групи блокується (FOR UPDATE), щоб два паралельні зарахування
--    не зайняли одне останнє місце.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_check_group_capacity(
    IN p_group_id      INT UNSIGNED,
    IN p_enrollment_id INT UNSIGNED   -- 0 для нового зарахування
)
BEGIN
    DECLARE v_max INT DEFAULT NULL;
    DECLARE v_cnt INT DEFAULT 0;

    SELECT max_students INTO v_max
      FROM study_groups WHERE group_id = p_group_id
       FOR UPDATE;

    IF v_max IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Групу не знайдено';
    END IF;

    SELECT COUNT(*) INTO v_cnt
      FROM enrollments e
      JOIN enrollment_statuses s ON s.status_id = e.status_id
     WHERE e.group_id = p_group_id
       AND s.code = 'studying'
       AND e.enrollment_id <> p_enrollment_id
       FOR SHARE;

    IF v_cnt >= v_max THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'У групі немає вільних місць';
    END IF;
END$$

-- ---------------------------------------------------------------------
-- Курсант не може одночасно навчатися на одну категорію у двох групах
-- (активними вважаються статуси 'studying' і 'leave' - з академвідпустки
--  курсант повертається у свою групу)
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_check_same_category(
    IN p_student_id    INT UNSIGNED,
    IN p_group_id      INT UNSIGNED,
    IN p_enrollment_id INT UNSIGNED   -- 0 для нового зарахування
)
BEGIN
    IF EXISTS (
        SELECT 1
          FROM enrollments e
          JOIN study_groups g         ON g.group_id  = e.group_id
          JOIN enrollment_statuses s  ON s.status_id = e.status_id
         WHERE e.student_id = p_student_id
           AND e.enrollment_id <> p_enrollment_id
           AND s.code IN ('studying', 'leave')
           AND g.category_id = (SELECT category_id FROM study_groups WHERE group_id = p_group_id)) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Курсант уже навчається на цю категорію в іншій групі';
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 3. Зарахування: статус і ціна за замовчуванням, строк групи,
--    одна категорія - одне активне навчання, місткість групи
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_enrollments_bi
BEFORE INSERT ON enrollments
FOR EACH ROW
BEGIN
    DECLARE v_studying_id TINYINT UNSIGNED DEFAULT NULL;
    DECLARE v_price       DECIMAL(10,2)    DEFAULT NULL;   -- локальна, а не @v_price
    DECLARE v_end_date    DATE             DEFAULT NULL;

    SELECT status_id INTO v_studying_id
      FROM enrollment_statuses WHERE code = 'studying';
    IF v_studying_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'У довіднику відсутній статус studying';
    END IF;

    -- Статус не вказано -> 'studying' (шукаємо за кодом, а не за числом 1)
    IF NEW.status_id IS NULL THEN
        SET NEW.status_id = v_studying_id;
    END IF;

    -- Ціну не вказано -> поточна ціна категорії групи
    IF NEW.agreed_price IS NULL THEN
        SELECT c.price INTO v_price
          FROM study_groups g
          JOIN categories c ON c.category_id = g.category_id
         WHERE g.group_id = NEW.group_id;
        -- INNER JOIN не поверне рядка, якщо немає групи АБО її категорії:
        -- обидва випадки дають v_price IS NULL і зрозуміле повідомлення (а не помилку FK)
        IF v_price IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Групу або її категорію не знайдено: неможливо визначити ціну курсу';
        END IF;
        SET NEW.agreed_price = v_price;
    END IF;

    -- Зарахувати можна лише до групи, навчання в якій ще не завершилось
    -- (порівнюється з датою зарахування, а не з сьогоднішньою: тестові дані
    --  про минулі групи вносяться з датами того часу)
    SELECT end_date INTO v_end_date FROM study_groups WHERE group_id = NEW.group_id;
    IF v_end_date IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Групу не знайдено';
    END IF;
    IF NEW.enrolled_on > v_end_date THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Навчання в цій групі вже завершилося';
    END IF;

    IF NEW.status_id = v_studying_id THEN
        CALL sp_check_same_category(NEW.student_id, NEW.group_id, 0);
        CALL sp_check_group_capacity(NEW.group_id, 0);
    END IF;
END$$

CREATE TRIGGER trg_enrollments_bu
BEFORE UPDATE ON enrollments
FOR EACH ROW
BEGIN
    DECLARE v_studying_id TINYINT UNSIGNED DEFAULT NULL;

    SELECT status_id INTO v_studying_id
      FROM enrollment_statuses WHERE code = 'studying';
    IF v_studying_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'У довіднику відсутній статус studying';
    END IF;

    -- Повернення з академвідпустки або переведення в іншу групу займає місце
    IF NEW.status_id = v_studying_id
       AND (OLD.status_id <> v_studying_id OR NEW.group_id <> OLD.group_id) THEN
        CALL sp_check_same_category(NEW.student_id, NEW.group_id, OLD.enrollment_id);
        CALL sp_check_group_capacity(NEW.group_id, OLD.enrollment_id);
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 4. Оплати та повернення
--    payment: сплачено + нова сума <= зафіксована ціна (без переплати)
--    refund : сума повернення <= фактично сплачене
--    Зарахування блокується, щоб паралельні платежі не обійшли перевірку.
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_payments_bi
BEFORE INSERT ON payments
FOR EACH ROW
BEGIN
    DECLARE v_price   DECIMAL(10,2) DEFAULT NULL;
    DECLARE v_balance DECIMAL(10,2) DEFAULT 0;

    SELECT agreed_price INTO v_price
      FROM enrollments WHERE enrollment_id = NEW.enrollment_id
       FOR UPDATE;
    IF v_price IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Зарахування не знайдено';
    END IF;

    SELECT COALESCE(SUM(CASE WHEN kind = 'payment' THEN amount ELSE -amount END), 0)
      INTO v_balance
      FROM payments
     WHERE enrollment_id = NEW.enrollment_id
       FOR SHARE;

    -- Від відрахованого курсанта оплата не приймається (можливе лише повернення)
    IF NEW.kind = 'payment' AND EXISTS (
        SELECT 1 FROM enrollments e JOIN enrollment_statuses s ON s.status_id = e.status_id
         WHERE e.enrollment_id = NEW.enrollment_id AND s.code = 'expelled') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Курсанта відраховано: оплата не приймається, можливе лише повернення';
    END IF;

    IF NEW.kind = 'payment' AND v_balance + NEW.amount > v_price THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Сума оплати перевищує залишок вартості навчання';
    END IF;
    IF NEW.kind = 'refund' AND NEW.amount > v_balance THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Сума повернення перевищує фактично сплачену суму';
    END IF;
END$$

-- ---------------------------------------------------------------------
-- Звільнення співробітника: не можна, поки за ним лишаються майбутні
-- заплановані заняття (інакше курсанти чекатимуть людину, якої вже немає).
-- Їх треба спершу скасувати або передати іншому інструктору / викладачу.
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_employees_bu
BEFORE UPDATE ON employees
FOR EACH ROW
BEGIN
    DECLARE v_practice INT DEFAULT 0;
    DECLARE v_theory   INT DEFAULT 0;
    DECLARE v_msg      VARCHAR(255);

    IF OLD.is_active AND NOT NEW.is_active THEN
        SELECT COUNT(*) INTO v_practice FROM practice_lessons
         WHERE instructor_id = OLD.employee_id AND status = 'planned' AND starts_at > NOW();
        SELECT COUNT(*) INTO v_theory FROM theory_lessons
         WHERE teacher_id = OLD.employee_id AND status = 'planned' AND starts_at > NOW();
        IF v_practice + v_theory > 0 THEN
            SET v_msg = CONCAT('Неможливо звільнити: заплановано ще ', v_practice, ' практичних і ',
                               v_theory, ' теоретичних занять. Спершу скасуйте їх або передайте іншому співробітнику');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;
    END IF;
END$$

-- ---------------------------------------------------------------------
-- Автомобілі
--   * закріплений інструктор - активний інструктор з правом на категорію авто;
--   * списати авто не можна, поки на ньому є майбутні заплановані заняття.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_check_vehicle_instructor(IN p_instructor_id INT UNSIGNED, IN p_category_id TINYINT UNSIGNED)
BEGIN
    IF p_instructor_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM employees e
          JOIN employee_categories ec ON ec.employee_id = e.employee_id
         WHERE e.employee_id = p_instructor_id AND e.role = 'instructor' AND e.is_active
           AND ec.category_id = p_category_id
           AND (ec.valid_until IS NULL OR ec.valid_until >= CURDATE())) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Закріплений інструктор має бути активним і мати право на категорію автомобіля';
    END IF;
END$$

CREATE TRIGGER trg_vehicles_bi
BEFORE INSERT ON vehicles
FOR EACH ROW
BEGIN
    CALL sp_check_vehicle_instructor(NEW.default_instructor_id, NEW.category_id);
END$$

CREATE TRIGGER trg_vehicles_bu
BEFORE UPDATE ON vehicles
FOR EACH ROW
BEGIN
    DECLARE v_cnt INT DEFAULT 0;
    DECLARE v_msg VARCHAR(255);
    IF NOT (NEW.default_instructor_id <=> OLD.default_instructor_id) OR NEW.category_id <> OLD.category_id THEN
        CALL sp_check_vehicle_instructor(NEW.default_instructor_id, NEW.category_id);
    END IF;
    IF OLD.is_active AND NOT NEW.is_active THEN
        SELECT COUNT(*) INTO v_cnt FROM practice_lessons
         WHERE vehicle_id = OLD.vehicle_id AND status = 'planned' AND starts_at > NOW();
        IF v_cnt > 0 THEN
            SET v_msg = CONCAT('Неможливо списати: на автомобіль заплановано ще ', v_cnt,
                               ' занять. Спершу скасуйте їх або перенесіть на інше авто');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 5. Відвідуваність теорії
--    - заняття і зарахування мають існувати (NULL-safe)
--    - не можна відмічати скасоване заняття
--    - лише курсанти групи, для якої проводилось заняття
--    - лише після початку заняття
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_check_attendance(
    IN p_lesson_id     INT UNSIGNED,
    IN p_enrollment_id INT UNSIGNED
)
BEGIN
    DECLARE v_lesson_group  INT UNSIGNED DEFAULT NULL;
    DECLARE v_lesson_start  DATETIME     DEFAULT NULL;
    DECLARE v_lesson_status VARCHAR(20)  DEFAULT NULL;
    DECLARE v_enr_group     INT UNSIGNED DEFAULT NULL;
    DECLARE v_enrolled_on   DATE         DEFAULT NULL;

    SELECT group_id, starts_at, status
      INTO v_lesson_group, v_lesson_start, v_lesson_status
      FROM theory_lessons WHERE lesson_id = p_lesson_id;
    IF v_lesson_group IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Теоретичне заняття не знайдено';
    END IF;

    SELECT group_id, enrolled_on INTO v_enr_group, v_enrolled_on
      FROM enrollments WHERE enrollment_id = p_enrollment_id;
    IF v_enr_group IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Зарахування не знайдено';
    END IF;

    IF v_lesson_status = 'cancelled' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Заняття скасовано: відвідуваність не ведеться';
    END IF;
    IF v_lesson_group <> v_enr_group THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Курсант не належить до групи, для якої проводилось заняття';
    END IF;
    IF v_lesson_start > NOW() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Не можна відмітити відвідування заняття, яке ще не відбулося';
    END IF;
    -- заняття до зарахування курсанта не зараховуються в його години
    IF DATE(v_lesson_start) < v_enrolled_on THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Заняття відбулося до зарахування курсанта до групи';
    END IF;
END$$

CREATE TRIGGER trg_attendance_bi
BEFORE INSERT ON theory_attendance
FOR EACH ROW
BEGIN
    CALL sp_check_attendance(NEW.lesson_id, NEW.enrollment_id);
END$$

-- Перевірка виконується при БУДЬ-ЯКІЙ зміні, зокрема лише present/absence_reason:
-- інакше на заняття, скасоване вже після відмітки, можна було б змінювати присутність.
-- Після першої відмітки відвідуваності заняття вважається проведеним
-- (інакше минулі заняття назавжди лишалися б «запланованими»)
CREATE TRIGGER trg_attendance_ai
AFTER INSERT ON theory_attendance
FOR EACH ROW
BEGIN
    UPDATE theory_lessons SET status = 'done'
     WHERE lesson_id = NEW.lesson_id AND status = 'planned';
END$$

CREATE TRIGGER trg_attendance_bu
BEFORE UPDATE ON theory_attendance
FOR EACH ROW
BEGIN
    CALL sp_check_attendance(NEW.lesson_id, NEW.enrollment_id);
END$$

-- ---------------------------------------------------------------------
-- 6. Іспити: узгодженість score і passed
--    Бальний іспит (pass_score задано): score обов'язковий, passed = score >= pass_score
--       (обчислюється автоматично, вручну не задається - суперечність неможлива).
--    Залік (pass_score = NULL): score має бути NULL, passed задається екзаменатором.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_exam_resolve_passed(
    IN    p_exam_type_id TINYINT UNSIGNED,
    IN    p_score        TINYINT UNSIGNED,
    INOUT p_passed       BOOLEAN
)
BEGIN
    DECLARE v_type_found BOOLEAN DEFAULT FALSE;
    DECLARE v_pass_score TINYINT UNSIGNED DEFAULT NULL;

    SELECT TRUE, pass_score INTO v_type_found, v_pass_score
      FROM exam_types WHERE exam_type_id = p_exam_type_id;
    IF NOT v_type_found THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Тип іспиту не знайдено';
    END IF;

    IF v_pass_score IS NOT NULL THEN
        IF p_score IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Для бального іспиту необхідно вказати бал';
        END IF;
        SET p_passed = (p_score >= v_pass_score);
    ELSE
        IF p_score IS NOT NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Для іспиту-заліку бал не виставляється';
        END IF;
        -- Залік: результат має явно вказати екзаменатор.
        -- Поле passed не має DEFAULT, тому пропущене значення тут = NULL, а не FALSE.
        IF p_passed IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Для іспиту-заліку необхідно вказати результат (passed)';
        END IF;
    END IF;
END$$

-- Номер спроби: наступний після останньої спроби цього типу.
-- Повторна спроба після успішної здачі заборонена.
CREATE TRIGGER trg_exams_bi
BEFORE INSERT ON exams
FOR EACH ROW
BEGIN
    DECLARE v_enr_found BOOLEAN DEFAULT FALSE;
    DECLARE v_passed    INT DEFAULT 0;
    DECLARE v_last      INT DEFAULT 0;
    DECLARE v_passed_value BOOLEAN;

    -- блокування зарахування: дві паралельні вставки не отримають однаковий номер спроби
    SELECT TRUE INTO v_enr_found
      FROM enrollments WHERE enrollment_id = NEW.enrollment_id
       FOR UPDATE;
    IF NOT v_enr_found THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Зарахування не знайдено';
    END IF;

    SELECT COALESCE(MAX(attempt_no), 0), COALESCE(SUM(passed), 0)
      INTO v_last, v_passed
      FROM exams
     WHERE enrollment_id = NEW.enrollment_id
       AND exam_type_id  = NEW.exam_type_id
       FOR SHARE;
    IF v_passed > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Іспит цього типу вже складено';
    END IF;
    SET NEW.attempt_no = v_last + 1;

    SET v_passed_value = NEW.passed;
    CALL sp_exam_resolve_passed(NEW.exam_type_id, NEW.score, v_passed_value);
    SET NEW.passed = v_passed_value;
END$$

-- При виправленні балу результат перераховується
CREATE TRIGGER trg_exams_bu
BEFORE UPDATE ON exams
FOR EACH ROW
BEGIN
    DECLARE v_passed_value BOOLEAN;
    IF NEW.exam_type_id <> OLD.exam_type_id OR NEW.enrollment_id <> OLD.enrollment_id
       OR NEW.attempt_no <> OLD.attempt_no THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Змінювати тип, курсанта або номер спроби іспиту не можна';
    END IF;
    SET v_passed_value = NEW.passed;
    CALL sp_exam_resolve_passed(NEW.exam_type_id, NEW.score, v_passed_value);
    SET NEW.passed = v_passed_value;

    -- Якщо виправлення робить спробу успішною, а після неї вже є інші спроби,
    -- виникла б суперечність ("склав", але потім перескладав)
    IF NEW.passed AND NOT OLD.passed AND EXISTS (
        SELECT 1 FROM exams
         WHERE enrollment_id = OLD.enrollment_id
           AND exam_type_id  = OLD.exam_type_id
           AND attempt_no    > OLD.attempt_no) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Неможливо зарахувати спробу: після неї вже є наступні спроби';
    END IF;
END$$

DELIMITER ;
