-- =====================================================================
-- Файл 6: функції, представлення (VIEW) та збережені процедури
--         для функціональних задач ІС
--
--   Задача 1  Список курсантів групи / категорії ..... v_students, sp_students_list
--   Задача 2  Розклад інструктора, запис на практику . sp_instructor_schedule,
--                                                       sp_instructor_free_slots, sp_book_practice
--   Задача 3  Допуск до іспиту ....................... v_exam_admission, sp_check_admission
--   Задача 4  Відвідуваність, «хто не відвідав» ...... sp_attendance_report, sp_absent_list
--   Задача 5  Меддовідки: відсутні / спливають ....... sp_medical_issues
--   Задача 6  Успішність, % з першої спроби .......... v_exam_results_by_group
--   Задача 7  Завантаженість інструкторів ............ sp_instructor_workload
--   Задача 8  Автомобілі, яким потрібне ТО ........... sp_vehicles_service_due
--   Задача 9  Історія оплат, боржники ................ sp_payment_history, v_debtors
--
-- Звіти, що залежать від дати, приймають її параметром (NULL = сьогодні),
-- щоб результат можна було відтворити для будь-якого дня.
--
-- Усі представлення створено з SQL SECURITY DEFINER явно (у MySQL це й так
-- значення за замовчуванням): запит виконується з правами власника, тому
-- ролі достатньо права SELECT на саме представлення, без доступу до таблиць.
-- =====================================================================

SET NAMES utf8mb4;
USE driving_school;

DROP FUNCTION IF EXISTS fn_theory_hours;
DROP FUNCTION IF EXISTS fn_practice_hours;
DROP FUNCTION IF EXISTS fn_paid_amount;
DROP FUNCTION IF EXISTS fn_has_valid_medical;
DROP VIEW IF EXISTS v_students;
DROP VIEW IF EXISTS v_enrollment_progress;
DROP VIEW IF EXISTS v_exam_admission;
DROP VIEW IF EXISTS v_exam_results_by_group;
DROP VIEW IF EXISTS v_debtors;
DROP PROCEDURE IF EXISTS sp_students_list;
DROP PROCEDURE IF EXISTS sp_instructor_schedule;
DROP PROCEDURE IF EXISTS sp_instructor_free_slots;
DROP PROCEDURE IF EXISTS sp_book_practice;
DROP PROCEDURE IF EXISTS sp_cancel_practice;
DROP PROCEDURE IF EXISTS sp_check_admission;
DROP PROCEDURE IF EXISTS sp_attendance_report;
DROP PROCEDURE IF EXISTS sp_absent_list;
DROP PROCEDURE IF EXISTS sp_medical_issues;
DROP PROCEDURE IF EXISTS sp_instructor_workload;
DROP PROCEDURE IF EXISTS sp_vehicles_service_due;
DROP PROCEDURE IF EXISTS sp_payment_history;
DROP PROCEDURE IF EXISTS sp_enroll_student;

DELIMITER $$

-- =====================================================================
-- ДОПОМІЖНІ ФУНКЦІЇ (використовуються у view та процедурах)
-- =====================================================================

-- Години теорії, які курсант фактично відвідав
CREATE FUNCTION fn_theory_hours(p_enrollment_id INT UNSIGNED)
RETURNS DECIMAL(6,1)
READS SQL DATA
BEGIN
    DECLARE v_hours DECIMAL(6,1);
    SELECT COALESCE(SUM(tl.duration_hours), 0) INTO v_hours
      FROM theory_attendance ta
      JOIN theory_lessons tl ON tl.lesson_id = ta.lesson_id
     WHERE ta.enrollment_id = p_enrollment_id
       AND ta.present = TRUE
       AND tl.status <> 'cancelled';
    RETURN v_hours;
END$$

-- Години проведеної практики (пропущені та скасовані не рахуються)
CREATE FUNCTION fn_practice_hours(p_enrollment_id INT UNSIGNED)
RETURNS DECIMAL(6,1)
READS SQL DATA
BEGIN
    DECLARE v_hours DECIMAL(6,1);
    SELECT COALESCE(SUM(duration_hours), 0) INTO v_hours
      FROM practice_lessons
     WHERE enrollment_id = p_enrollment_id AND status = 'done';
    RETURN v_hours;
END$$

-- Фактично сплачено: оплати мінус повернення
CREATE FUNCTION fn_paid_amount(p_enrollment_id INT UNSIGNED)
RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
    DECLARE v_sum DECIMAL(10,2);
    SELECT COALESCE(SUM(CASE WHEN kind = 'payment' THEN amount ELSE -amount END), 0)
      INTO v_sum
      FROM payments WHERE enrollment_id = p_enrollment_id;
    RETURN v_sum;
END$$

-- Чи має курсант чинну медичну довідку на дату
CREATE FUNCTION fn_has_valid_medical(p_student_id INT UNSIGNED, p_on_date DATE)
RETURNS BOOLEAN
READS SQL DATA
BEGIN
    RETURN EXISTS (
        SELECT 1
          FROM documents d
          JOIN document_types t ON t.document_type_id = d.document_type_id
         WHERE d.student_id = p_student_id
           AND t.code = 'medical'
           AND d.issue_date <= p_on_date
           AND (d.valid_until IS NULL OR d.valid_until >= p_on_date));
END$$

DELIMITER ;

