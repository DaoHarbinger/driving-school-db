-- =====================================================================
-- Файл 2: тригери контролю розкладу (практичні та теоретичні заняття)
--
-- Захист від race condition:
--   Перевірка "чи вільний слот" і вставка - дві окремі дії. Якщо дві сесії
--   одночасно перевіряють той самий слот, обидві можуть побачити "вільно".
--   Тому на початку перевірки процедура бере ексклюзивне блокування
--   (SELECT ... FOR UPDATE) на "батьківські" рядки ресурсів: інструктора,
--   автомобіль, курсанта (або викладача, групу та її курсантів для теорії).
--   Друга сесія чекає, доки перша завершить транзакцію (COMMIT/ROLLBACK),
--   і лише потім виконує перевірку - вже бачачи вставлений рядок.
--   Підрахунки накладок виконуються як блокуючі читання (FOR SHARE),
--   щоб читати останні зафіксовані дані, а не знімок початку транзакції.
--   Порядок блокувань сталий (співробітник -> авто -> група -> курсанти),
--   що мінімізує ризик взаємних блокувань (deadlock).
--
-- Оптимізація (за результатами 08_performance.sql):
--   * умова перетину starts_at < кінець не має нижньої межі, і MySQL читав
--     УСІ заняття інструктора до цієї дати (7 167 рядків на 500 тис.).
--     Тривалість практики <= 4 год, теорії <= 6 год (CHECK), тому будь-яке
--     заняття, що перетинається з новим, почалося не раніше ніж за 4 (6) год
--     до його початку - додано нижню межу, і діапазон індексу став вузьким;
--   * DATE(starts_at) = d замінено на діапазон starts_at >= d AND < d + 1:
--     функція над стовпцем не дає використати індекс як діапазон.
-- =====================================================================

-- Кодування з'єднання: без цього клієнт може працювати в latin1,
-- і кирилиця збережеться подвійно закодованою («кракозябри» в інших клієнтах)
SET NAMES utf8mb4;
USE driving_school;

DROP PROCEDURE IF EXISTS sp_check_practice_lesson;
DROP PROCEDURE IF EXISTS sp_check_theory_lesson;
DROP TRIGGER IF EXISTS trg_practice_bi;
DROP TRIGGER IF EXISTS trg_practice_bu;
DROP TRIGGER IF EXISTS trg_theory_bi;
DROP TRIGGER IF EXISTS trg_theory_bu;

DELIMITER $$

