-- =====================================================================
-- Файл 99: тестові сценарії тригерів (для розділу «Тестування»)
-- Запуск на ЧИСТІЙ базі (після 01, 02, 03 - БЕЗ сиду):
--     mysql --force -u root < 99_tests_triggers.sql
-- --force дозволяє продовжити після очікуваних помилок.
-- Кожен тест друкує свою назву; рядок ERROR після назви = очікувана відмова.
-- =====================================================================

-- Кодування з'єднання: без цього клієнт може працювати в latin1,
-- і кирилиця збережеться подвійно закодованою («кракозябри» в інших клієнтах)
SET NAMES utf8mb4;
USE driving_school;

-- ---------- Мінімальні дані ----------
-- Статуси навмисно вставлено НЕ в «природному» порядку:
-- 'studying' отримає status_id = 3, а логіка все одно працює (пошук за кодом).
INSERT INTO enrollment_statuses(code, name, is_system) VALUES
 ('expelled','Відрахований',TRUE), ('leave','Академвідпустка',TRUE),
 ('studying','Навчається',TRUE),   ('graduated','Закінчив',TRUE);
INSERT INTO document_types(code, name) VALUES ('passport','Паспорт'), ('medical','Медична довідка');
INSERT INTO payment_methods(name) VALUES ('Готівка'), ('Картка');
INSERT INTO categories(code,name,price,theory_hours_min,practice_hours_min) VALUES
 ('B','Легкові автомобілі',12000,60,40), ('A','Мотоцикли',8000,40,20);
INSERT INTO employees(full_name,phone,role,hire_date,experience_years) VALUES
 ('Інструктор 1 (B)','+380000000001','instructor','2020-01-01',5),
 ('Інструктор 2 (B)','+380000000002','instructor','2020-01-01',5),
 ('Викладач 1 (B)',  '+380000000003','teacher',   '2020-01-01',5),
 ('Інструктор 3 (A)','+380000000004','instructor','2020-01-01',5),
 ('Викладач 2 (B)',  '+380000000005','teacher',   '2020-01-01',5);
INSERT INTO employee_categories VALUES
 (1,1,'2019-01-01',NULL),(2,1,'2019-01-01',NULL),(3,1,'2019-01-01',NULL),
 (4,2,'2019-01-01',NULL),(5,1,'2019-01-01',NULL);
INSERT INTO vehicles(plate_number,make,model,production_year,category_id,default_instructor_id,next_service_date) VALUES
 ('AA0001AA','Skoda','Fabia',2020,1,1,'2027-12-01'),
 ('AA0002AA','Skoda','Fabia',2020,1,2,'2027-12-01'),
 ('AA0003AA','Honda','CB500',2020,2,4,'2027-12-01'),
 ('AA0004AA','VW','Polo',2019,1,2,'2026-11-10');
INSERT INTO study_groups(name,category_id,start_date,end_date,shift,max_students) VALUES
 ('B-1',1,'2026-10-01','2027-01-31','evening',4),
 ('B-2',1,'2026-10-01','2027-01-31','morning',2);
INSERT INTO students(full_name,birth_date,phone,registered_at) VALUES
 ('Курсант 1','2000-01-01','+380500000001','2026-09-20'),
 ('Курсант 2','2000-01-01','+380500000002','2026-09-20'),
 ('Курсант 3','2000-01-01','+380500000003','2026-09-20'),
 ('Курсант 4 (без довідки)','2000-01-01','+380500000004','2026-09-20'),
 ('Курсант 5 (довідка прострочена)','2000-01-01','+380500000005','2026-09-20'),
 ('Курсант 6','2000-01-01','+380500000006','2026-09-20'),
 ('Курсант 7','2000-01-01','+380500000007','2026-09-20');
INSERT INTO documents(student_id,document_type_id,number,issue_date,valid_until) VALUES
 (1,2,'MED-1','2026-09-01','2028-09-01'),(2,2,'MED-2','2026-09-01','2028-09-01'),
 (3,2,'MED-3','2026-09-01','2028-09-01'),(5,2,'MED-5','2024-01-01','2026-11-15'),
 (6,2,'MED-6','2026-09-01','2028-09-01'),(7,2,'MED-7','2026-09-01','2028-09-01');