-- =====================================================================
-- ЗАДАЧА 1. Список курсантів групи / категорії
-- =====================================================================
CREATE SQL SECURITY DEFINER VIEW v_students AS
SELECT e.enrollment_id,
       s.student_id,
       s.full_name           AS student,
       s.phone,
       s.email,
       c.code                AS category,
       g.group_id,
       g.name                AS group_name,
       g.shift,
       st.code               AS status_code,
       st.name               AS status,
       e.enrolled_on,
       e.agreed_price
  FROM enrollments e
  JOIN students s             ON s.student_id  = e.student_id
  JOIN study_groups g         ON g.group_id    = e.group_id
  JOIN categories c           ON c.category_id = g.category_id
  JOIN enrollment_statuses st ON st.status_id  = e.status_id;

-- Прогрес навчання кожного зарахування (основа для допуску та звітів)
CREATE SQL SECURITY DEFINER VIEW v_enrollment_progress AS
SELECT e.enrollment_id,
       e.student_id,
       s.full_name                                AS student,
       g.group_id,
       g.name                                     AS group_name,
       c.code                                     AS category,
       st.code                                    AS status_code,
       c.theory_hours_min,
       fn_theory_hours(e.enrollment_id)           AS theory_hours,
       c.practice_hours_min,
       fn_practice_hours(e.enrollment_id)         AS practice_hours,
       e.agreed_price,
       fn_paid_amount(e.enrollment_id)            AS paid,
       -- після відрахування курсант нічого не винен: розрахунок закрито поверненням
       IF(st.code = 'expelled', 0,
          e.agreed_price - fn_paid_amount(e.enrollment_id)) AS debt
  FROM enrollments e
  JOIN students s             ON s.student_id  = e.student_id
  JOIN study_groups g         ON g.group_id    = e.group_id
  JOIN categories c           ON c.category_id = g.category_id
  JOIN enrollment_statuses st ON st.status_id  = e.status_id;

DELIMITER $$

-- p_group_id та p_category_code необов'язкові (NULL = без фільтра)
CREATE PROCEDURE sp_students_list(
    IN p_group_id      INT UNSIGNED,
    IN p_category_code VARCHAR(5),
    IN p_only_active   BOOLEAN
)
READS SQL DATA
BEGIN
    SELECT student_id, group_name, category, student, phone, email, status, enrolled_on
      FROM v_students
     WHERE (p_group_id IS NULL OR group_id = p_group_id)
       AND (p_category_code IS NULL OR category = p_category_code)
       AND (NOT COALESCE(p_only_active, FALSE) OR status_code = 'studying')
     ORDER BY group_name, student;
END$$

-- =====================================================================
-- ЗАДАЧА 2. Розклад інструктора на тиждень; вільні слоти; запис на практику
-- =====================================================================
CREATE PROCEDURE sp_instructor_schedule(
    IN p_instructor_id INT UNSIGNED,
    IN p_week_date     DATE          -- будь-яка дата тижня; NULL = поточний тиждень
)
READS SQL DATA
BEGIN
    DECLARE v_monday DATE;
    SET v_monday = COALESCE(p_week_date, CURDATE());
    SET v_monday = v_monday - INTERVAL WEEKDAY(v_monday) DAY;

    SELECT pl.lesson_id,
           DATE(pl.starts_at)                     AS lesson_date,
           ELT(WEEKDAY(pl.starts_at) + 1, 'Пн','Вт','Ср','Чт','Пт','Сб','Нд') AS day_name,
           TIME_FORMAT(pl.starts_at, '%H:%i')     AS time_from,
           TIME_FORMAT(pl.ends_at,   '%H:%i')     AS time_to,
           s.full_name                            AS student,
           s.phone,
           CONCAT(v.make, ' ', v.model, ' (', v.plate_number, ')') AS vehicle,
           pl.status
      FROM practice_lessons pl
      JOIN enrollments e ON e.enrollment_id = pl.enrollment_id
      JOIN students s    ON s.student_id    = e.student_id
      JOIN vehicles v    ON v.vehicle_id    = pl.vehicle_id
     WHERE pl.instructor_id = p_instructor_id
       AND pl.starts_at >= v_monday
       AND pl.starts_at <  v_monday + INTERVAL 7 DAY
       AND pl.status <> 'cancelled'
     ORDER BY pl.starts_at;
END$$

-- Вільні 2-годинні слоти інструктора на день (07:00-21:00).
-- Слот вільний, якщо не перетинається з жодним активним заняттям інструктора
-- і після запису не буде перевищено денний ліміт 8 год (те саме правило, що в тригері).
CREATE PROCEDURE sp_instructor_free_slots(
    IN p_instructor_id INT UNSIGNED,
    IN p_date          DATE
)
READS SQL DATA
BEGIN
    DECLARE v_day_hours DECIMAL(5,1);
    SELECT COALESCE(SUM(duration_hours), 0) INTO v_day_hours
      FROM practice_lessons
     WHERE instructor_id = p_instructor_id AND status <> 'cancelled'
       AND starts_at >= p_date AND starts_at < p_date + INTERVAL 1 DAY;

    WITH RECURSIVE slots(slot_start) AS (
        SELECT TIMESTAMP(p_date, '07:00:00')
        UNION ALL
        SELECT slot_start + INTERVAL 1 HOUR FROM slots
         WHERE slot_start + INTERVAL 1 HOUR <= TIMESTAMP(p_date, '19:00:00')
    )
    SELECT TIME_FORMAT(sl.slot_start, '%H:%i')                    AS time_from,
           TIME_FORMAT(sl.slot_start + INTERVAL 2 HOUR, '%H:%i')  AS time_to
      FROM slots sl
     WHERE v_day_hours + 2 <= 8
       AND sl.slot_start > NOW()                 -- минулий час не пропонуємо
       AND NOT EXISTS (
            SELECT 1 FROM practice_lessons pl
             WHERE pl.instructor_id = p_instructor_id
               AND pl.status <> 'cancelled'
               AND pl.starts_at > sl.slot_start - INTERVAL 4 HOUR
               AND pl.starts_at < sl.slot_start + INTERVAL 2 HOUR
               AND pl.ends_at   > sl.slot_start)
     ORDER BY sl.slot_start;
