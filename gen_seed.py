"""Генератор 04_seed.sql: детерміновані правдоподібні дані, що проходять усі тригери."""
import random
from datetime import date, datetime, timedelta

random.seed(2026)
TODAY = date(2026, 11, 4)          # "сьогодні" для даних: до цієї дати - проведені заняття
HORIZON = date(2026, 11, 18)       # практику бронюють максимум на 2 тижні вперед
out = []
w = out.append

def q(v):
    if v is None: return 'NULL'
    if isinstance(v, bool): return 'TRUE' if v else 'FALSE'
    if isinstance(v, (int, float)): return str(v)
    if isinstance(v, datetime): return "'" + v.strftime('%Y-%m-%d %H:%M') + "'"
    if isinstance(v, date): return "'" + v.isoformat() + "'"
    return "'" + str(v).replace("'", "''") + "'"

def insert(table, cols, rows, comment=None):
    if not rows: return
    if comment: w(f"-- {comment}")
    w(f"INSERT INTO {table} ({', '.join(cols)}) VALUES")
    w(",\n".join("  (" + ", ".join(q(v) for v in r) + ")" for r in rows) + ";\n")

# ------------------------------------------------------------------ довідники
w("""-- =====================================================================
-- Файл 4: тестові дані (seed)
-- Завантажувати ПІСЛЯ 01, 02, 03: усі дані проходять перевірки тригерів.
-- Дані згенеровано детерміновано; «сьогодні» для даних = 04.11.2026:
-- заняття до цієї дати проведені, після - заплановані (на 2 тижні вперед).
-- Ідентифікатори задано явно, щоб на них можна було посилатися в прикладах.
-- =====================================================================
SET NAMES utf8mb4;
USE driving_school;
""")
insert('enrollment_statuses', ['status_id','code','name','is_system'], [
    (1,'studying','Навчається',True),(2,'graduated','Закінчив навчання',True),
    (3,'expelled','Відрахований',True),(4,'leave','Академвідпустка',True)],
    "Системні статуси: логіка спирається на code, is_system захищає від видалення")
insert('document_types', ['document_type_id','code','name'], [
    (1,'passport','Паспорт громадянина України'),(2,'medical','Медична довідка водія (форма 083/о)'),
    (3,'tax_id','Реєстраційний номер облікової картки платника податків')],
    "code = 'medical' використовується в перевірці допуску до практики")
insert('exam_types', ['exam_type_id','code','name','pass_score'], [
    (1,'internal_theory','Внутрішній іспит з теорії',90),
    (2,'internal_practice','Внутрішній іспит з практичного водіння',None),
    (3,'final','Підсумковий іспит',None)],
    "pass_score = NULL -> залік (результат вказує екзаменатор)")
insert('payment_methods', ['method_id','name'], [(1,'Готівка'),(2,'Банківська картка'),(3,'Безготівковий переказ')])

CATS = {1:('B','Легкові автомобілі',14500,60,40), 2:('A','Мотоцикли',9000,40,20), 3:('C','Вантажні автомобілі',22000,70,50)}
insert('categories', ['category_id','code','name','price','theory_hours_min','practice_hours_min'],
       [(k,)+v for k,v in CATS.items()])

# ------------------------------------------------------------------ співробітники
EMP = [  # id, ПІБ, роль, дата прийняття, стаж, категорії
 (1,'Ковальчук Ірина Петрівна','teacher','2018-02-01',12,[1,2]),
 (2,'Мельник Олег Вікторович','teacher','2019-09-01',9,[1,3]),
 (3,'Шевчук Наталія Андріївна','teacher','2022-01-10',4,[1]),
 (4,'Бондаренко Сергій Іванович','instructor','2016-03-01',15,[1]),
 (5,'Ткаченко Андрій Миколайович','instructor','2017-05-15',11,[1]),
 (6,'Кравченко Віталій Олегович','instructor','2020-08-01',7,[1]),
 (7,'Олійник Петро Степанович','instructor','2015-04-01',20,[1]),     # звільниться після літа
 (8,'Савченко Дмитро Юрійович','instructor','2019-03-11',8,[2,1]),
 (9,'Руденко Василь Петрович','instructor','2014-06-02',22,[3,1]),
]
insert('employees', ['employee_id','full_name','phone','role','hire_date','experience_years'],
       [(e[0],e[1],f'+38067{1000000+e[0]*7919:07d}',e[2],e[3],e[4]) for e in EMP])
