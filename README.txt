ZACAST ATTENDANCE MANAGEMENT SYSTEM  (v3.1 - online)
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