END$$

-- Запис курсанта на практику.
-- Усі бізнес-правила перевіряє тригер; процедура перетворює помилку на
-- зрозумілий результат і повертає id створеного заняття.
-- Якщо авто не вказано, процедура підбирає його сама:
--   активне, тієї ж категорії, що й навчання курсанта, з чинним ТО
--   і вільне в цей час; спершу - закріплене за інструктором,
--   інакше - будь-яке інше вільне авто цієї категорії.
-- (Інструктор може мати авто різних категорій, напр. мотоцикл і легковик,
--  тому «перше закріплене» авто могло не підійти за категорією.)
CREATE PROCEDURE sp_book_practice(
    IN  p_enrollment_id INT UNSIGNED,
    IN  p_instructor_id INT UNSIGNED,
    IN  p_vehicle_id    INT UNSIGNED,
    IN  p_starts_at     DATETIME,
    IN  p_duration      DECIMAL(3,1),
    OUT p_lesson_id     INT UNSIGNED,
    OUT p_message       VARCHAR(255)
)
MODIFIES SQL DATA
BEGIN
    DECLARE v_vehicle_id INT UNSIGNED DEFAULT NULL;
    DECLARE v_category   TINYINT UNSIGNED DEFAULT NULL;
    DECLARE v_ends_at    DATETIME;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 p_message = MESSAGE_TEXT;
        ROLLBACK;
        SET p_lesson_id = NULL;
    END;

    -- Записати можна лише на майбутній час. (Тригер цього не забороняє
    -- навмисно: через нього вносяться й історичні дані про минулі заняття.)
    IF p_starts_at <= NOW() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Не можна записати на час, що вже минув';
    END IF;

    SET v_vehicle_id = p_vehicle_id;
    IF v_vehicle_id IS NULL THEN
        SELECT g.category_id INTO v_category
          FROM enrollments e
          JOIN study_groups g ON g.group_id = e.group_id
         WHERE e.enrollment_id = p_enrollment_id;
        IF v_category IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Зарахування не знайдено';
        END IF;

        SET v_ends_at = p_starts_at + INTERVAL ROUND(COALESCE(p_duration, 2.0) * 60) MINUTE;

        SELECT v.vehicle_id INTO v_vehicle_id
          FROM vehicles v
         WHERE v.is_active
           AND v.category_id = v_category
           AND v.next_service_date >= DATE(p_starts_at)
           AND NOT EXISTS (
                SELECT 1 FROM practice_lessons pl
                 WHERE pl.vehicle_id = v.vehicle_id
                   AND pl.status <> 'cancelled'
                   AND pl.starts_at > p_starts_at - INTERVAL 4 HOUR
                   AND pl.starts_at < v_ends_at AND pl.ends_at > p_starts_at)
         ORDER BY (v.default_instructor_id <=> p_instructor_id) DESC,  -- спершу авто інструктора
                  v.vehicle_id
         LIMIT 1;

        IF v_vehicle_id IS NULL THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Немає вільного автомобіля потрібної категорії на цей час';
        END IF;
    END IF;

    START TRANSACTION;
    INSERT INTO practice_lessons (enrollment_id, instructor_id, vehicle_id, starts_at, duration_hours)
    VALUES (p_enrollment_id, p_instructor_id, v_vehicle_id, p_starts_at, COALESCE(p_duration, 2.0));
    SET p_lesson_id = LAST_INSERT_ID();
    COMMIT;
    SET p_message = 'Заняття заплановано';
END$$

-- Скасування запланованого практичного заняття.
-- Заняття НЕ видаляється: статус 'cancelled' зберігає історію (хто й коли
-- скасував - у журналі аудиту), а тригери не враховують скасовані заняття,
-- тож час інструктора, авто й курсанта звільняється.
-- Минуле заняття скасувати не можна: його відмічають як проведене або пропущене.
CREATE PROCEDURE sp_cancel_practice(IN p_lesson_id INT UNSIGNED)
MODIFIES SQL DATA
BEGIN
    DECLARE v_status    VARCHAR(10) DEFAULT NULL;
    DECLARE v_starts_at DATETIME    DEFAULT NULL;

    SELECT status, starts_at INTO v_status, v_starts_at
      FROM practice_lessons WHERE lesson_id = p_lesson_id
       FOR UPDATE;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Заняття не знайдено';
    END IF;
    IF v_status <> 'planned' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Скасувати можна лише заплановане заняття';
    END IF;
    IF v_starts_at <= NOW() THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Заняття вже почалося або минуло: відмітьте його як проведене або пропущене';
    END IF;

    UPDATE practice_lessons SET status = 'cancelled' WHERE lesson_id = p_lesson_id;