-- ---------- 1. Статус і ціна за замовчуванням ----------
SELECT 'T01 Зарахування без status_id та agreed_price -> studying, ціна з категорії' AS test;
-- id задаються явно: невдалі INSERT «з'їдають» значення AUTO_INCREMENT
INSERT INTO enrollments(enrollment_id,student_id,group_id,enrolled_on) VALUES (1,1,1,'2026-10-01');
SELECT e.enrollment_id, s.code, e.agreed_price FROM enrollments e
  JOIN enrollment_statuses s USING(status_id) WHERE e.enrollment_id = 1;

INSERT INTO enrollments(enrollment_id,student_id,group_id,enrolled_on,agreed_price,discount_note)
VALUES (2,2,1,'2026-10-01',11000,'Знижка студентам');
INSERT INTO enrollments(enrollment_id,student_id,group_id,enrolled_on) VALUES
 (3,3,1,'2026-10-01'),(4,5,1,'2026-10-01');

SELECT 'T02 Видалення системного статусу -> відмова' AS test;
DELETE FROM enrollment_statuses WHERE code = 'studying';

SELECT 'T03 Зміна коду системного статусу -> відмова' AS test;
UPDATE enrollment_statuses SET code = 'learning' WHERE code = 'studying';

-- ---------- 2. Місткість групи ----------
SELECT 'T04 П''ятий курсант у групу з max_students = 4 -> відмова' AS test;
INSERT INTO enrollments(enrollment_id,student_id,group_id,enrolled_on) VALUES (5,6,1,'2026-10-02');

SELECT 'T05 Відрахування звільняє місце -> зарахування проходить' AS test;
UPDATE enrollments SET status_id = (SELECT status_id FROM enrollment_statuses WHERE code='expelled')
 WHERE enrollment_id = 3;
INSERT INTO enrollments(enrollment_id,student_id,group_id,enrolled_on) VALUES (5,6,1,'2026-10-02');
SELECT 'OK' AS result;

SELECT 'T06 Повернення відрахованого, коли місць немає -> відмова' AS test;
UPDATE enrollments SET status_id = (SELECT status_id FROM enrollment_statuses WHERE code='studying')
 WHERE enrollment_id = 3;

-- ---------- 3. Оплати та повернення ----------
SELECT 'T07 Оплата частинами -> OK' AS test;
INSERT INTO payments(enrollment_id,kind,amount,method_id) VALUES (1,'payment',5000,1),(1,'payment',4000,2);
SELECT 'OK' AS result;

SELECT 'T08 Переплата понад зафіксовану ціну -> відмова' AS test;
INSERT INTO payments(enrollment_id,kind,amount,method_id) VALUES (1,'payment',3500,1);

SELECT 'T09 Повернення більше, ніж сплачено -> відмова' AS test;
INSERT INTO payments(enrollment_id,kind,amount,method_id,note) VALUES (1,'refund',9500,1,'Відрахування');

SELECT 'T10 Часткове повернення -> OK, баланс зменшився' AS test;
INSERT INTO payments(enrollment_id,kind,amount,method_id,note) VALUES (1,'refund',2000,1,'Відрахування');
SELECT SUM(CASE WHEN kind='payment' THEN amount ELSE -amount END) AS balance FROM payments WHERE enrollment_id = 1;

SELECT 'T11 Від''ємна сума -> відмова (CHECK)' AS test;
INSERT INTO payments(enrollment_id,kind,amount,method_id) VALUES (1,'payment',-100,1);

-- ---------- 4. Теоретичні заняття ----------
INSERT INTO enrollments(enrollment_id,student_id,group_id,enrolled_on) VALUES
 (6,7,2,'2026-10-01'),(7,4,2,'2026-10-01');
SELECT 'T12 Теорія (минуле заняття) -> OK' AS test;
INSERT INTO theory_lessons(lesson_id,group_id,teacher_id,starts_at,duration_hours,topic) VALUES
 (1,1,3,'2026-10-20 18:00',2,'Загальні положення ПДР'),
 (2,1,3,'2026-11-20 18:00',2,'Дорожні знаки');
SELECT 'OK' AS result;

