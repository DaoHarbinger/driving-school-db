"""
Мінімальний вебінтерфейс ІС «Автошкола».

Ключова ідея: користувач входить під СВОЇМ обліковим записом MySQL
(manager_olena, acc_iryna, instr_bondarenko, ...). Програма не має власної
таблиці користувачів і не перевіряє права сама - кожен запит виконується
з правами цього користувача, тож дозволи й заборони визначає база даних
(ролі з 07_security.sql), а бізнес-правила - тригери.

Запуск:  pip install -r requirements.txt
         python app.py
         відкрити http://127.0.0.1:5000
"""
import re
import secrets
from datetime import date, datetime, timedelta
from decimal import Decimal

import pymysql
from flask import Flask, flash, redirect, render_template, request, session, url_for

DB_HOST = "127.0.0.1"
DB_PORT = 3306
DB_NAME = "driving_school"

app = Flask(__name__)
app.secret_key = secrets.token_hex(16)

# Паролі зберігаються лише в пам'яті сервера (не в cookie браузера):
# у сесії браузера лежить тільки випадковий токен.
CREDENTIALS: dict[str, tuple[str, str]] = {}


# ---------------------------------------------------------------------------
# Робота з базою даних
# ---------------------------------------------------------------------------
class DbError(Exception):
    """Помилка MySQL з людським повідомленням (тригер, нестача прав тощо)."""


def connect(user: str, password: str):
    return pymysql.connect(host=DB_HOST, port=DB_PORT, user=user, password=password,
                           database=DB_NAME, charset="utf8mb4", autocommit=True,
                           cursorclass=pymysql.cursors.DictCursor)


def db():
    token = session.get("token")
    if token not in CREDENTIALS:
        raise PermissionError
    return connect(*CREDENTIALS[token])


def run(sql: str, args=None, all_sets: bool = False):
    """Виконує запит. Повертає рядки (або список наборів рядків для процедур
    з кількома результатами). Помилку MySQL перетворює на DbError з текстом."""
    try:
        with db() as conn, conn.cursor() as cur:
            cur.execute(sql, args)
            sets = [cur.fetchall()]
            while all_sets and cur.nextset():
                sets.append(cur.fetchall())
            return [s for s in sets if s] if all_sets else sets[0]
    except pymysql.MySQLError as e:
        raise DbError(explain(e)) from e


def call_with_message(sql: str, args) -> tuple[bool, str]:
    """Для процедур з OUT-параметрами @id, @msg (sp_book_practice тощо)."""
    try:
        with db() as conn, conn.cursor() as cur:
            cur.execute(sql, args)
            cur.execute("SELECT @id AS id, @msg AS msg")
            row = cur.fetchone()
            ok = row["id"] is not None
            # процедура повертає текст помилки MySQL як є - перекладаємо його так само
            return ok, row["msg"] if ok else friendly(row["msg"] or "")
    except pymysql.MySQLError as e:
        raise DbError(explain(e)) from e


# Повідомлення для порушень унікальності (1062) і CHECK (3819) за іменем обмеження в схемі
CONSTRAINT_MESSAGES = {
    "uq_students_phone": "Курсант з таким телефоном уже існує",
    "uq_employees_phone": "Співробітник з таким телефоном уже існує",
    "uq_enrollments_student_group": "Курсант уже зарахований до цієї групи",
    "PRIMARY": "Такий запис уже існує",
    "ck_students_birth": "Дата народження має бути раніше дати реєстрації",
    "ck_documents_dates": "Термін дії документа не може закінчуватися раніше дати видачі",
    "ck_empcat_dates": "Термін дії кваліфікації не може закінчуватися раніше дати отримання",
    "ck_enrollments_price": "Ціна не може бути від'ємною",
    "ck_payments_amount": "Сума має бути більшою за нуль",
    "uq_groups_name": "Група з такою назвою вже існує",
    "ck_groups_dates": "Дата завершення групи має бути пізніше дати початку",
    "ck_groups_max": "Місткість групи - від 1 до 40 курсантів",
    "uq_vehicles_plate": "Автомобіль з таким номером уже є",
    "ck_vehicles_year": "Некоректний рік випуску",
    "ck_exams_score": "Бал має бути від 0 до 100",
}


def friendly(text: str) -> str:
    """Технічні повідомлення про дублікати / CHECK -> зрозумілі (за іменем обмеження)."""
    if text.startswith(("Duplicate entry", "Check constraint")):
        for name, msg in CONSTRAINT_MESSAGES.items():
            if f"'{name}'" in text or f".{name}'" in text:
                return msg
    if text.startswith("Data too long"):
        return "Задане значення задовге для поля"
    return text                              # SIGNAL з тригера - вже зрозумілий текст


def explain(e: pymysql.MySQLError) -> str:
    code, text = (e.args + ("",))[:2]
    if code in (1142, 1143, 1370):          # нестача прав на таблицю / стовпець / процедуру
        return f"База даних відмовила в доступі: {text}"
    return friendly(text)


def current_roles() -> set[str]:
    rows = run("SELECT CURRENT_ROLE() AS r")
    roles = set(re.findall(r"`(r_\w+)`", rows[0]["r"] or ""))
    if not roles and session.get("user") == "root":
        roles = {"r_admin"}
    return roles