END$$

DELIMITER ;

-- =====================================================================
-- ЗАДАЧА 3. Допуск до іспиту
--   Умови: години теорії >= мінімуму категорії, години практики >= мінімуму,
--          курс сплачено повністю, чинна меддовідка на сьогодні,
--          статус 'studying'.
--   Причини відмови перелічуються, щоб менеджер бачив, ЩО саме не виконано.
-- =====================================================================
CREATE SQL SECURITY DEFINER VIEW v_exam_admission AS
SELECT p.enrollment_id,
       p.student,
       p.group_name,
       p.category,
       p.status_code,
       p.theory_hours,  p.theory_hours_min,
       p.practice_hours, p.practice_hours_min,
       p.debt,
       fn_has_valid_medical(p.student_id, CURDATE()) AS has_medical,
       (p.status_code = 'studying'
        AND p.theory_hours   >= p.theory_hours_min
        AND p.practice_hours >= p.practice_hours_min
        AND p.debt <= 0
        AND fn_has_valid_medical(p.student_id, CURDATE()))  AS admitted,
       NULLIF(CONCAT_WS('; ',
           IF(p.status_code <> 'studying', 'статус не «навчається»', NULL),
           IF(p.theory_hours < p.theory_hours_min,
              CONCAT('теорія ', p.theory_hours, ' з ', p.theory_hours_min, ' год'), NULL),
           IF(p.practice_hours < p.practice_hours_min,
              CONCAT('практика ', p.practice_hours, ' з ', p.practice_hours_min, ' год'), NULL),
           IF(p.debt > 0, CONCAT('борг ', p.debt, ' грн'), NULL),
           IF(NOT fn_has_valid_medical(p.student_id, CURDATE()), 'немає чинної меддовідки', NULL)
       ), '') AS reasons
  FROM v_enrollment_progress p;

DELIMITER $$