qual=[]
for e in EMP:
    for c in e[5]:
        qual.append((e[0],c,date.fromisoformat(e[3])+timedelta(days=30),None))
qual = [(4,1,date(2016,4,1),date(2029,4,1)) if x[0]==4 else x for x in qual]
insert('employee_categories',['employee_id','category_id','granted_date','valid_until'],qual)

# ------------------------------------------------------------------ автомобілі
VEH = [  # id, номер, марка, модель, рік, КПП, кат, інструктор, ТО
 (1,'AA1234KX','Skoda','Fabia',2021,'manual',1,4,date(2026,11,15)),   # ТО скоро
 (2,'AA5678KX','Renault','Logan',2020,'manual',1,5,date(2027,3,1)),
 (3,'AA9012KX','Toyota','Yaris',2022,'automatic',1,6,date(2027,5,20)),
 (4,'AA3456KX','Volkswagen','Polo',2019,'manual',1,7,date(2027,1,10)), # переходить до інструктора 5
 (5,'AA7788KX','Honda','CB500F',2021,'manual',2,8,date(2027,4,1)),
 (6,'AA2211KX','MAN','TGL 8.180',2018,'manual',3,9,date(2026,11,28)),  # ТО протягом місяця
 (7,'AA4455KX','Skoda','Rapid',2023,'manual',1,8,date(2027,6,1)),
 (8,'AA0099KX','Hyundai','Accent',2012,'manual',1,None,date(2026,9,1)),# списаний
]
insert('vehicles',['vehicle_id','plate_number','make','model','production_year','transmission',
                   'category_id','default_instructor_id','next_service_date'],[v for v in VEH])
veh_by_id={v[0]:v for v in VEH}

# ------------------------------------------------------------------ групи
GROUPS = [  # id, назва, кат, старт, кінець, зміна, макс, викладач, дні теорії, час теорії
 (1,'B-2026-05-В',1,date(2026,5,4),date(2026,8,28),'evening',12,1,(0,2),18),
 (2,'B-2026-09-В',1,date(2026,9,7),date(2026,12,25),'evening',12,1,(0,2),18),
 (3,'B-2026-09-Р',1,date(2026,9,14),date(2027,1,15),'morning',10,3,(1,3),9),
 (4,'A-2026-10-В',2,date(2026,10,5),date(2026,12,18),'evening',8,1,(1,3),18),
 (5,'C-2026-10-Р',3,date(2026,10,12),date(2027,2,26),'morning',6,2,(0,4),9),
 (6,'B-2026-12-В',1,date(2026,12,1),date(2027,3,31),'evening',12,3,(0,2),18),
]
insert('study_groups',['group_id','name','category_id','start_date','end_date','shift','max_students'],
       [g[:7] for g in GROUPS])
grp={g[0]:g for g in GROUPS}

# ------------------------------------------------------------------ курсанти
M_FIRST=['Олександр','Дмитро','Максим','Андрій','Іван','Богдан','Артем','Назар','Владислав','Тарас','Юрій','Роман','Степан','Михайло','Олег']
F_FIRST=['Анна','Марія','Олена','Катерина','Юлія','Вікторія','Ірина','Софія','Дарина','Христина']
SURN=['Шевченко','Бойко','Коваленко','Ткачук','Мороз','Лисенко','Поліщук','Гончаренко','Захарченко','Петренко',
      'Кузьменко','Онищенко','Остапенко','Пономаренко','Романюк','Литвиненко','Марченко','Костенко','Сидоренко','Федорчук',
      'Гаврилюк','Дорошенко','Ярошенко','Білик','Головко','Демченко','Іваненко','Клименко','Левченко','Нестеренко',
      'Павлюк','Савчук','Тимошенко','Усенко','Харченко','Цимбал','Чорновол','Юрченко','Яковенко','Вовк']
