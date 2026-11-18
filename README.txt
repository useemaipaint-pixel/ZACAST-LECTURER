ZACAST ATTENDANCE MANAGEMENT SYSTEM  (v3.4 - online)
Zamfara College of Arts, Science and Technology, Gusau

NEW INSTALLATION
1. Supabase > SQL Editor > New query > paste supabase_setup.sql > RUN
   (also removes the older per-lecturer version if it was run before)
2. Open index.html (Chrome) or upload it to any web host.
3. Login: admin / admin123  -> change it in Settings > Change Password.

ALREADY USING ZACAST?  (add COURSES to your existing database)
1. Supabase > SQL Editor > New query > paste supabase_update_courses.sql > RUN
   (it does not delete or change any student, department or attendance)
2. Replace your old index.html with the new one.

COURSES (new)
- Every department has its own courses: Settings > Courses.
- To take attendance you must first choose the course (New Attendance > Course).
- Each course keeps its own attendance, absent list and reports:
  use the "Course" bar on Attendance, Reports and Absent List to switch course.
- Dashboard lists the department's courses with their average attendance; tap one to open it.
- Student profile shows the attendance % of that student for each course ("By Course").
- Old attendances that had a course typed in are linked to a course automatically.

Exam list: Reports > Exam List (set minimum attendance %, print or Excel).
Departments: Settings > Departments (each has its own students, courses and attendance).
Profile photo + name: tap the round picture at the top.

=====================================================================
UPDATE v3.2  (ND I / ND II, AI Mode, search, forgot password)
=====================================================================
ALREADY USING ZACAST?
1. Supabase > SQL Editor > New query > paste supabase_update_levels.sql > RUN (once).
   It does NOT delete anything. Do NOT run supabase_setup.sql again.
   Your present students stay in Computer Science ND II. An empty ND I is added.
2. Replace your old index.html with the new one.
NEW INSTALLATION: run supabase_setup.sql, then supabase_update_courses.sql, then supabase_update_levels.sql.

- LEVELS: every department has ND I (Year 1) and ND II (Year 2). Each has its own
  students, courses and attendance. Adding a department creates both levels.
- AI MODE (nav bar): type a command in English or Hausa, e.g.
  "Find ND II student", "Export all students to PDF",
  "Mark all students in Computer Science ND 1 present", "Delete all students",
  "Add student Aminu Sani, 36201", "How many students in ND I?", "Help".
  Delete and Mark All always ask for confirmation first.
- SEARCH: every student list/picker (Reports, Absent list, Exam list...) has a search box.
- FORGOT PASSWORD: on the login page. Enter the last 3 characters of your password.
  The username and password boxes are now empty until you type.

UPDATE v3.3
- Run supabase_update_semester.sql ONCE (moves existing attendance to Second Semester).
- Departments are listed once; tap a department, then choose ND I or ND II.
- Semester bar (First / Second Semester): attendance, absent list, reports, exam list
  and course averages are separate for each semester.
- AI Mode: trash button (top right) or type "clear chat" to delete the conversation.
- Keyboard no longer hides what you type.

UPDATE v3.4  (left menu, Promote ND I -> ND II + Archive, stronger AI Mode)
ALREADY USING ZACAST?
1. Supabase > SQL Editor > New query > paste supabase_update_promote.sql > RUN (once).
   It does NOT delete or change anything now. Do NOT run supabase_setup.sql again.
2. Replace your old index.html with the new one. Nothing was removed from the app.
NEW INSTALLATION: run supabase_setup.sql, supabase_update_courses.sql,
   supabase_update_levels.sql, supabase_update_semester.sql, then supabase_update_promote.sql.

- LEFT MENU: tap the green menu button (top left) or swipe from the left edge.
  Close it by tapping the dark area, the X, swiping left, or choosing a page.
  It has every page: Dashboard, Students, Attendance, AI Mode, Reports, Courses,
  Departments, Manage/Export Students, Promote ND I -> ND II, Archive, Settings, About, Logout.
  The bottom bar is still there.
- PROMOTE ND I -> ND II (menu / Settings / AI Mode): at the end of the year, one tap moves
  the whole ND I class to ND II. For each department it does everything together
  (if anything fails, nothing changes):
    1. the finishing ND II students are saved in the ARCHIVE (never lost)
    2. every ND I student becomes an ND II student
    3. ND I is left empty for the new intake
  The attendance of both levels is saved inside the archive, then cleared.
  Courses are kept. You can promote ALL departments or one department.
- ARCHIVE: Settings > Archive. Open a class to see/search its students with their
  attendance %, export to PDF or Excel, or delete it.
- AI MODE (stronger): finds students in ALL departments (by name, admission no. or serial
  no., even with small spelling mistakes), adds one or many students (also step by step:
  just type "Add student"), lists with "more", deletes one student, promotes, opens archive.
  Examples: "Find abdulahi" | "Add student Aminu Sani, 36201" |
  "Add Aminu Sani 36201 to Computer Science ND I" |
  "Add students: Aminu Sani, 36201; Bala Musa, 36202" | "Promote ND I to ND II" |
  Hausa: "nemo Aminu", "kara dalibi Aminu Sani, 36201", "mayar da ND I zuwa ND II".