CREATE PROCEDURE sp_check_admission(IN p_enrollment_id INT UNSIGNED)
READS SQL DATA
BEGIN
    IF NOT EXISTS (SELECT 1 FROM enrollments WHERE enrollment_id = p_enrollment_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Зарахування не знайдено';
    END IF;
    SELECT student, group_name,
           CONCAT(theory_hours, ' / ', theory_hours_min)     AS theory,
           CONCAT(practice_hours, ' / ', practice_hours_min) AS practice,
           debt, has_medical,
           IF(admitted, 'ДОПУЩЕНО', 'НЕ ДОПУЩЕНО')            AS decision,
           reasons
      FROM v_exam_admission
     WHERE enrollment_id = p_enrollment_id;
END$$

-- =====================================================================
-- ЗАДАЧА 4. Відвідуваність теорії за період
-- =====================================================================
-- Зведення по курсантах групи (або одного курсанта, якщо p_enrollment_id задано)
CREATE PROCEDURE sp_attendance_report(
    IN p_group_id      INT UNSIGNED,
    IN p_enrollment_id INT UNSIGNED,   -- NULL = вся група
    IN p_date_from     DATE,
    IN p_date_to       DATE
)
READS SQL DATA
BEGIN
    SELECT s.full_name                                         AS student,
           COUNT(ta.lesson_id)                                 AS lessons_marked,
           SUM(ta.present)                                     AS attended,
           SUM(NOT ta.present)                                 AS missed,
           -- для присутніх absence_reason = NULL, а SUM з одних NULL дає NULL, тому COALESCE
           COALESCE(SUM(ta.absence_reason = 'illness'), 0)     AS missed_illness,
           COALESCE(SUM(ta.absence_reason = 'excused'), 0)     AS missed_excused,
           COALESCE(SUM(ta.absence_reason = 'unexcused'), 0)   AS missed_unexcused,
           ROUND(100 * SUM(ta.present) / NULLIF(COUNT(ta.lesson_id), 0), 1) AS attendance_pct
      FROM enrollments e
      JOIN students s           ON s.student_id = e.student_id
      LEFT JOIN theory_attendance ta ON ta.enrollment_id = e.enrollment_id
      LEFT JOIN theory_lessons tl    ON tl.lesson_id     = ta.lesson_id
     WHERE e.group_id = p_group_id
       AND (p_enrollment_id IS NULL OR e.enrollment_id = p_enrollment_id)
       AND (tl.lesson_id IS NULL OR (DATE(tl.starts_at) BETWEEN p_date_from AND p_date_to
                                     AND tl.status <> 'cancelled'))
     GROUP BY e.enrollment_id, s.full_name
     ORDER BY attendance_pct, s.full_name;
END$$

-- «Хто не відвідав»: перелік пропусків із датою, темою та причиною
CREATE PROCEDURE sp_absent_list(
    IN p_group_id  INT UNSIGNED,
    IN p_date_from DATE,
    IN p_date_to   DATE
)
READS SQL DATA
BEGIN
    SELECT DATE_FORMAT(tl.starts_at, '%d.%m.%Y %H:%i') AS lesson_time,
           tl.topic,
           s.full_name                                 AS student,
           CASE ta.absence_reason
               WHEN 'illness'   THEN 'хвороба'
               WHEN 'excused'   THEN 'поважна причина'
               WHEN 'unexcused' THEN 'без поважної причини'
           END                                         AS reason
      FROM theory_attendance ta
      JOIN theory_lessons tl ON tl.lesson_id     = ta.lesson_id
      JOIN enrollments e     ON e.enrollment_id  = ta.enrollment_id
      JOIN students s        ON s.student_id     = e.student_id
     WHERE tl.group_id = p_group_id
       AND ta.present = FALSE
       AND tl.status <> 'cancelled'
       AND DATE(tl.starts_at) BETWEEN p_date_from AND p_date_to
     ORDER BY tl.starts_at, s.full_name;
END$$

-- =====================================================================
-- ЗАДАЧА 5. Меддовідки: курсанти без чинної довідки або з довідкою,
--           що спливає протягом p_days днів (лише ті, хто навчається)
-- =====================================================================
CREATE PROCEDURE sp_medical_issues(
    IN p_on_date DATE,       -- NULL = сьогодні
    IN p_days    INT         -- горизонт попередження, напр. 30
)
READS SQL DATA
BEGIN
    DECLARE v_date DATE DEFAULT COALESCE(p_on_date, CURDATE());

    SELECT s.full_name                         AS student,
           s.phone,
           GROUP_CONCAT(DISTINCT g.name ORDER BY g.name SEPARATOR ', ') AS `groups`,
           md.valid_until                      AS medical_valid_until,
           CASE
               WHEN md.valid_until IS NULL AND md.student_id IS NULL THEN 'довідки немає'
               WHEN md.valid_until < v_date                         THEN 'довідка прострочена'
               ELSE CONCAT('спливає через ', DATEDIFF(md.valid_until, v_date), ' дн.')
           END                                 AS problem
      FROM students s
      JOIN enrollments e          ON e.student_id = s.student_id
      JOIN enrollment_statuses st ON st.status_id = e.status_id AND st.code = 'studying'
      JOIN study_groups g         ON g.group_id   = e.group_id
      -- остання (найпізніше чинна) медична довідка курсанта
      LEFT JOIN (
            SELECT d.student_id, MAX(COALESCE(d.valid_until, '9999-12-31')) AS valid_until
              FROM documents d
              JOIN document_types t ON t.document_type_id = d.document_type_id
             WHERE t.code = 'medical'
             GROUP BY d.student_id
      ) md ON md.student_id = s.student_id
     WHERE md.student_id IS NULL
        OR md.valid_until < v_date + INTERVAL COALESCE(p_days, 30) DAY
     GROUP BY s.student_id, s.full_name, s.phone, md.student_id, md.valid_until
     ORDER BY md.valid_until IS NOT NULL, md.valid_until, s.full_name;
END$$

DELIMITER ;

-- =====================================================================
-- ЗАДАЧА 6. Успішність по групах
--   - скільки курсантів складали кожен тип іспиту
--   - скільки склали, скільки з першої спроби (%), середній бал теорії
-- =====================================================================
CREATE SQL SECURITY DEFINER VIEW v_exam_results_by_group AS
WITH per_student AS (
    SELECT e.group_id, x.enrollment_id, x.exam_type_id,
           MAX(x.passed)                                 AS passed_any,
           MAX(x.attempt_no = 1 AND x.passed)            AS passed_first,
           COUNT(*)                                      AS attempts,
           MAX(CASE WHEN x.attempt_no = 1 THEN x.score END) AS first_score
      FROM exams x
      JOIN enrollments e ON e.enrollment_id = x.enrollment_id
     GROUP BY e.group_id, x.enrollment_id, x.exam_type_id
)
SELECT g.name                                           AS group_name,
       t.name                                           AS exam_type,
       COUNT(*)                                         AS students_examined,
       SUM(ps.passed_any)                               AS passed,
       SUM(ps.passed_first)                             AS passed_first_attempt,
       ROUND(100 * SUM(ps.passed_first) / COUNT(*), 1)  AS first_attempt_pct,
       ROUND(AVG(ps.attempts), 2)                       AS avg_attempts,
       ROUND(AVG(ps.first_score), 1)                    AS avg_first_score
  FROM per_student ps
  JOIN study_groups g ON g.group_id     = ps.group_id
  JOIN exam_types t   ON t.exam_type_id = ps.exam_type_id
 GROUP BY g.group_id, g.name, t.exam_type_id, t.name;

DELIMITER $$

-- =====================================================================
-- ЗАДАЧА 7. Завантаженість інструкторів за місяць
-- =====================================================================
CREATE PROCEDURE sp_instructor_workload(
    IN p_year  SMALLINT,
    IN p_month TINYINT
)
READS SQL DATA
BEGIN
    DECLARE v_from DATE;
    SET v_from = MAKEDATE(p_year, 1) + INTERVAL (p_month - 1) MONTH;

    SELECT em.full_name                                             AS instructor,
           IF(em.is_active, 'працює', 'звільнений')                  AS state,
           COALESCE(SUM(CASE WHEN pl.status = 'done'    THEN pl.duration_hours END), 0) AS hours_done,
           COALESCE(SUM(CASE WHEN pl.status = 'planned' THEN pl.duration_hours END), 0) AS hours_planned,
           COUNT(CASE WHEN pl.status = 'missed' THEN 1 END)          AS lessons_missed_by_students,
           COUNT(DISTINCT pl.enrollment_id)                         AS students,
           COUNT(DISTINCT DATE(pl.starts_at))                       AS working_days,
           ROUND(COALESCE(SUM(CASE WHEN pl.status IN ('done','planned') THEN pl.duration_hours END), 0)
                 / NULLIF(COUNT(DISTINCT DATE(pl.starts_at)), 0), 1) AS avg_hours_per_day
      FROM employees em
      LEFT JOIN practice_lessons pl
             ON pl.instructor_id = em.employee_id
            AND pl.status <> 'cancelled'
            AND pl.starts_at >= v_from
            AND pl.starts_at <  v_from + INTERVAL 1 MONTH
     WHERE em.role = 'instructor'
       -- звільнені інструктори показуються лише за місяці, коли вони працювали
       AND (em.is_active
            OR EXISTS (SELECT 1 FROM practice_lessons p2
                        WHERE p2.instructor_id = em.employee_id
                          AND p2.status <> 'cancelled'
                          AND p2.starts_at >= v_from
                          AND p2.starts_at <  v_from + INTERVAL 1 MONTH))
     GROUP BY em.employee_id, em.full_name, em.is_active
     ORDER BY hours_done + hours_planned DESC;
END$$

-- =====================================================================
-- ЗАДАЧА 8. Автомобілі, яким потрібне ТО протягом p_days днів
-- =====================================================================
CREATE PROCEDURE sp_vehicles_service_due(
    IN p_days    INT,
    IN p_on_date DATE        -- NULL = сьогодні
)
READS SQL DATA
BEGIN
    DECLARE v_date DATE DEFAULT COALESCE(p_on_date, CURDATE());

    SELECT v.plate_number,
           CONCAT(v.make, ' ', v.model)          AS vehicle,
           c.code                                AS category,
           em.full_name                          AS default_instructor,
           v.next_service_date,
           DATEDIFF(v.next_service_date, v_date) AS days_left,
           IF(v.next_service_date < v_date, 'ПРОСТРОЧЕНО', 'скоро')  AS state,
           -- заплановані заняття, які доведеться перенести (після дати ТО)
           (SELECT COUNT(*) FROM practice_lessons pl
             WHERE pl.vehicle_id = v.vehicle_id AND pl.status = 'planned'
               AND DATE(pl.starts_at) > v.next_service_date) AS lessons_to_reschedule
      FROM vehicles v
      JOIN categories c      ON c.category_id = v.category_id
      LEFT JOIN employees em ON em.employee_id = v.default_instructor_id
     WHERE v.is_active
       AND v.next_service_date <= v_date + INTERVAL p_days DAY
     ORDER BY v.next_service_date;
END$$

-- =====================================================================
-- ЗАДАЧА 9. Історія оплат курсанта; список боржників
-- =====================================================================
CREATE PROCEDURE sp_payment_history(IN p_student_id INT UNSIGNED)
READS SQL DATA
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Курсанта не знайдено';
    END IF;

    -- 1) операції з наростаючим балансом (віконна функція)
    SELECT g.name                                         AS group_name,
           DATE_FORMAT(p.paid_at, '%d.%m.%Y %H:%i')       AS paid_at,
           IF(p.kind = 'payment', 'оплата', 'повернення') AS operation,
           IF(p.kind = 'payment', p.amount, -p.amount)    AS amount,
           m.name                                         AS method,
           SUM(IF(p.kind = 'payment', p.amount, -p.amount))
               OVER (PARTITION BY p.enrollment_id ORDER BY p.paid_at, p.payment_id) AS balance,
           p.note
      FROM payments p
      JOIN enrollments e      ON e.enrollment_id = p.enrollment_id
      JOIN study_groups g     ON g.group_id      = e.group_id
      JOIN payment_methods m  ON m.method_id     = p.method_id
     WHERE e.student_id = p_student_id
     ORDER BY e.enrollment_id, p.paid_at, p.payment_id;

    -- 2) підсумок по кожному зарахуванню
    SELECT group_name, category, agreed_price, paid, debt
      FROM v_enrollment_progress
     WHERE student_id = p_student_id;