-- ---------------------------------------------------------------------
-- ПРАКТИЧНІ ЗАНЯТТЯ
-- p_lesson_id = 0 для нового заняття
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_check_practice_lesson(
    IN p_lesson_id     INT UNSIGNED,
    IN p_enrollment_id INT UNSIGNED,
    IN p_instructor_id INT UNSIGNED,
    IN p_vehicle_id    INT UNSIGNED,
    IN p_starts_at     DATETIME,
    IN p_duration      DECIMAL(3,1)
)
BEGIN
    DECLARE v_ends_at        DATETIME;
    DECLARE v_student_id     INT UNSIGNED;
    DECLARE v_group_cat      TINYINT UNSIGNED;
    DECLARE v_group_start    DATE;
    DECLARE v_group_end      DATE;
    DECLARE v_status_code    VARCHAR(20);
    DECLARE v_role           VARCHAR(20);
    DECLARE v_emp_active     BOOLEAN;
    DECLARE v_vehicle_cat    TINYINT UNSIGNED;
    DECLARE v_vehicle_active BOOLEAN;
    DECLARE v_service_date   DATE;
    DECLARE v_cnt            INT;
    DECLARE v_hours          DECIMAL(5,1);   -- сума годин: DECIMAL, а не INT
    DECLARE v_lesson_date    DATE;

    SET v_ends_at     = p_starts_at + INTERVAL ROUND(p_duration * 60) MINUTE;
    SET v_lesson_date = DATE(p_starts_at);

    -- Блокування ресурсів (захист від паралельних вставок) -------------
    SELECT role, is_active INTO v_role, v_emp_active
      FROM employees WHERE employee_id = p_instructor_id
       FOR UPDATE;

    SELECT category_id, is_active, next_service_date
      INTO v_vehicle_cat, v_vehicle_active, v_service_date
      FROM vehicles WHERE vehicle_id = p_vehicle_id
       FOR UPDATE;

    SELECT e.student_id, g.category_id, g.start_date, g.end_date, s.code
      INTO v_student_id, v_group_cat, v_group_start, v_group_end, v_status_code
      FROM enrollments e
      JOIN study_groups g        ON g.group_id  = e.group_id
      JOIN enrollment_statuses s ON s.status_id = e.status_id
     WHERE e.enrollment_id = p_enrollment_id;

    SELECT student_id INTO v_student_id
      FROM students WHERE student_id = v_student_id
       FOR UPDATE;

    -- NULL-safe: якщо рядок не знайдено, змінні лишаються NULL, і порівняння
    -- на кшталт v_role <> 'instructor' дало б NULL (тобто "не помилка").
    -- Тому існування перевіряємо явно і даємо зрозуміле повідомлення.
    IF v_role IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Інструктора не знайдено';
    END IF;
    IF v_vehicle_cat IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Автомобіль не знайдено';
    END IF;
    IF v_status_code IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Зарахування не знайдено';
    END IF;

    -- 1. Курсант має активний статус навчання
    IF v_status_code <> 'studying' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Курсант не має активного статусу навчання';
    END IF;

    -- 2. Чинна медична довідка на дату заняття
    SELECT COUNT(*) INTO v_cnt
      FROM documents d
      JOIN document_types t ON t.document_type_id = d.document_type_id
     WHERE d.student_id = v_student_id
       AND t.code = 'medical'
       AND d.issue_date <= v_lesson_date
       AND (d.valid_until IS NULL OR d.valid_until >= v_lesson_date);
    IF v_cnt = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Курсант не має чинної медичної довідки на дату заняття';
    END IF;

    -- 3. Заняття в межах строку навчання групи
    IF v_lesson_date NOT BETWEEN v_group_start AND v_group_end THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Дата заняття поза строком навчання групи';
    END IF;

    -- 4. Робочий час автошколи 07:00 - 21:00
    IF TIME(p_starts_at) < '07:00:00' OR TIME(v_ends_at) > '21:00:00'
       OR DATE(v_ends_at) <> v_lesson_date THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Заняття виходить за межі робочого часу (07:00-21:00)';
    END IF;

    -- 5. Співробітник - активний інструктор
    IF v_role <> 'instructor' OR NOT v_emp_active THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Співробітник не є активним інструктором з водіння';
    END IF;

    -- 6. Чинне право інструктора навчати категорії групи
    SELECT COUNT(*) INTO v_cnt
      FROM employee_categories
     WHERE employee_id = p_instructor_id
       AND category_id = v_group_cat
       AND granted_date <= v_lesson_date
       AND (valid_until IS NULL OR valid_until >= v_lesson_date);
    IF v_cnt = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Інструктор не має чинного права навчати цієї категорії';
    END IF;

    -- 7. Автомобіль активний, відповідної категорії, без простроченого ТО
    IF NOT v_vehicle_active THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Автомобіль виведено з експлуатації';
    END IF;
    IF v_vehicle_cat <> v_group_cat THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Категорія автомобіля не відповідає категорії навчання';
    END IF;
    IF v_service_date < v_lesson_date THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Автомобіль має прострочене технічне обслуговування';
    END IF;

    -- 8. Накладка інструктора. Інтервали [a1,a2) і [b1,b2) перетинаються, якщо a1 < b2 AND b1 < a2
    SELECT COUNT(*) INTO v_cnt
      FROM practice_lessons
     WHERE instructor_id = p_instructor_id
       AND lesson_id <> p_lesson_id
       AND status <> 'cancelled'
       AND starts_at > p_starts_at - INTERVAL 4 HOUR   -- нижня межа: заняття <= 4 год
       AND starts_at < v_ends_at AND ends_at > p_starts_at
       FOR SHARE;
    IF v_cnt > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Інструктор уже зайнятий у цей час';
    END IF;

    -- 9. Накладка автомобіля
    SELECT COUNT(*) INTO v_cnt
      FROM practice_lessons
     WHERE vehicle_id = p_vehicle_id
       AND lesson_id <> p_lesson_id
       AND status <> 'cancelled'
       AND starts_at > p_starts_at - INTERVAL 4 HOUR   -- нижня межа: заняття <= 4 год
       AND starts_at < v_ends_at AND ends_at > p_starts_at
       FOR SHARE;
    IF v_cnt > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Автомобіль уже зайнятий у цей час';
    END IF;

    -- 10. Накладка курсанта (по всіх його зарахуваннях)
    SELECT COUNT(*) INTO v_cnt
      FROM practice_lessons pl
      JOIN enrollments e ON e.enrollment_id = pl.enrollment_id
     WHERE e.student_id = v_student_id
       AND pl.lesson_id <> p_lesson_id
       AND pl.status <> 'cancelled'
       AND pl.starts_at > p_starts_at - INTERVAL 4 HOUR
       AND pl.starts_at < v_ends_at AND pl.ends_at > p_starts_at
       FOR SHARE;
    IF v_cnt > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Курсант уже має практичне заняття в цей час';
    END IF;

    -- 11. Курсант не може водити під час теоретичного заняття будь-якої зі своїх груп
    SELECT COUNT(*) INTO v_cnt
      FROM theory_lessons tl
      JOIN enrollments e         ON e.group_id  = tl.group_id
      JOIN enrollment_statuses s ON s.status_id = e.status_id
     WHERE e.student_id = v_student_id
       AND s.code = 'studying'
       AND tl.status <> 'cancelled'
       AND tl.starts_at > p_starts_at - INTERVAL 6 HOUR
       AND tl.starts_at < v_ends_at AND tl.ends_at > p_starts_at
       FOR SHARE;
    IF v_cnt > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'У курсанта в цей час теоретичне заняття';
    END IF;

    -- 12. Денне навантаження інструктора - не більше 8 годин
    SELECT COALESCE(SUM(duration_hours), 0) INTO v_hours
      FROM practice_lessons
     WHERE instructor_id = p_instructor_id
       AND lesson_id <> p_lesson_id
       AND status <> 'cancelled'
       AND starts_at >= v_lesson_date AND starts_at < v_lesson_date + INTERVAL 1 DAY
       FOR SHARE;
    IF v_hours + p_duration > 8.0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Перевищено денне навантаження інструктора (8 год)';
    END IF;