SELECT 'T13 Викладач веде дві групи одночасно -> відмова' AS test;
INSERT INTO theory_lessons(group_id,teacher_id,starts_at,duration_hours,topic) VALUES (2,3,'2026-11-20 19:00',2,'Розмітка');

SELECT 'T14 Група має два заняття одночасно -> відмова' AS test;
INSERT INTO theory_lessons(group_id,teacher_id,starts_at,duration_hours,topic) VALUES (1,5,'2026-11-20 19:00',1,'Розмітка');

SELECT 'T15 Інструктор замість викладача -> відмова' AS test;
INSERT INTO theory_lessons(group_id,teacher_id,starts_at,duration_hours,topic) VALUES (2,1,'2026-11-21 10:00',2,'Розмітка');

-- ---------- 5. Відвідуваність ----------
SELECT 'T16 Відмітка відвідування -> OK' AS test;
INSERT INTO theory_attendance(lesson_id,enrollment_id,present,absence_reason) VALUES
 (1,1,TRUE,NULL),(1,2,FALSE,'illness');
SELECT 'OK' AS result;

SELECT 'T17 Відсутній без причини (NULL) -> відмова (CHECK)' AS test;
INSERT INTO theory_attendance(lesson_id,enrollment_id,present,absence_reason) VALUES (1,5,FALSE,NULL);

SELECT 'T18 Курсант іншої групи -> відмова' AS test;
INSERT INTO theory_attendance(lesson_id,enrollment_id,present) VALUES (1,6,TRUE);

SELECT 'T19 Заняття ще не відбулося -> відмова' AS test;
INSERT INTO theory_attendance(lesson_id,enrollment_id,present) VALUES (2,1,TRUE);

-- ---------- 6. Практичні заняття ----------
SELECT 'T20 Практика -> OK' AS test;
INSERT INTO practice_lessons(lesson_id,enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,1,1,1,'2026-11-20 10:00',1.5);
SELECT 'OK' AS result;

SELECT 'T21 Інструктор зайнятий (частковий перетин) -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (2,1,2,'2026-11-20 11:00',1);

SELECT 'T22 Суміжні інтервали 10:00-11:30 і 11:30-12:30 -> OK' AS test;
INSERT INTO practice_lessons(lesson_id,enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (2,2,1,1,'2026-11-20 11:30',1);
SELECT 'OK' AS result;

SELECT 'T23 Автомобіль зайнятий -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (5,2,1,'2026-11-20 12:00',1);

SELECT 'T24 Курсант зайнятий -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,2,2,'2026-11-20 10:30',1);

SELECT 'T25 Курсант на теорії -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,2,2,'2026-11-20 18:30',1);

SELECT 'T26 Без медичної довідки (Курсант 4, група B-2) -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (7,2,2,'2026-11-21 10:00',1);

SELECT 'T27 Довідка чинна до 15.11, заняття 21.11 -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (4,2,2,'2026-11-21 10:00',1);

SELECT 'T28 Та сама довідка, заняття 12.11 -> OK' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (4,2,2,'2026-11-12 10:00',1);
SELECT 'OK' AS result;

SELECT 'T29 Інструктор без права на категорію B -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,4,1,'2026-11-21 10:00',1);

SELECT 'T30 Викладач замість інструктора -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,3,1,'2026-11-21 10:00',1);

SELECT 'T31 Мотоцикл для категорії B -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,1,3,'2026-11-21 10:00',1);

SELECT 'T32 Прострочене ТО (до 10.11) -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,2,4,'2026-11-21 10:00',1);

SELECT 'T33 Відрахований курсант -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (3,1,1,'2026-11-21 10:00',1);

SELECT 'T34 Поза строком групи -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,1,1,'2027-03-01 10:00',1);

SELECT 'T35 Поза робочим часом (20:30-21:30) -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,1,1,'2026-11-21 20:30',1);

SELECT 'T36 Зміна статусу на done -> OK (не блокується)' AS test;
UPDATE practice_lessons SET status = 'done' WHERE lesson_id = 1;
SELECT 'OK' AS result;

SELECT 'T37 Перенесення на зайнятий час -> відмова' AS test;
UPDATE practice_lessons SET starts_at = '2026-11-20 11:00' WHERE lesson_id = 1;

SELECT 'T38 Скасоване заняття звільняє слот -> OK' AS test;
UPDATE practice_lessons SET status = 'cancelled' WHERE lesson_id = 2;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (2,2,2,'2026-11-20 11:30',1);
SELECT 'OK' AS result;

SELECT 'T39 Денний ліміт: 4 + 3.5 = 7.5 OK, + 1 = 8.5 -> відмова' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES
 (1,2,2,'2026-11-23 07:00',4), (2,2,2,'2026-11-23 11:00',3.5);
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,2,2,'2026-11-23 15:00',1);