END$$

DELIMITER ;

-- Боржники: лише активні (навчаються або в академвідпустці), борг > 0
CREATE SQL SECURITY DEFINER VIEW v_debtors AS
SELECT p.student,
       s.phone,
       p.group_name,
       p.agreed_price,
       p.paid,
       p.debt,
       ROUND(100 * p.paid / NULLIF(p.agreed_price, 0), 0) AS paid_pct,   -- ціна 0 -> NULL, а не ділення на 0
       (SELECT MAX(pm.paid_at) FROM payments pm
         WHERE pm.enrollment_id = p.enrollment_id AND pm.kind = 'payment') AS last_payment
  FROM v_enrollment_progress p
  JOIN students s ON s.student_id = p.student_id
 WHERE p.status_code IN ('studying', 'leave')
   AND p.debt > 0;

-- =====================================================================
-- ТРАНЗАКЦІЯ: зарахування нового курсанта разом із першим платежем.
-- Або зберігаються ОБИДВА записи, або жоден (атомарність).
-- Напр., якщо в групі немає місць або сума перевищує ціну - відкат усього.
-- =====================================================================
DELIMITER $$
CREATE PROCEDURE sp_enroll_student(
    IN  p_student_id    INT UNSIGNED,
    IN  p_group_id      INT UNSIGNED,
    IN  p_price         DECIMAL(10,2),   -- NULL = ціна категорії
    IN  p_discount_note VARCHAR(100),
    IN  p_first_payment DECIMAL(10,2),   -- NULL або 0 = без оплати
    IN  p_method_id     TINYINT UNSIGNED,
    OUT p_enrollment_id INT UNSIGNED,
    OUT p_message       VARCHAR(255)
)
MODIFIES SQL DATA
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 p_message = MESSAGE_TEXT;
        ROLLBACK;
        SET p_enrollment_id = NULL;
    END;

    IF COALESCE(p_first_payment, 0) > 0 AND p_method_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Для першого платежу вкажіть спосіб оплати';
    END IF;

    START TRANSACTION;
    INSERT INTO enrollments (student_id, group_id, enrolled_on, agreed_price, discount_note)
    VALUES (p_student_id, p_group_id, CURDATE(), p_price, p_discount_note);
    SET p_enrollment_id = LAST_INSERT_ID();

    IF COALESCE(p_first_payment, 0) > 0 THEN
        INSERT INTO payments (enrollment_id, kind, amount, method_id, note)
        VALUES (p_enrollment_id, 'payment', p_first_payment, p_method_id, 'Перший внесок при зарахуванні');
    END IF;
    COMMIT;
    SET p_message = 'Курсанта зараховано';