END$$

CREATE TRIGGER trg_practice_bi
BEFORE INSERT ON practice_lessons
FOR EACH ROW
BEGIN
    IF NEW.status <> 'cancelled' THEN
        CALL sp_check_practice_lesson(0, NEW.enrollment_id, NEW.instructor_id,
                                      NEW.vehicle_id, NEW.starts_at, NEW.duration_hours);
    END IF;
END$$

CREATE TRIGGER trg_practice_bu
BEFORE UPDATE ON practice_lessons
FOR EACH ROW
BEGIN
    -- Перевірка лише при зміні часу/учасників або відновленні скасованого заняття.
    -- Зміна статусу planned -> done / missed не блокується.
    IF NEW.status <> 'cancelled' AND (
           NEW.starts_at      <> OLD.starts_at
        OR NEW.duration_hours <> OLD.duration_hours
        OR NEW.instructor_id  <> OLD.instructor_id
        OR NEW.vehicle_id     <> OLD.vehicle_id
        OR NEW.enrollment_id  <> OLD.enrollment_id
        OR OLD.status = 'cancelled')
    THEN
        CALL sp_check_practice_lesson(OLD.lesson_id, NEW.enrollment_id, NEW.instructor_id,
                                      NEW.vehicle_id, NEW.starts_at, NEW.duration_hours);
    END IF;
END$$