# ---------------------------------------------------------------------------
# Меню: яка роль які сторінки бачить (лише зручність - захищає БАЗА)
# ---------------------------------------------------------------------------
PAGES = [
    ("students",  "Курсанти",       {"r_admin", "r_manager"}),
    ("groups",    "Групи і теорія",  {"r_admin", "r_manager"}),
    ("schedule",  "Практика",        {"r_admin", "r_manager"}),
    ("exams",     "Іспити",          {"r_admin", "r_manager"}),
    ("vehicles",  "Автомобілі",      {"r_admin", "r_manager"}),
    ("reports",   "Звіти",           {"r_admin", "r_manager"}),
    ("finance",   "Фінанси",         {"r_admin", "r_accountant"}),
    ("my",        "Мої заняття",     {"r_instructor"}),
    ("teacher",   "Відвідуваність",  {"r_teacher"}),
    ("audit",     "Журнал аудиту",   {"r_admin", "r_auditor"}),
    ("staff",     "Персонал і доступ", {"r_admin"}),
]
ROLE_NAMES = {"r_admin": "адміністратор", "r_manager": "менеджер", "r_accountant": "бухгалтер",
              "r_instructor": "інструктор", "r_teacher": "викладач", "r_auditor": "аудитор",
              "r_backup": "резервне копіювання"}


@app.context_processor
def inject_menu():
    roles = set(session.get("roles", []))
    return {"menu": [(p, t) for p, t, r in PAGES if roles & r],
            "role_title": ", ".join(ROLE_NAMES.get(r, r) for r in sorted(roles)) or "—",
            "today": date.today().isoformat()}


# ---------------------------------------------------------------------------
# Форматування значень у таблицях
# ---------------------------------------------------------------------------
LABELS = {
    "student": "Курсант", "phone": "Телефон", "group_name": "Група", "category": "Кат.",
    "status": "Статус", "enrolled_on": "Зараховано", "lesson_date": "Дата", "day_name": "День",
    "time_from": "З", "time_to": "До", "vehicle": "Автомобіль", "theory": "Теорія, год",
    "practice": "Практика, год", "debt": "Борг, грн", "has_medical": "Меддовідка",
    "decision": "Рішення", "reasons": "Причини", "theory_hours": "Теорія", "practice_hours": "Практика",
    "theory_hours_min": "Мін. теорії", "practice_hours_min": "Мін. практики", "admitted": "Допущено",
    "groups": "Групи", "medical_valid_until": "Довідка до", "problem": "Проблема",
    "plate_number": "Номер", "default_instructor": "Інструктор", "next_service_date": "ТО",
    "days_left": "Днів", "state": "Стан", "lessons_to_reschedule": "Перенести занять",
    "instructor": "Інструктор", "hours_done": "Проведено, год", "hours_planned": "Заплановано, год",
    "lessons_missed_by_students": "Пропущено курсантами", "students": "Курсантів",
    "working_days": "Робочих днів", "avg_hours_per_day": "Год/день", "exam_type": "Іспит",
    "students_examined": "Складали", "passed": "Склали", "passed_first_attempt": "З 1-ї спроби",
    "first_attempt_pct": "% з 1-ї спроби", "avg_attempts": "Спроб у сер.", "avg_first_score": "Сер. бал",
    "agreed_price": "Ціна, грн", "paid": "Сплачено, грн", "paid_pct": "%", "last_payment": "Остання оплата",
    "paid_at": "Дата", "operation": "Операція", "amount": "Сума, грн", "method": "Спосіб",
    "balance": "Баланс, грн", "note": "Коментар", "starts_at": "Початок", "ends_at": "Кінець",
    "student_phone": "Телефон", "topic": "Тема", "audit_id": "№", "table_name": "Таблиця",
    "operation_type": "Операція", "record_id": "Запис", "changed_by": "Хто", "changed_at": "Коли",
    "old_value": "Було", "new_value": "Стало", "login": "Логін", "role": "Роль", "employee": "Співробітник",
    "locked": "Заблоковано", "password_changed": "Пароль змінено", "full_name": "ПІБ", "position": "Посада",
    "hire_date": "Прийнятий", "experience_years": "Стаж, р.", "is_active": "Працює", "db_login": "Логін",
    "qualifications": "Категорії", "email": "Email", "address": "Адреса", "birth_date": "Дата народження",
    "registered_at": "Зареєстровано", "doc_type": "Документ", "number": "Номер", "issue_date": "Видано",
    "valid_until": "Дійсний до", "validity": "Стан", "attempt_no": "Спроба", "exam_date": "Дата", "score": "Бал",
}
VALUE_NAMES = {"planned": "заплановано", "done": "проведено", "missed": "пропущено",
               "cancelled": "скасовано", "studying": "навчається", "graduated": "закінчив",
               "expelled": "відрахований", "leave": "академвідпустка", "morning": "ранкова",
               "evening": "вечірня", "INSERT": "додано", "UPDATE": "змінено", "DELETE": "видалено",
               "teacher": "викладач", "instructor": "інструктор", **{k: v for k, v in [
                   ("r_admin", "адміністратор"), ("r_manager", "менеджер"), ("r_accountant", "бухгалтер"),
                   ("r_instructor", "інструктор"), ("r_teacher", "викладач"), ("r_auditor", "аудитор")]}}