END$$
DELIMITER ;

-- =====================================================================
-- ЖИТТЄВИЙ ЦИКЛ НАВЧАННЯ: іспити, статуси, розклад теорії, автомобілі
-- =====================================================================
DROP PROCEDURE IF EXISTS sp_record_exam;
DROP PROCEDURE IF EXISTS sp_change_enrollment_status;
DROP PROCEDURE IF EXISTS sp_cancel_theory;
DROP PROCEDURE IF EXISTS sp_vehicle_service_done;

DELIMITER $$

-- ---------------------------------------------------------------------
-- Внесення результату іспиту з перевіркою допуску.
--   Внутрішні іспити (теорія, практика): курсант має бути допущений
--   (v_exam_admission: години, оплата, меддовідка).
--   Підсумковий: лише після складання ОБОХ внутрішніх іспитів.
--   Номер спроби й результат бального іспиту обчислює тригер trg_exams_bi.
--   Складений підсумковий іспит -> статус зарахування 'graduated'
--   (у тій самій транзакції: або обидві зміни, або жодна).
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_record_exam(
    IN  p_enrollment_id INT UNSIGNED,
    IN  p_exam_code     VARCHAR(20),       -- internal_theory / internal_practice / final
    IN  p_exam_date     DATE,
    IN  p_score         TINYINT UNSIGNED,  -- для бального іспиту, інакше NULL
    IN  p_passed        BOOLEAN,           -- для заліку, інакше NULL
    OUT p_exam_id       INT UNSIGNED,
    OUT p_message       VARCHAR(255)
)
MODIFIES SQL DATA
BEGIN
    DECLARE v_status   VARCHAR(20)  DEFAULT NULL;
    DECLARE v_type_id  TINYINT UNSIGNED DEFAULT NULL;
    DECLARE v_admitted BOOLEAN      DEFAULT FALSE;
    DECLARE v_reasons  VARCHAR(255) DEFAULT NULL;
    DECLARE v_passed   BOOLEAN      DEFAULT FALSE;
    DECLARE v_attempt  TINYINT UNSIGNED;
    DECLARE v_msg      VARCHAR(255);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 p_message = MESSAGE_TEXT;
        ROLLBACK;
        SET p_exam_id = NULL;
    END;

    SELECT s.code INTO v_status
      FROM enrollments e JOIN enrollment_statuses s ON s.status_id = e.status_id
     WHERE e.enrollment_id = p_enrollment_id;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Зарахування не знайдено';
    END IF;
    IF v_status <> 'studying' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Іспит складають лише курсанти зі статусом «навчається»';
    END IF;

    SELECT exam_type_id INTO v_type_id FROM exam_types WHERE code = p_exam_code;
    IF v_type_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Тип іспиту не знайдено';
    END IF;
    IF p_exam_date IS NULL OR p_exam_date > CURDATE() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Дата іспиту не може бути в майбутньому';
    END IF;

    IF p_exam_code IN ('internal_theory', 'internal_practice') THEN
        SELECT admitted, reasons INTO v_admitted, v_reasons
          FROM v_exam_admission WHERE enrollment_id = p_enrollment_id;
        IF NOT v_admitted THEN
            SET v_msg = CONCAT('Курсант не допущений до іспиту: ', COALESCE(v_reasons, ''));
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;
    ELSE
        IF NOT EXISTS (SELECT 1 FROM exams x JOIN exam_types t ON t.exam_type_id = x.exam_type_id
                        WHERE x.enrollment_id = p_enrollment_id AND t.code = 'internal_theory' AND x.passed)
        OR NOT EXISTS (SELECT 1 FROM exams x JOIN exam_types t ON t.exam_type_id = x.exam_type_id
                        WHERE x.enrollment_id = p_enrollment_id AND t.code = 'internal_practice' AND x.passed) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'До підсумкового іспиту допускаються лише ті, хто склав внутрішні іспити з теорії та практики';
        END IF;
        -- підсумковий іспит - не раніше, ніж складено обидва внутрішні
        IF p_exam_date < (SELECT MAX(x.exam_date) FROM exams x JOIN exam_types t ON t.exam_type_id = x.exam_type_id
                           WHERE x.enrollment_id = p_enrollment_id AND x.passed
                             AND t.code IN ('internal_theory', 'internal_practice')) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Дата підсумкового іспиту не може бути раніше складання внутрішніх іспитів';
        END IF;
    END IF;

    START TRANSACTION;
    INSERT INTO exams (enrollment_id, exam_type_id, exam_date, score, passed)
    VALUES (p_enrollment_id, v_type_id, p_exam_date, p_score, p_passed);
    SET p_exam_id = LAST_INSERT_ID();
    SELECT passed, attempt_no INTO v_passed, v_attempt FROM exams WHERE exam_id = p_exam_id;

    IF p_exam_code = 'final' AND v_passed THEN
        UPDATE enrollments
           SET status_id = (SELECT status_id FROM enrollment_statuses WHERE code = 'graduated')
         WHERE enrollment_id = p_enrollment_id;
    END IF;
    COMMIT;

    SET p_message = CASE
        WHEN p_exam_code = 'final' AND v_passed THEN 'Підсумковий іспит складено. Навчання завершено (статус «закінчив»)'
        WHEN v_passed THEN CONCAT('Іспит складено (спроба ', v_attempt, ')')
        ELSE CONCAT('Іспит не складено (спроба ', v_attempt, '). Можна призначити повторну спробу')
    END;