M_PAT=['Олександрович','Іванович','Петрович','Сергійович','Миколайович','Андрійович','Васильович','Юрійович']
F_PAT=['Олександрівна','Іванівна','Петрівна','Сергіївна','Миколаївна','Андріївна','Василівна','Юріївна']
def fem(s):
    return s if s.endswith(('ко','ук','юк','ик','ол','вк','бал')) or s in ('Мороз','Вовк') else s[:-2]+'ка' if s.endswith('ий') else s
STREETS=['вул. Хрещатик','вул. Січових Стрільців','просп. Перемоги','вул. Лук\'янівська','вул. Велика Васильківська','вул. Антоновича','просп. Бандери']

# розподіл курсантів по групах: (група, кількість)
plan=[(1,10),(2,9),(3,8),(4,5),(5,4),(6,4)]
students=[]; enrolls=[]
sid=0
for gid,n in plan:
    for _ in range(n):
        sid+=1
        female = random.random()<0.35
        sur = SURN[sid-1]
        name = (fem(sur) if female else sur)+' '+random.choice(F_FIRST if female else M_FIRST)+' '+random.choice(F_PAT if female else M_PAT)
        g=grp[gid]
        reg = min(g[3], TODAY)-timedelta(days=random.randint(5,25))   # реєстрація не в майбутньому
        bd = date(random.randint(1976,2006),random.randint(1,12),random.randint(1,28))
        email = f'student{sid:02d}@ukr.net' if random.random()<0.8 else None
        students.append((sid,name,bd,f'+38050{2000000+sid*104729 % 9000000:07d}',email,
                         f'м. Київ, {random.choice(STREETS)}, {random.randint(1,150)}',reg))
        enrolls.append([sid,sid,gid,min(g[3]-timedelta(days=random.randint(0,4)), TODAY-timedelta(days=random.randint(1,4))),None,None])
# друге зарахування: випускник групи B-2026-05 вчиться на категорію A
enrolls.append([41,3,4,date(2026,10,2),8100,'Знижка 10% для випускників'])
for e in enrolls:
    if e[4] is None:
        price = CATS[grp[e[2]][2]][2]
        if random.random()<0.2: e[4]=round(price*0.9,2); e[5]='Знижка 10% (студент)'
        else: e[4]=price
insert('students',['student_id','full_name','birth_date','phone','email','address','registered_at'],students)

# ------------------------------------------------------------------ документи
# особливі випадки для звітів:
NO_MED   = {22}            # без медичної довідки взагалі (група B-2026-09-Р)
MED_EXP  = {13: date(2026,10,20)}   # довідка спливла 20.10 (група B-2026-09-В)
MED_SOON = {15: date(2026,11,20), 25: date(2026,11,30)}  # спливає найближчим часом
docs=[]; did=0; med_valid={}
for s in students:
    sid_=s[0]; did+=1
    docs.append((did,sid_,1,f'{random.randint(100000000,999999999)}',date(random.randint(2016,2024),random.randint(1,12),10),None))
    if sid_ in NO_MED: continue
    issue = s[6]-timedelta(days=random.randint(3,60))
    valid = MED_EXP.get(sid_) or MED_SOON.get(sid_) or issue.replace(year=issue.year+3)
    if sid_ in MED_EXP: issue=date(2023,10,21)
    if sid_ in MED_SOON: issue=valid.replace(year=valid.year-3)
    did+=1
    docs.append((did,sid_,2,f'083/о-{random.randint(10000,99999)}',issue,valid))
    med_valid[sid_]=(issue,valid)
    if random.random()<0.6:
        did+=1; docs.append((did,sid_,3,f'{random.randint(1000000000,9999999999)}',date(2010,1,1)+timedelta(days=random.randint(0,4000)),None))