SELECT 'T40 Денний ліміт рівно 8.0 (7.5 + 0.5) -> OK' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,2,2,'2026-11-23 15:00',0.5);
SELECT 'OK' AS result;

SELECT 'T41 Теорія, коли курсант групи має практику -> відмова' AS test;
INSERT INTO theory_lessons(group_id,teacher_id,starts_at,duration_hours,topic) VALUES (1,5,'2026-11-20 10:00',2,'Розмітка');

-- ---------- 7. Скасування теоретичних занять ----------
SELECT 'T42 Скасована теорія звільняє слот: нове заняття групи в той самий час -> OK' AS test;
UPDATE theory_lessons SET status = 'cancelled' WHERE lesson_id = 2;
INSERT INTO theory_lessons(lesson_id,group_id,teacher_id,starts_at,duration_hours,topic)
VALUES (3,1,5,'2026-11-20 18:00',2,'Дорожні знаки (перенесено)');
SELECT 'OK' AS result;

SELECT 'T43 Скасована теорія не блокує практику курсанта -> OK' AS test;
UPDATE theory_lessons SET status = 'cancelled' WHERE lesson_id = 3;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,2,2,'2026-11-20 18:30',1);
SELECT 'OK' AS result;

SELECT 'T44 Відновлення скасованої теорії, коли слот уже зайнятий практикою -> відмова' AS test;
UPDATE theory_lessons SET status = 'planned' WHERE lesson_id = 3;

SELECT 'T45 Відмітка відвідування на скасованому занятті -> відмова' AS test;
UPDATE theory_lessons SET starts_at = '2026-10-21 18:00' WHERE lesson_id = 3; -- у минуле (скасоване, без перевірки)
INSERT INTO theory_attendance(lesson_id,enrollment_id,present) VALUES (3,1,TRUE);

-- ---------- 8. NULL-safe перевірки існування ----------
-- FOREIGN_KEY_CHECKS - змінна СЕСІЇ: навіть якщо скрипт обірветься, вона зникне разом
-- із з'єднанням і не вплине на інші підключення. Додатково блок обгорнуто в транзакцію
-- з ROLLBACK: якщо якийсь INSERT несподівано пройде, рядок без батьківського запису
-- не залишиться в базі. --force не зупиняє скрипт, тому SET ... = 1 виконається завжди.
START TRANSACTION;
SET FOREIGN_KEY_CHECKS = 0;  -- лише для тесту: імітуємо "зник" рядок, щоб перевірити повідомлення тригера
SELECT 'T46 Відвідуваність для неіснуючого заняття -> зрозуміле повідомлення' AS test;
INSERT INTO theory_attendance(lesson_id,enrollment_id,present) VALUES (999,1,TRUE);
SELECT 'T47 Відвідуваність для неіснуючого зарахування -> зрозуміле повідомлення' AS test;
INSERT INTO theory_attendance(lesson_id,enrollment_id,present) VALUES (1,999,TRUE);
SELECT 'T48 Зарахування до неіснуючої групи -> зрозуміле повідомлення' AS test;
INSERT INTO enrollments(student_id,group_id,enrolled_on) VALUES (1,999,'2026-10-01');
SELECT 'T49 Практика з неіснуючим інструктором -> зрозуміле повідомлення' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,999,1,'2026-11-25 10:00',1);
SELECT 'T50 Практика з неіснуючим авто -> зрозуміле повідомлення' AS test;
INSERT INTO practice_lessons(enrollment_id,instructor_id,vehicle_id,starts_at,duration_hours) VALUES (1,1,999,'2026-11-25 10:00',1);
SET FOREIGN_KEY_CHECKS = 1;
ROLLBACK;
SELECT 'T50a Після блоку: FK-перевірки увімкнено, «сирітських» рядків немає' AS test;
SELECT @@foreign_key_checks AS fk_checks,
       (SELECT COUNT(*) FROM theory_attendance WHERE lesson_id = 999 OR enrollment_id = 999) +
       (SELECT COUNT(*) FROM enrollments WHERE group_id = 999) +
       (SELECT COUNT(*) FROM practice_lessons WHERE instructor_id = 999 OR vehicle_id = 999) AS orphan_rows;