@app.template_filter("fmt")
def fmt(value, column=""):
    if value is None:
        return "—"
    if column in ("has_medical", "admitted", "locked", "is_active") or isinstance(value, bool):
        return "так" if value else "ні"
    if isinstance(value, datetime):
        return value.strftime("%d.%m.%Y %H:%M")
    if isinstance(value, date):
        return value.strftime("%d.%m.%Y")
    if isinstance(value, Decimal):
        return f"{value:,.2f}".replace(",", " ") if value % 1 else f"{value:,.0f}".replace(",", " ")
    return VALUE_NAMES.get(value, value) if isinstance(value, str) else value


@app.template_filter("label")
def label(column):
    return LABELS.get(column, column)


# ---------------------------------------------------------------------------
# Вхід / вихід
# ---------------------------------------------------------------------------
@app.route("/", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        user, password = request.form["user"].strip(), request.form["password"]
        try:
            connect(user, password).close()
        except pymysql.MySQLError as e:
            # тут видно й блокування після 5 невдалих спроб (FAILED_LOGIN_ATTEMPTS)
            flash(f"Вхід не виконано: {e.args[1]}", "error")
            return render_template("login.html", user=user)
        token = secrets.token_urlsafe(16)
        CREDENTIALS[token] = (user, password)
        session.update(token=token, user=user)
        session["roles"] = sorted(current_roles())
        allowed = [p for p, _, r in PAGES if set(session["roles"]) & r]
        return redirect(url_for(allowed[0] if allowed else "login"))
    return render_template("login.html", user="")


@app.route("/logout")
def logout():
    CREDENTIALS.pop(session.get("token"), None)
    session.clear()
    return redirect(url_for("login"))


@app.errorhandler(PermissionError)
def need_login(_):
    return redirect(url_for("login"))


def page(template, **ctx):
    """Рендер сторінки; помилки бази показуються в повідомленні, а не «падають»."""
    return render_template(template, **ctx)


def safe(fn, *args, default=None, **kw):
    try:
        return fn(*args, **kw)
    except DbError as e:
        flash(str(e), "error")
        return default if default is not None else []


# ---------------------------------------------------------------------------
# Менеджер
# ---------------------------------------------------------------------------
def run_many(statements):
    """Кілька запитів в ОДНІЙ транзакції: або всі, або жоден. Повертає lastrowid першого."""
    try:
        with db() as conn, conn.cursor() as cur:
            conn.begin()
            first_id = None
            try:
                for sql, args in statements:
                    cur.execute(sql, args)
                    first_id = first_id or cur.lastrowid
                conn.commit()
            except Exception:
                conn.rollback()
                raise
            return first_id
    except pymysql.MySQLError as e:
        raise DbError(explain(e)) from e


def blank(v):
    return v.strip() if v and v.strip() else None


@app.route("/students", methods=["GET", "POST"])
def students():
    if request.method == "POST":
        f, action = request.form, request.form["action"]
        try:
            if action == "student":
                # курсант і (необов'язково) меддовідка - однією транзакцією
                stmts = [("INSERT INTO students (full_name, birth_date, phone, email, address) "
                          "VALUES (%s, %s, %s, %s, %s)",
                          (f["full_name"].strip(), f["birth_date"], f["phone"].strip(),
                           blank(f.get("email")), blank(f.get("address"))))]
                if blank(f.get("med_number")):
                    stmts.append(("INSERT INTO documents (student_id, document_type_id, number, issue_date, valid_until) "
                                  "SELECT LAST_INSERT_ID(), document_type_id, %s, %s, %s "
                                  "FROM document_types WHERE code = 'medical'",
                                  (f["med_number"].strip(), f["med_issue"], blank(f.get("med_valid")))))
                new_id = run_many(stmts)
                if not f.get("group_id"):
                    flash("Курсанта додано, але НЕ зараховано до групи: зарахуйте його формою «Зарахувати до групи».", "warn")
                    return redirect(url_for("students", new=new_id))
                # зарахування - окремим кроком (процедура має власну транзакцію і перевірки:
                # строк групи, місткість, категорія, переплата)
                ok, msg = call_with_message(
                    "CALL sp_enroll_student(%s, %s, NULL, NULL, %s, %s, @id, @msg)",
                    (new_id, f["group_id"], blank(f.get("first_payment")), f.get("method_id") or None))
                if ok:
                    flash("Курсанта додано і зараховано до групи", "ok")
                    return redirect(url_for("student_card", student_id=new_id))
                flash(f"Курсанта додано, але зарахувати не вдалося: {msg}", "error")
                return redirect(url_for("students", new=new_id))
            if action == "document":
                run("INSERT INTO documents (student_id, document_type_id, number, issue_date, valid_until) "
                    "VALUES (%s, %s, %s, %s, %s)",
                    (f["student_id"], f["document_type_id"], f["number"].strip(), f["issue_date"], blank(f.get("valid_until"))))
                flash("Документ додано", "ok")
            if action == "enroll":
                ok, msg = call_with_message(
                    "CALL sp_enroll_student(%s, %s, %s, %s, %s, %s, @id, @msg)",
                    (f["student_id"], f["group_id"], blank(f.get("price")), blank(f.get("discount_note")),
                     blank(f.get("first_payment")), f.get("method_id") or None))
                flash(msg, "ok" if ok else "error")
                if ok:
                    return redirect(url_for("students", group_id=f["group_id"]))
        except DbError as e:
            flash(str(e), "error")
        return redirect(url_for("students"))

    group_id = request.args.get("group_id", type=int)
    only_active = request.args.get("active") == "1"
    groups = safe(run, "SELECT group_id, name FROM study_groups ORDER BY start_date DESC")
    rows = safe(run, "CALL sp_students_list(%s, NULL, %s)", (group_id, only_active))
    all_students = safe(run, "SELECT student_id, full_name, phone FROM students ORDER BY student_id DESC")
    not_enrolled = safe(run, "SELECT s.student_id, s.full_name, s.phone, s.registered_at FROM students s "
                             "WHERE NOT EXISTS (SELECT 1 FROM enrollments e WHERE e.student_id = s.student_id) "
                             "ORDER BY s.student_id DESC")
    open_groups = safe(run, "SELECT g.group_id, g.name, g.max_students, "
                            "(SELECT COUNT(*) FROM enrollments e JOIN enrollment_statuses st ON st.status_id = e.status_id "
                            "  WHERE e.group_id = g.group_id AND st.code = 'studying') AS studying "
                            "FROM study_groups g WHERE g.end_date >= CURDATE() ORDER BY g.start_date")
    doc_types = safe(run, "SELECT document_type_id, name FROM document_types ORDER BY document_type_id")
    methods = safe(run, "SELECT method_id, name FROM payment_methods")
    return page("students.html", groups=groups, rows=rows, group_id=group_id, only_active=only_active,
                all_students=all_students, doc_types=doc_types, methods=methods,
                not_enrolled=not_enrolled, open_groups=open_groups,
                new_id=request.args.get("new", type=int))


@app.route("/student/<int:student_id>", methods=["GET", "POST"])
def student_card(student_id):
    if request.method == "POST" and request.form.get("action") == "status":
        f = request.form
        try:
            ok_msg = call_status(f["enrollment_id"], f["new_status"])
            flash(*ok_msg)
        except DbError as e:
            flash(str(e), "error")
        return redirect(url_for("student_card", student_id=student_id))
    if request.method == "POST" and request.form.get("action") == "enroll":
        f = request.form
        try:
            ok, msg = call_with_message(
                "CALL sp_enroll_student(%s, %s, %s, %s, %s, %s, @id, @msg)",
                (student_id, f["group_id"], blank(f.get("price")), blank(f.get("discount_note")),
                 blank(f.get("first_payment")), f.get("method_id") or None))
            flash(msg, "ok" if ok else "error")
        except DbError as e:
            flash(str(e), "error")
        return redirect(url_for("student_card", student_id=student_id))
    if request.method == "POST":
        f = request.form
        try:
            run("UPDATE students SET full_name = %s, birth_date = %s, phone = %s, email = %s, address = %s "
                "WHERE student_id = %s",
                (f["full_name"].strip(), f["birth_date"], f["phone"].strip(),
                 blank(f.get("email")), blank(f.get("address")), student_id))
            flash("Дані курсанта збережено", "ok")
        except DbError as e:
            flash(str(e), "error")
        return redirect(url_for("student_card", student_id=student_id))

    info = safe(run, "SELECT student_id, full_name, birth_date, phone, email, address, registered_at "
                     "FROM students WHERE student_id = %s", (student_id,))
    if not info and not get_flashed_messages_peek():
        flash("Курсанта не знайдено", "error")
    documents = safe(run, "SELECT t.name AS doc_type, d.number, d.issue_date, d.valid_until, "
                          "CASE WHEN d.valid_until IS NULL THEN 'безстроковий' "
                          "     WHEN d.valid_until < CURDATE() THEN 'прострочений' "
                          "     WHEN d.valid_until < CURDATE() + INTERVAL 30 DAY THEN 'спливає скоро' "
                          "     ELSE 'чинний' END AS validity "
                          "FROM documents d JOIN document_types t ON t.document_type_id = d.document_type_id "
                          "WHERE d.student_id = %s ORDER BY t.document_type_id, d.issue_date DESC", (student_id,))
    studies = safe(run, "SELECT a.enrollment_id, a.group_name, a.category, a.status_code AS status, a.theory_hours, a.theory_hours_min, "
                        "a.practice_hours, a.practice_hours_min, p.agreed_price, p.paid, a.debt, a.admitted, a.reasons "
                        "FROM v_exam_admission a JOIN v_enrollment_progress p ON p.enrollment_id = a.enrollment_id "
                        "WHERE p.student_id = %s ORDER BY p.enrollment_id", (student_id,))
    open_groups = safe(run, "SELECT g.group_id, g.name, g.max_students, "
                            "(SELECT COUNT(*) FROM enrollments e JOIN enrollment_statuses st ON st.status_id = e.status_id "
                            "  WHERE e.group_id = g.group_id AND st.code = 'studying') AS studying "
                            "FROM study_groups g WHERE g.end_date >= CURDATE() ORDER BY g.start_date")
    methods = safe(run, "SELECT method_id, name FROM payment_methods")
    return page("student.html", s=info[0] if info else None, documents=documents, studies=studies,
                open_groups=open_groups, methods=methods)


def call_status(enrollment_id, new_status):
    """sp_change_enrollment_status повертає текст в OUT-параметрі; помилку визначаємо за текстом."""
    try:
        with db() as conn, conn.cursor() as cur:
            cur.execute("CALL sp_change_enrollment_status(%s, %s, @msg)", (enrollment_id, new_status))
            cur.execute("SELECT @msg AS msg")
            msg = cur.fetchone()["msg"] or ""
    except pymysql.MySQLError as e:
        raise DbError(explain(e)) from e
    ok = msg.startswith("Курсанта")
    return (msg if ok else friendly(msg)), ("ok" if ok else "error")


def get_flashed_messages_peek():
    from flask import session as s
    return bool(s.get("_flashes"))


@app.route("/schedule", methods=["GET", "POST"])
def schedule():
    if request.method == "POST":
        f = request.form
        try:
            ok, msg = call_with_message(
                "CALL sp_book_practice(%s, %s, NULL, %s, %s, @id, @msg)",
                (f["enrollment_id"], f["instructor_id"], f["starts_at"].replace("T", " "), f["duration"]))
            flash(msg, "ok" if ok else "error")
        except DbError as e:
            flash(str(e), "error")
        return redirect(url_for("schedule", instructor_id=f["instructor_id"],
                                week=f["starts_at"][:10], day=f["starts_at"][:10]))

    instructors = safe(run, "SELECT employee_id, full_name FROM employees "
                            "WHERE role = 'instructor' AND is_active ORDER BY full_name")
    instructor_id = request.args.get("instructor_id", type=int) or (instructors[0]["employee_id"] if instructors else None)
    week = request.args.get("week") or date.today().isoformat()
    day = request.args.get("day") or week
    lessons = safe(run, "CALL sp_instructor_schedule(%s, %s)", (instructor_id, week))
    slots = safe(run, "CALL sp_instructor_free_slots(%s, %s)", (instructor_id, day))
    enrollments = safe(run, "SELECT enrollment_id, student, group_name FROM v_students "
                            "WHERE status_code = 'studying' ORDER BY student")
    return page("schedule.html", instructors=instructors, instructor_id=instructor_id, week=week,
                day=day, lessons=lessons, slots=slots, enrollments=enrollments)


@app.route("/schedule/cancel", methods=["POST"])
def cancel_practice():
    f = request.form
    try:
        run("CALL sp_cancel_practice(%s)", (f["lesson_id"],))
        flash("Заняття скасовано, час звільнено", "ok")
    except DbError as e:
        flash(str(e), "error")
    return redirect(url_for("schedule", instructor_id=f["instructor_id"], week=f["week"], day=f["day"]))


@app.route("/admission")
def admission():
    return redirect(url_for("exams", **request.args))


@app.route("/exams", methods=["GET", "POST"])
def exams():
    if request.method == "POST":
        f = request.form
        code = f["exam_code"]
        score = blank(f.get("score")) if code == "internal_theory" else None
        passed = None if code == "internal_theory" else {"1": True, "0": False}.get(f.get("passed"))
        try:
            ok, msg = call_with_message("CALL sp_record_exam(%s, %s, %s, %s, %s, @id, @msg)",
                                        (f["enrollment_id"], code, f["exam_date"], score, passed))
            failed_exam = ok and "не складено" in msg
            flash(msg, "error" if not ok else ("warn" if failed_exam else "ok"))
        except DbError as e:
            flash(str(e), "error")
        return redirect(url_for("exams", group=f.get("group")))

    group = request.args.get("group") or None
    groups = safe(run, "SELECT name FROM study_groups ORDER BY start_date DESC")
    rows = safe(run, "SELECT a.enrollment_id, a.student, a.group_name, a.category, a.theory_hours, a.theory_hours_min, "
                     "a.practice_hours, a.practice_hours_min, a.debt, a.has_medical, a.admitted, a.reasons, "
                     "(SELECT GROUP_CONCAT(CONCAT(t.name, ': ', IF(x.passed, 'склав', 'не склав'), ' (', x.attempt_no, ')') "
                     "        ORDER BY x.exam_type_id, x.attempt_no SEPARATOR '; ') "
                     "   FROM exams x JOIN exam_types t ON t.exam_type_id = x.exam_type_id "
                     "  WHERE x.enrollment_id = a.enrollment_id) AS exams_done "
                     "FROM v_exam_admission a WHERE a.status_code = 'studying' "
                     "AND (%s IS NULL OR a.group_name = %s) ORDER BY a.group_name, a.student", (group, group))
    history = safe(run, "SELECT x.exam_date, s.full_name AS student, g.name AS group_name, t.name AS exam_type, "
                        "x.attempt_no, x.score, x.passed "
                        "FROM exams x JOIN exam_types t ON t.exam_type_id = x.exam_type_id "
                        "JOIN enrollments e ON e.enrollment_id = x.enrollment_id "
                        "JOIN students s ON s.student_id = e.student_id JOIN study_groups g ON g.group_id = e.group_id "
                        "WHERE %s IS NULL OR g.name = %s ORDER BY x.exam_date DESC, x.exam_id DESC LIMIT 50", (group, group))
    return page("exams.html", rows=rows, groups=groups, group=group, history=history)


# ---------------------------------------------------------------------------
# Групи і теоретичні заняття
# ---------------------------------------------------------------------------
WEEKDAYS = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Нд"]


@app.route("/groups", methods=["GET", "POST"])
def groups():
    if request.method == "POST":
        f, action = request.form, request.form["action"]
        try:
            if action == "group":
                run("INSERT INTO study_groups (name, category_id, start_date, end_date, shift, max_students) "
                    "VALUES (%s, %s, %s, %s, %s, %s)",
                    (f["name"].strip(), f["category_id"], f["start_date"], f["end_date"], f["shift"], f["max_students"]))
                flash(f"Групу {f['name'].strip()} створено. Тепер заплануйте їй теоретичні заняття.", "ok")
                gid = run("SELECT group_id FROM study_groups WHERE name = %s", (f["name"].strip(),))[0]["group_id"]
                return redirect(url_for("groups", group_id=gid))
            if action == "theory":
                # серія занять: обрані дні тижня, з першої дати, поки не набереться потрібна кількість;
                # кожне заняття вставляється окремо - накладки пропускаються з поясненням
                days = {int(d) for d in f.getlist("weekday")}
                if not days:
                    raise DbError("Оберіть хоча б один день тижня")
                count = max(1, min(int(f.get("count") or 1), 60))
                d = date.fromisoformat(f["first_date"])
                hh, mm = map(int, f["time"].split(":"))
                created, skipped, guard = 0, [], 0
                while created + len(skipped) < count and guard < 400:
                    guard += 1
                    if d.weekday() in days:
                        n = created + len(skipped) + 1
                        topic = f["topic"].strip() + (f" ({n})" if count > 1 else "")
                        try:
                            run("INSERT INTO theory_lessons (group_id, teacher_id, starts_at, duration_hours, topic) "
                                "VALUES (%s, %s, %s, %s, %s)",
                                (f["group_id"], f["teacher_id"], datetime(d.year, d.month, d.day, hh, mm),
                                 f["duration"], topic))
                            created += 1
                        except DbError as e:
                            skipped.append(f"{d.strftime('%d.%m')}: {e}")
                            if len(skipped) >= 5 and created == 0:
                                break      # усі спроби невдалі - далі немає сенсу
                    d += timedelta(days=1)
                if created:
                    flash(f"Заплановано теоретичних занять: {created}", "ok")
                for s in skipped[:8]:
                    flash(f"Пропущено {s}", "error")
                return redirect(url_for("groups", group_id=f["group_id"]))
            if action == "cancel_theory":
                run("CALL sp_cancel_theory(%s)", (f["lesson_id"],))
                flash("Теоретичне заняття скасовано", "ok")
                return redirect(url_for("groups", group_id=f["group_id"]))
        except DbError as e:
            flash(str(e), "error")
        return redirect(url_for("groups", group_id=f.get("group_id")))

    group_id = request.args.get("group_id", type=int)
    group_list = safe(run, "SELECT g.group_id, g.name, c.code AS category, g.start_date, g.end_date, g.shift, "
                           "g.max_students, "
                           "(SELECT COUNT(*) FROM enrollments e JOIN enrollment_statuses s ON s.status_id = e.status_id "
                           "  WHERE e.group_id = g.group_id AND s.code = 'studying') AS studying, "
                           "(SELECT COUNT(*) FROM theory_lessons t WHERE t.group_id = g.group_id AND t.status <> 'cancelled') AS lessons, "
                           "(SELECT COALESCE(SUM(duration_hours), 0) FROM theory_lessons t "
                           "  WHERE t.group_id = g.group_id AND t.status <> 'cancelled') AS hours, c.theory_hours_min "
                           "FROM study_groups g JOIN categories c ON c.category_id = g.category_id "
                           "ORDER BY g.start_date DESC")
    categories = safe(run, "SELECT category_id, code, name FROM categories ORDER BY code")
    teachers = safe(run, "SELECT employee_id, full_name FROM employees WHERE role = 'teacher' AND is_active ORDER BY full_name")
    lessons = safe(run, "SELECT t.lesson_id, t.starts_at, t.duration_hours, t.topic, t.status, e.full_name AS teacher "
                        "FROM theory_lessons t JOIN employees e ON e.employee_id = t.teacher_id "
                        "WHERE t.group_id = %s AND t.starts_at >= NOW() - INTERVAL 14 DAY ORDER BY t.starts_at LIMIT 60",
                   (group_id,)) if group_id else []
    current = next((g for g in group_list if g["group_id"] == group_id), None)
    return page("groups.html", group_list=group_list, categories=categories, teachers=teachers,
                lessons=lessons, group_id=group_id, current=current, weekdays=WEEKDAYS, now=datetime.now())


# ---------------------------------------------------------------------------
# Автомобілі
# ---------------------------------------------------------------------------
@app.route("/vehicles", methods=["GET", "POST"])
def vehicles():
    if request.method == "POST":
        f, action = request.form, request.form["action"]
        try:
            if action == "service":
                run("CALL sp_vehicle_service_done(%s, %s)", (f["vehicle_id"], f["next_date"]))
                flash("ТО відмічено, нова дата збережена", "ok")
            if action == "instructor":
                run("UPDATE vehicles SET default_instructor_id = %s WHERE vehicle_id = %s",
                    (f.get("instructor_id") or None, f["vehicle_id"]))
                flash("Закріпленого інструктора змінено", "ok")
            if action in ("write_off", "restore"):
                run("UPDATE vehicles SET is_active = %s WHERE vehicle_id = %s", (action == "restore", f["vehicle_id"]))
                flash("Автомобіль списано" if action == "write_off" else "Автомобіль повернуто в роботу", "ok")
            if action == "vehicle":
                run("INSERT INTO vehicles (plate_number, make, model, production_year, transmission, category_id, "
                    "default_instructor_id, next_service_date) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
                    (f["plate_number"].strip().upper(), f["make"].strip(), f["model"].strip(), f["production_year"],
                     f["transmission"], f["category_id"], f.get("instructor_id") or None, f["next_service_date"]))
                flash("Автомобіль додано", "ok")
        except DbError as e:
            flash(str(e), "error")
        return redirect(url_for("vehicles"))

    rows = safe(run, "SELECT v.vehicle_id, v.plate_number, CONCAT(v.make, ' ', v.model) AS vehicle, c.code AS category, "
                     "v.transmission, v.production_year, v.default_instructor_id, em.full_name AS instructor, "
                     "v.next_service_date, DATEDIFF(v.next_service_date, CURDATE()) AS days_left, v.is_active, "
                     "(SELECT COUNT(*) FROM practice_lessons p WHERE p.vehicle_id = v.vehicle_id "
                     "  AND p.status = 'planned' AND p.starts_at > NOW()) AS planned "
                     "FROM vehicles v JOIN categories c ON c.category_id = v.category_id "
                     "LEFT JOIN employees em ON em.employee_id = v.default_instructor_id "
                     "ORDER BY v.is_active DESC, v.next_service_date")
    instructors = safe(run, "SELECT e.employee_id, e.full_name, GROUP_CONCAT(c.code ORDER BY c.code) AS cats "
                            "FROM employees e JOIN employee_categories ec ON ec.employee_id = e.employee_id "
                            "JOIN categories c ON c.category_id = ec.category_id "
                            "WHERE e.role = 'instructor' AND e.is_active GROUP BY e.employee_id ORDER BY e.full_name")
    categories = safe(run, "SELECT category_id, code, name FROM categories ORDER BY code")
    return page("vehicles.html", rows=rows, instructors=instructors, categories=categories,
                is_admin="r_admin" in session.get("roles", []),
                default_next=(date.today() + timedelta(days=365)).isoformat())


@app.route("/reports")
def reports():
    on = request.args.get("on") or date.today().isoformat()
    days = request.args.get("days", 30, type=int)
    month = request.args.get("month") or on[:7]
    y, m = map(int, month.split("-"))
    return page("reports.html", on=on, days=days, month=month,
                medical=safe(run, "CALL sp_medical_issues(%s, %s)", (on, days)),
                vehicles=safe(run, "CALL sp_vehicles_service_due(%s, %s)", (days, on)),
                workload=safe(run, "CALL sp_instructor_workload(%s, %s)", (y, m)),
                exams=safe(run, "SELECT * FROM v_exam_results_by_group"))


# ---------------------------------------------------------------------------
# Бухгалтер
# ---------------------------------------------------------------------------
@app.route("/finance", methods=["GET", "POST"])
def finance():
    if request.method == "POST":
        f = request.form
        try:
            run("INSERT INTO payments (enrollment_id, kind, amount, method_id, note) "
                "VALUES (%s, %s, %s, %s, NULLIF(%s, ''))",
                (f["enrollment_id"], f["kind"], f["amount"], f["method_id"], f["note"]))
            flash("Операцію збережено", "ok")
        except DbError as e:
            flash(str(e), "error")
        return redirect(url_for("finance", student_id=f.get("student_id")))

    student_id = request.args.get("student_id", type=int)
    students_list = safe(run, "SELECT student_id, full_name FROM students ORDER BY full_name")
    history = safe(run, "CALL sp_payment_history(%s)", (student_id,), all_sets=True) if student_id else []
    enrollments = safe(run, "SELECT e.enrollment_id, s.full_name, g.name AS group_name "
                            "FROM enrollments e JOIN students s ON s.student_id = e.student_id "
                            "JOIN study_groups g ON g.group_id = e.group_id "
                            "WHERE %s IS NULL OR e.student_id = %s ORDER BY s.full_name",
                       (student_id, student_id))
    methods = safe(run, "SELECT method_id, name FROM payment_methods")
    debtors = safe(run, "SELECT student, phone, group_name, agreed_price, paid, debt, paid_pct, last_payment "
                        "FROM v_debtors ORDER BY debt DESC")
    return page("finance.html", students=students_list, student_id=student_id, history=history,
                enrollments=enrollments, methods=methods, debtors=debtors)


# ---------------------------------------------------------------------------
# Інструктор
# ---------------------------------------------------------------------------
@app.route("/my", methods=["GET", "POST"])
def my():
    if request.method == "POST":
        try:
            run("CALL sp_my_mark_practice(%s, %s)", (request.form["lesson_id"], request.form["status"]))
            flash("Відмітку збережено", "ok")
        except DbError as e:
            flash(str(e), "error")
        return redirect(url_for("my", on=request.form.get("on")))

    on = date.fromisoformat(request.args.get("on") or date.today().isoformat())
    rows = safe(run, "SELECT lesson_id, starts_at, ends_at, student, student_phone, group_name, vehicle, status "
                     "FROM v_my_practice WHERE starts_at >= %s AND starts_at < %s ORDER BY starts_at",
                (on - timedelta(days=7), on + timedelta(days=8)))
    return page("my.html", rows=rows, on=on.isoformat(), now=datetime.now())


# ---------------------------------------------------------------------------
# Викладач теорії
# ---------------------------------------------------------------------------
@app.route("/teacher", methods=["GET", "POST"])
def teacher():
    if request.method == "POST":
        lesson_id = request.form["lesson_id"]
        errors = 0
        for key, value in request.form.items():
            if not key.startswith("p_"):
                continue
            enrollment_id = key[2:]
            present = value == "present"
            try:
                run("CALL sp_my_mark_attendance(%s, %s, %s, %s)",
                    (lesson_id, enrollment_id, present, None if present else value))
            except DbError as e:
                errors += 1
                flash(str(e), "error")
        if not errors:
            flash("Відвідуваність збережено", "ok")
        return redirect(url_for("teacher", lesson_id=lesson_id))

    lessons = safe(run, "SELECT lesson_id, starts_at, group_name, topic FROM v_my_theory "
                        "WHERE status <> 'cancelled' AND starts_at <= NOW() ORDER BY starts_at DESC LIMIT 30")
    lesson_id = request.args.get("lesson_id", type=int) or (lessons[0]["lesson_id"] if lessons else None)
    students_on_lesson = safe(run, "SELECT enrollment_id, student, present, absence_reason "
                                   "FROM v_my_theory_students WHERE lesson_id = %s ORDER BY student", (lesson_id,))
    return page("teacher.html", lessons=lessons, lesson_id=lesson_id, rows=students_on_lesson)


# ---------------------------------------------------------------------------
# Аудитор
# ---------------------------------------------------------------------------
@app.route("/audit")
def audit():
    rows = safe(run, "SELECT audit_id, table_name, operation, record_id, changed_by, changed_at, "
                     "old_value, new_value FROM audit_log ORDER BY audit_id DESC LIMIT 200")
    return page("audit.html", rows=rows)


# ---------------------------------------------------------------------------
# Адміністратор: персонал і облікові записи
# ---------------------------------------------------------------------------
@app.route("/staff", methods=["GET", "POST"])
def staff():
    if request.method == "POST":
        f, action = request.form, request.form["action"]
        try:
            if action == "employee":
                cats = f.getlist("category_id")
                stmts = [("INSERT INTO employees (full_name, phone, role, hire_date, experience_years) "
                          "VALUES (%s, %s, %s, %s, %s)",
                          (f["full_name"].strip(), f["phone"].strip(), f["role"], f["hire_date"],
                           f.get("experience_years") or 0))]
                stmts += [("INSERT INTO employee_categories (employee_id, category_id, granted_date) "
                           "VALUES (LAST_INSERT_ID(), %s, %s)", (c, f["hire_date"])) for c in cats]
                if not cats:
                    raise DbError("Оберіть хоча б одну категорію, яку співробітник має право викладати")
                run_many(stmts)
                flash("Співробітника додано. Тепер можна створити йому обліковий запис.", "ok")
            if action == "account":
                run("CALL sp_create_account(%s, %s, %s, %s)",
                    (f["login"].strip(), f["password"], f["role"], f.get("employee_id") or None))
                flash(f"Обліковий запис {f['login'].strip()} створено", "ok")
            if action in ("lock", "unlock"):
                run("CALL sp_set_account_locked(%s, %s)", (f["login"], action == "lock"))
                flash(f"Обліковий запис {f['login']} " + ("заблоковано" if action == "lock" else "розблоковано"), "ok")
            if action in ("deactivate", "reactivate"):
                active = action == "reactivate"
                run("UPDATE employees SET is_active = %s WHERE employee_id = %s", (active, f["employee_id"]))
                login_row = run("SELECT db_login FROM employees WHERE employee_id = %s", (f["employee_id"],))
                db_login = login_row[0]["db_login"] if login_row else None
                if db_login:   # обліковий запис блокується / розблоковується разом зі статусом
                    run("CALL sp_set_account_locked(%s, %s)", (db_login, not active))
                flash(("Співробітника повернуто на роботу" if active else
                       "Співробітника звільнено. Історія його занять зберігається")
                      + (f"; обліковий запис {db_login} " + ("розблоковано" if active else "заблоковано")
                         if db_login else ""), "ok")
        except DbError as e:
            flash(str(e), "error")
        return redirect(url_for("staff"))

    employees = safe(run, "SELECT e.employee_id, e.full_name, e.role AS position, e.phone, e.hire_date, "
                          "e.experience_years, e.is_active, e.db_login, "
                          "GROUP_CONCAT(c.code ORDER BY c.code SEPARATOR ', ') AS qualifications "
                          "FROM employees e "
                          "LEFT JOIN employee_categories ec ON ec.employee_id = e.employee_id "
                          "LEFT JOIN categories c ON c.category_id = ec.category_id "
                          "GROUP BY e.employee_id ORDER BY e.is_active DESC, e.role, e.full_name")
    accounts = safe(run, "CALL sp_list_accounts()")
    categories = safe(run, "SELECT category_id, code, name FROM categories ORDER BY code")
    free_employees = [e for e in employees if e["is_active"] and not e["db_login"]]
    return page("staff.html", employees=employees, accounts=accounts, categories=categories,
                free_employees=free_employees, today=date.today().isoformat())


if __name__ == "__main__":
    # лише локальний доступ: інтерфейс не відкривається з інших комп'ютерів мережі
    app.run(host="127.0.0.1", port=5000, debug=False)