insert('documents',['document_id','student_id','document_type_id','number','issue_date','valid_until'],docs)

insert('enrollments',['enrollment_id','student_id','group_id','enrolled_on','agreed_price','discount_note'],
       [tuple(e) for e in enrolls], "status_id не вказано: тригер підставляє 'studying' за кодом")
enr={e[0]:e for e in enrolls}

# ------------------------------------------------------------------ теоретичні заняття
TOPICS=['Загальні положення ПДР','Обов\'язки і права водіїв','Дорожні знаки: попереджувальні','Дорожні знаки: заборонні',
 'Дорожні знаки: наказові','Дорожня розмітка','Сигнали світлофора','Регулювальник','Початок руху і маневрування',
 'Розташування на проїзній частині','Швидкість руху','Обгін','Зупинка і стоянка','Проїзд перехресть','Пішохідні переходи',
 'Залізничні переїзди','Перевезення пасажирів','Буксирування','Рух у темну пору доби','Рух автомагістралями',
 'Основи безпеки руху','Будова автомобіля: двигун','Будова автомобіля: трансмісія','Гальмівна система',
 'Технічний стан ТЗ','Перша медична допомога','Перша допомога: кровотечі','Відповідальність водіїв','Страхування ОСЦПВ',
 'Підготовка до іспиту','Розбір типових помилок','Контрольне тестування']
HOLIDAYS={date(2026,8,24),date(2026,10,14)}
theory=[]; tid=0; theory_busy={}   # (student, date) -> (start,end) для заборони накладок
for g in GROUPS:
    gid,_,cat,st,en,_,_,teacher,days,hour=g
    d=st; n=0
    while d<=en and n<len(TOPICS):
        if d.weekday() in days:
            tid+=1; n+=1
            s_at=datetime(d.year,d.month,d.day,hour)
            status = 'cancelled' if d in HOLIDAYS else ('done' if d<TODAY else 'planned')
            theory.append((tid,gid,teacher,s_at,2.0,TOPICS[n-1] if status!='cancelled' else TOPICS[n-1]+' (скасовано: святковий день)',status))
            if status=='cancelled': n-=1
        d+=timedelta(days=1)
insert('theory_lessons',['lesson_id','group_id','teacher_id','starts_at','duration_hours','topic','status'],theory)
theory_by_group={}
for t in theory:
    if t[6]!='cancelled': theory_by_group.setdefault(t[1],[]).append(t)

# ------------------------------------------------------------------ спеціальні сценарії зарахувань
EXPELLED = {7: date(2026,6,22)}     # відрахований у червні (є повернення коштів)
LEAVE    = {16: date(2026,10,5)}    # академвідпустка з 05.10
WEAK_ATT = {12, 26}                 # часто пропускають теорію -> не набирають годин
def active_until(eid):
    e=enr[eid]
    return EXPELLED.get(eid) or LEAVE.get(eid) or grp[e[2]][4]

att=[]
for gid,lessons in theory_by_group.items():
    for t in lessons:
        if t[6]!='done': continue
        for e in enrolls:
            if e[2]!=gid or t[3].date()<e[3] or t[3].date()>active_until(e[0]): continue
            p_present = 0.6 if e[0] in WEAK_ATT else 0.92
            if random.random()<p_present: att.append((t[0],e[0],True,None))
            else: att.append((t[0],e[0],False,random.choices(['illness','excused','unexcused'],[3,2,2])[0]))
# Узгодженість: курсанти завершеної групи, допущені до іспитів, мають набрати мінімум теорії
# (60 год = 30 занять). Найраніші пропуски без поважної причини / поважні - відпрацьовані.
for e in enrolls:
    if e[2]!=1 or e[0] in EXPELLED: continue
    mine=[i for i,a_ in enumerate(att) if a_[1]==e[0]]
    present=sum(1 for i in mine if att[i][2])
    for i in mine:
        if present>=30: break
        if not att[i][2]: att[i]=(att[i][0],att[i][1],True,None); present+=1