-- ---------- 9. Іспити ----------
INSERT INTO exam_types(code,name,pass_score) VALUES
 ('internal_theory','Внутрішній іспит з теорії',90),
 ('internal_practice','Внутрішній іспит з практики',NULL),
 ('final','Підсумковий іспит',NULL);

SELECT 'T51 Теорія 85 балів (прохідний 90) -> passed обчислено = 0, спроба 1' AS test;
INSERT INTO exams(enrollment_id,exam_type_id,exam_date,score,passed) VALUES (1,1,'2026-11-25',85,TRUE);
SELECT attempt_no, score, passed FROM exams WHERE enrollment_id=1 AND exam_type_id=1 ORDER BY attempt_no;

SELECT 'T52 Друга спроба 95 балів -> passed = 1, спроба 2' AS test;
INSERT INTO exams(enrollment_id,exam_type_id,exam_date,score) VALUES (1,1,'2026-11-28',95);
SELECT attempt_no, score, passed FROM exams WHERE enrollment_id=1 AND exam_type_id=1 ORDER BY attempt_no;

SELECT 'T53 Третя спроба після успішної здачі -> відмова' AS test;
INSERT INTO exams(enrollment_id,exam_type_id,exam_date,score) VALUES (1,1,'2026-11-29',100);

SELECT 'T54 Бальний іспит без балу -> відмова' AS test;
INSERT INTO exams(enrollment_id,exam_type_id,exam_date) VALUES (2,1,'2026-11-25');

SELECT 'T54a Залік без результату (passed не вказано) -> відмова, а не тихий FALSE' AS test;
INSERT INTO exams(enrollment_id,exam_type_id,exam_date) VALUES (2,2,'2026-11-25');

SELECT 'T55 Залік (практика) з балом -> відмова' AS test;
INSERT INTO exams(enrollment_id,exam_type_id,exam_date,score,passed) VALUES (2,2,'2026-11-25',80,TRUE);

SELECT 'T56 Залік без балу, passed задано вручну -> OK' AS test;
INSERT INTO exams(enrollment_id,exam_type_id,exam_date,passed) VALUES (2,2,'2026-11-25',TRUE);
SELECT attempt_no, score, passed FROM exams WHERE enrollment_id=2 AND exam_type_id=2;

SELECT 'T57a Виправлення балу ОСТАННЬОЇ спроби 95 -> 80 перераховує passed = 0' AS test;
UPDATE exams SET score = 80 WHERE enrollment_id=1 AND exam_type_id=1 AND attempt_no=2;
SELECT attempt_no, score, passed FROM exams WHERE enrollment_id=1 AND exam_type_id=1 ORDER BY attempt_no;

SELECT 'T57b Зарахування ранньої спроби, коли є наступні (85 -> 92 у спробі 1) -> відмова' AS test;
UPDATE exams SET score = 92 WHERE enrollment_id=1 AND exam_type_id=1 AND attempt_no=1;

SELECT 'T57c Скасування заняття ПІСЛЯ відмітки -> змінити присутність уже не можна' AS test;
UPDATE theory_lessons SET status = 'cancelled' WHERE lesson_id = 1;
UPDATE theory_attendance SET present = TRUE, absence_reason = NULL WHERE lesson_id = 1 AND enrollment_id = 2;
UPDATE theory_lessons SET status = 'done' WHERE lesson_id = 1;

SELECT 'T58 Оплата заднім числом (власне paid_at) -> OK' AS test;
INSERT INTO payments(enrollment_id,kind,amount,paid_at,method_id,note) VALUES (2,'payment',1000,'2026-10-05 12:00',1,'Квитанція №17');
SELECT paid_at FROM payments WHERE note = 'Квитанція №17';