-- ---------------------------------------------------------------------
-- ТЕОРЕТИЧНІ ЗАНЯТТЯ
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_check_theory_lesson(
    IN p_lesson_id  INT UNSIGNED,
    IN p_group_id   INT UNSIGNED,
    IN p_teacher_id INT UNSIGNED,
    IN p_starts_at  DATETIME,
    IN p_duration   DECIMAL(3,1)
)
BEGIN
    DECLARE v_ends_at     DATETIME;
    DECLARE v_lesson_date DATE;
    DECLARE v_role        VARCHAR(20);
    DECLARE v_emp_active  BOOLEAN;
    DECLARE v_group_cat   TINYINT UNSIGNED;
    DECLARE v_group_start DATE;
    DECLARE v_group_end   DATE;
    DECLARE v_cnt         INT;

    SET v_ends_at     = p_starts_at + INTERVAL ROUND(p_duration * 60) MINUTE;
    SET v_lesson_date = DATE(p_starts_at);

    -- Блокування: викладач -> група -> курсанти групи
    SELECT role, is_active INTO v_role, v_emp_active
      FROM employees WHERE employee_id = p_teacher_id
       FOR UPDATE;

    SELECT category_id, start_date, end_date
      INTO v_group_cat, v_group_start, v_group_end
      FROM study_groups WHERE group_id = p_group_id
       FOR UPDATE;

    SELECT COUNT(*) INTO v_cnt
      FROM students st
     WHERE st.student_id IN (SELECT e.student_id FROM enrollments e WHERE e.group_id = p_group_id)
       FOR UPDATE;

    -- NULL-safe перевірка існування
    IF v_role IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Викладача не знайдено';
    END IF;
    IF v_group_cat IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Групу не знайдено';
    END IF;

    -- 1. Співробітник - активний викладач теорії
    IF v_role <> 'teacher' OR NOT v_emp_active THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Співробітник не є активним викладачем теорії';
    END IF;

    -- 2. Чинне право викладати категорію групи
    SELECT COUNT(*) INTO v_cnt
      FROM employee_categories
     WHERE employee_id = p_teacher_id
       AND category_id = v_group_cat
       AND granted_date <= v_lesson_date
       AND (valid_until IS NULL OR valid_until >= v_lesson_date);
    IF v_cnt = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Викладач не має чинного права викладати цієї категорії';
    END IF;

    -- 3. У межах строку групи та робочого часу
    IF v_lesson_date NOT BETWEEN v_group_start AND v_group_end THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Дата заняття поза строком навчання групи';
    END IF;
    IF TIME(p_starts_at) < '07:00:00' OR TIME(v_ends_at) > '21:00:00'
       OR DATE(v_ends_at) <> v_lesson_date THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Заняття виходить за межі робочого часу (07:00-21:00)';
    END IF;

    -- 4. Накладка викладача (не може вести дві групи одночасно)
    SELECT COUNT(*) INTO v_cnt
      FROM theory_lessons
     WHERE teacher_id = p_teacher_id
       AND lesson_id <> p_lesson_id
       AND status <> 'cancelled'
       AND starts_at > p_starts_at - INTERVAL 6 HOUR   -- нижня межа: заняття <= 6 год
       AND starts_at < v_ends_at AND ends_at > p_starts_at
       FOR SHARE;
    IF v_cnt > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Викладач уже веде заняття в цей час';
    END IF;

    -- 5. Накладка групи (у групи не може бути двох занять одночасно)
    SELECT COUNT(*) INTO v_cnt
      FROM theory_lessons
     WHERE group_id = p_group_id
       AND lesson_id <> p_lesson_id
       AND status <> 'cancelled'
       AND starts_at > p_starts_at - INTERVAL 6 HOUR   -- нижня межа: заняття <= 6 год
       AND starts_at < v_ends_at AND ends_at > p_starts_at
       FOR SHARE;
    IF v_cnt > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Група вже має заняття в цей час';
    END IF;

    -- 6. Курсанти групи не мають у цей час запланованої практики
    SELECT COUNT(*) INTO v_cnt
      FROM practice_lessons pl
      JOIN enrollments e_pl ON e_pl.enrollment_id = pl.enrollment_id
     WHERE pl.status <> 'cancelled'
       AND pl.starts_at > p_starts_at - INTERVAL 4 HOUR
       AND pl.starts_at < v_ends_at AND pl.ends_at > p_starts_at
       AND e_pl.student_id IN (
            SELECT e.student_id
              FROM enrollments e
              JOIN enrollment_statuses s ON s.status_id = e.status_id
             WHERE e.group_id = p_group_id AND s.code = 'studying')
       FOR SHARE;
    IF v_cnt > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Частина курсантів групи має в цей час практичне заняття';
    END IF;
END$$

CREATE TRIGGER trg_theory_bi
BEFORE INSERT ON theory_lessons
FOR EACH ROW
BEGIN
    IF NEW.status <> 'cancelled' THEN
        CALL sp_check_theory_lesson(0, NEW.group_id, NEW.teacher_id, NEW.starts_at, NEW.duration_hours);
    END IF;
END$$

CREATE TRIGGER trg_theory_bu
BEFORE UPDATE ON theory_lessons
FOR EACH ROW
BEGIN
    -- Симетрично до практики: зміна статусу planned -> done/cancelled не блокується,
    -- а відновлення скасованого заняття перевіряється заново.
    IF NEW.status <> 'cancelled' AND (
           NEW.starts_at      <> OLD.starts_at
        OR NEW.duration_hours <> OLD.duration_hours
        OR NEW.teacher_id     <> OLD.teacher_id
        OR NEW.group_id       <> OLD.group_id
        OR OLD.status = 'cancelled')
    THEN
        CALL sp_check_theory_lesson(OLD.lesson_id, NEW.group_id, NEW.teacher_id,
                                    NEW.starts_at, NEW.duration_hours);
    END IF;
END$$

DELIMITER ;