insert('theory_attendance',['lesson_id','enrollment_id','present','absence_reason'],att)

# ------------------------------------------------------------------ практичні заняття (з урахуванням усіх правил тригера)
instr_for_cat={1:[4,5,6,7],2:[8],3:[9]}
assigned={}
for e in enrolls:
    cat=grp[e[2]][2]
    pool=instr_for_cat[cat]
    if cat==1 and grp[e[2]][3]>date(2026,8,31): pool=[4,5,6]   # інструктор 7 звільнився наприкінці серпня
    assigned[e[0]]=pool[e[0]%len(pool)]
instr_default_vehicle={4:1,5:2,6:3,7:4,8:5,9:6}
busy_instr={}; busy_veh={}; busy_stud={}; instr_hours={}
SLOTS=[7,9,11,13,15,17,19]
def overlaps(lst,a,b): return any(x<b and a<y for x,y in lst)
def theory_conflict(sid_,a,b):
    for e in enrolls:
        if e[1]!=sid_: continue
        for t in theory_by_group.get(e[2],[]):
            ts=t[3]; te=ts+timedelta(hours=t[4])
            if ts<b and a<te: return True
    return False
practice=[]; pid=0
target={1:20,2:10,3:25}   # кількість 2-годинних занять для повного курсу
for e in sorted(enrolls,key=lambda x:x[3]):
    eid,sid_,gid=e[0],e[1],e[2]; g=grp[gid]; cat=g[2]
    if sid_ not in med_valid: continue                      # без меддовідки практика неможлива
    instr=assigned[eid]
    need=target[cat]-(4 if eid in WEAK_ATT else 0)
    d=max(g[3],e[3])+timedelta(days=14)                     # практика з 3-го тижня навчання
    last=min(active_until(eid),HORIZON,g[4]); cnt=0
    while d<=last and cnt<need:
        if d.weekday()<6 and random.random()<0.42 and med_valid[sid_][0]<=d<=med_valid[sid_][1]:
            for h in random.sample(SLOTS,len(SLOTS)):
                a=datetime(d.year,d.month,d.day,h); b=a+timedelta(hours=2)
                if instr_hours.get((instr,d),0)+2>8: break
                if overlaps(busy_instr.get(instr,[]),a,b) or (sid_,d) in busy_stud or theory_conflict(sid_,a,b): continue
                veh=None
                for v in [instr_default_vehicle[instr]]+[x[0] for x in VEH if x[6]==cat]:
                    vv=veh_by_id[v]
                    if v!=8 and vv[8]>=d and not overlaps(busy_veh.get(v,[]),a,b): veh=v; break
                if veh is None: continue
                if d<TODAY: status='missed' if random.random()<0.06 else 'done'
                else: status='planned'
                pid+=1; practice.append((pid,eid,instr,veh,a,2.0,status))
                busy_instr.setdefault(instr,[]).append((a,b)); busy_veh.setdefault(veh,[]).append((a,b))
                busy_stud[(sid_,d)]=1; instr_hours[(instr,d)]=instr_hours.get((instr,d),0)+2
                if status!='missed': cnt+=1
                break
        d+=timedelta(days=1)
# заміна інструктора: 2 заняття курсанта інструктора 4 провів інструктор 5 (на авто інструктора 4)
insert('practice_lessons',['lesson_id','enrollment_id','instructor_id','vehicle_id','starts_at','duration_hours','status'],practice)

# ------------------------------------------------------------------ іспити (лише завершена група 1)
exams=[]; xid=0; graduated=[]
for e in enrolls:
    if e[2]!=1 or e[0] in EXPELLED: continue
    d0=date(2026,8,17)
    # теорія: бал; деякі складають з 2-ї спроби
    first = random.choice([96,92,90,85,95,100,88,93,97,91])
    xid+=1; exams.append((xid,e[0],1,d0,first,None))
    if first<90: xid+=1; exams.append((xid,e[0],1,d0+timedelta(days=3),random.choice([92,94,96]),None))
    # практика: залік
    ok = random.random()<0.8
    xid+=1; exams.append((xid,e[0],2,date(2026,8,21),None,ok))
    if not ok: xid+=1; exams.append((xid,e[0],2,date(2026,8,25),None,True))
    xid+=1; exams.append((xid,e[0],3,date(2026,8,27),None,e[0]!=10))
    if e[0]!=10: graduated.append(e[0])