END$$

-- ---------------------------------------------------------------------
-- Зміна статусу навчання. Дозволені переходи:
--   навчається     -> академвідпустка | відрахований
--   академвідпустка -> навчається      | відрахований
-- «Закінчив» встановлюється лише складанням підсумкового іспиту;
-- «закінчив» і «відрахований» - остаточні.
-- При академвідпустці й відрахуванні майбутні заплановані практичні
-- заняття курсанта скасовуються (інакше інструктор чекатиме даремно).
-- Повернення з академвідпустки перевіряє місткість групи (тригер).
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_change_enrollment_status(
    IN  p_enrollment_id INT UNSIGNED,
    IN  p_new_code      VARCHAR(20),
    OUT p_message       VARCHAR(255)
)
MODIFIES SQL DATA
BEGIN
    DECLARE v_old       VARCHAR(20) DEFAULT NULL;
    DECLARE v_cancelled INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 p_message = MESSAGE_TEXT;
        ROLLBACK;
    END;

    SELECT s.code INTO v_old
      FROM enrollments e JOIN enrollment_statuses s ON s.status_id = e.status_id
     WHERE e.enrollment_id = p_enrollment_id;
    IF v_old IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Зарахування не знайдено';
    END IF;
    IF NOT ((v_old = 'studying' AND p_new_code IN ('leave', 'expelled'))
         OR (v_old = 'leave'    AND p_new_code IN ('studying', 'expelled'))) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Такий перехід статусу не дозволено';
    END IF;

    START TRANSACTION;
    IF p_new_code IN ('leave', 'expelled') THEN
        UPDATE practice_lessons SET status = 'cancelled'
         WHERE enrollment_id = p_enrollment_id AND status = 'planned' AND starts_at > NOW();
        SET v_cancelled = ROW_COUNT();
    END IF;
    UPDATE enrollments
       SET status_id = (SELECT status_id FROM enrollment_statuses WHERE code = p_new_code)
     WHERE enrollment_id = p_enrollment_id;
    COMMIT;

    SET p_message = CONCAT(
        CASE p_new_code WHEN 'leave' THEN 'Курсанта переведено в академвідпустку'
                        WHEN 'expelled' THEN 'Курсанта відраховано'
                        ELSE 'Курсанта повернуто до навчання' END,
        IF(v_cancelled > 0, CONCAT('; скасовано запланованих практичних занять: ', v_cancelled), ''));
END$$

-- Скасування запланованого теоретичного заняття (лише майбутнього)
CREATE PROCEDURE sp_cancel_theory(IN p_lesson_id INT UNSIGNED)
MODIFIES SQL DATA
BEGIN
    DECLARE v_status    VARCHAR(10) DEFAULT NULL;
    DECLARE v_starts_at DATETIME    DEFAULT NULL;
    SELECT status, starts_at INTO v_status, v_starts_at
      FROM theory_lessons WHERE lesson_id = p_lesson_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Заняття не знайдено';
    END IF;
    IF v_status <> 'planned' OR v_starts_at <= NOW() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Скасувати можна лише заплановане заняття, яке ще не почалося';
    END IF;
    UPDATE theory_lessons SET status = 'cancelled' WHERE lesson_id = p_lesson_id;
END$$

-- Відмітка «ТО пройдено»: нова дата наступного ТО (в межах 2 років)
CREATE PROCEDURE sp_vehicle_service_done(IN p_vehicle_id INT UNSIGNED, IN p_next_date DATE)
MODIFIES SQL DATA
BEGIN
    DECLARE v_active BOOLEAN DEFAULT NULL;
    SELECT is_active INTO v_active FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF v_active IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Автомобіль не знайдено';
    END IF;
    IF NOT v_active THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Автомобіль списано';
    END IF;
    IF p_next_date IS NULL OR p_next_date <= CURDATE() OR p_next_date > CURDATE() + INTERVAL 2 YEAR THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Дата наступного ТО має бути в майбутньому, але не далі ніж через 2 роки';
    END IF;
    UPDATE vehicles SET next_service_date = p_next_date WHERE vehicle_id = p_vehicle_id;
END$$

DELIMITER ;