w("-- Іспити: для бального (теорія) passed обчислює тригер, для заліку вказано явно")
w("INSERT INTO exams (exam_id, enrollment_id, exam_type_id, exam_date, score, passed) VALUES")
w(",\n".join(f"  ({x[0]}, {x[1]}, {x[2]}, {q(x[3])}, {q(x[4])}, {q(x[5]) if x[5] is not None else 'NULL'})" for x in exams)+";\n")

# ------------------------------------------------------------------ платежі
pays=[]; payid=0
for e in enrolls:
    eid,price=e[0],e[4]; g=grp[e[2]]
    if g[0]==1: parts=[0.5,0.5] if eid not in EXPELLED else [0.5]
    elif g[0]==6: parts=[0.3] if eid%2 else []
    else: parts=random.choice([[0.5],[0.5,0.25],[1.0],[0.3,0.3],[0.5,0.5]])
    d=e[3]
    for i,pt in enumerate(parts):
        if d+timedelta(days=30*i) >= TODAY: break     # платежів у майбутньому немає
        payid+=1
        pays.append((payid,eid,'payment',round(price*pt,2),datetime(d.year,d.month,d.day,10+i)+timedelta(days=30*i),random.choice([1,2,2,3]),None))
# повернення коштів відрахованому (частина невикористаної оплати)
for eid,dexp in EXPELLED.items():
    payid+=1; pays.append((payid,eid,'refund',3000.00,datetime(dexp.year,dexp.month,dexp.day,15),3,'Повернення при відрахуванні (заява від '+dexp.strftime('%d.%m.%Y')+')'))
insert('payments',['payment_id','enrollment_id','kind','amount','paid_at','method_id','note'],pays)

# ------------------------------------------------------------------ зміни стану після подій
w("""-- ---------------------------------------------------------------------
-- Події, що відбулися після проведених занять
-- ---------------------------------------------------------------------
-- Інструктор Олійник звільнився наприкінці серпня: історія його занять зберігається,
-- закріплене за ним авто переходить до інструктора Ткаченка
UPDATE employees SET is_active = FALSE WHERE employee_id = 7;
UPDATE vehicles  SET default_instructor_id = 5 WHERE vehicle_id = 4;
-- Списаний автомобіль
UPDATE vehicles  SET is_active = FALSE WHERE vehicle_id = 8;
""")
w("-- Статуси зарахувань (за кодом статусу, а не за числом)")
w(f"UPDATE enrollments SET status_id = (SELECT status_id FROM enrollment_statuses WHERE code = 'graduated')\n WHERE enrollment_id IN ({', '.join(map(str,graduated))});")
w(f"UPDATE enrollments SET status_id = (SELECT status_id FROM enrollment_statuses WHERE code = 'expelled')\n WHERE enrollment_id IN ({', '.join(map(str,EXPELLED))});")
w(f"UPDATE enrollments SET status_id = (SELECT status_id FROM enrollment_statuses WHERE code = 'leave')\n WHERE enrollment_id IN ({', '.join(map(str,LEAVE))});")
w("-- Курсант enrollment_id = 10 не склав підсумковий іспит і продовжує навчання (статус 'studying')\n")

w(f"""-- Підсумок: {len(students)} курсантів, {len(enrolls)} зарахувань, {len(theory)} теоретичних занять,
-- {len(att)} відміток відвідуваності, {len(practice)} практичних занять, {len(exams)} іспитів, {len(pays)} платежів""")
open('04_seed.sql','w',encoding='utf-8').write("\n".join(out)+"\n")
print(len(students),len(enrolls),len(theory),len(att),len(practice),len(exams),len(pays))
