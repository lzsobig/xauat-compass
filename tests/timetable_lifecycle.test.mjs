import test from 'node:test';
import assert from 'node:assert/strict';

// 模拟 ClassroomManager 与 TimetableEngine 核心逻辑
class MockClassroomManager {
  constructor() {
    this.timetable = { semester: '2026-2027-1', currentWeek: 10, slots: [] };
    this.courses = [];
    this.sessions = [];
    this.lastCommittedTimetable = null;
    this.lastCommittedCourses = null;
  }

  createCourse(name, teacher = '', room = '', semester = '2026-2027-1', source = 'manual') {
    const c = {
      id: 'c-' + Math.random().toString(36).substring(2, 9),
      name,
      teacher,
      room,
      semester,
      source,
      status: 'active'
    };
    this.courses.push(c);
    return c;
  }

  // 1. 解析生成草稿，不影响真实数据
  parseDraft(pdfPayload) {
    if (!pdfPayload || pdfPayload.corrupt) {
      throw new Error('未能从该 PDF 中解析出课程节次');
    }
    return {
      semester: pdfPayload.semester || '2026-2027-1',
      studentName: pdfPayload.studentName || '李振',
      slots: pdfPayload.slots.map(s => ({ ...s, id: 's-' + Math.random() })),
      items: pdfPayload.courses.map(c => ({
        id: 'item-' + Math.random(),
        originalName: c.name,
        editedName: c.name,
        teacher: c.teacher || '',
        room: c.room || '',
        matchedCourseId: null,
        isSelected: true,
        action: 'create'
      })),
      warnings: []
    };
  }

  // 2. 对照现有课程
  reconcileCourses(draft) {
    const draftNames = new Set(draft.items.map(i => i.editedName));
    const newCourses = [];
    const matchedCourses = [];

    for (const item of draft.items) {
      const match = this.courses.find(c => c.name === item.originalName && c.semester === draft.semester);
      if (match) {
        matchedCourses.push({ ...item, matchedCourseId: match.id, action: 'matchExisting' });
      } else {
        newCourses.push(item);
      }
    }

    const coursesToArchive = this.courses.filter(
      c => c.semester === draft.semester && c.source === 'timetable' && c.status === 'active' && !draftNames.has(c.name)
    );

    return { draft, newCourses, matchedCourses, coursesToArchive };
  }

  // 3. 确认提交
  commitImport(draft) {
    // 保存快照
    this.lastCommittedTimetable = JSON.parse(JSON.stringify(this.timetable));
    this.lastCommittedCourses = JSON.parse(JSON.stringify(this.courses));

    const nameToCourseId = new Map();

    for (const item of draft.items) {
      if (!item.isSelected) continue;

      if (item.action === 'matchExisting' && item.matchedCourseId) {
        const existing = this.courses.find(c => c.id === item.matchedCourseId);
        if (existing) {
          if (item.teacher) existing.teacher = item.teacher;
          if (item.room) existing.room = item.room;
          existing.status = 'active';
          nameToCourseId.set(item.editedName, existing.id);
          nameToCourseId.set(item.originalName, existing.id);
        }
      } else {
        const found = this.courses.find(c => c.name === item.editedName && c.semester === draft.semester);
        if (found) {
          found.status = 'active';
          nameToCourseId.set(item.editedName, found.id);
        } else {
          const newC = {
            id: 'c-' + Math.random().toString(36).substring(2, 9),
            name: item.editedName,
            teacher: item.teacher,
            room: item.room,
            semester: draft.semester,
            source: 'timetable',
            status: 'active'
          };
          this.courses.push(newC);
          nameToCourseId.set(item.editedName, newC.id);
          nameToCourseId.set(item.originalName, newC.id);
        }
      }
    }

    // 学期迁移与归档
    if (draft.semester !== this.timetable.semester) {
      for (const c of this.courses) {
        if (c.semester === this.timetable.semester && c.source === 'timetable') {
          c.status = 'historical';
        }
      }
    } else {
      const activeDraftNames = new Set(draft.items.filter(i => i.isSelected).map(i => i.editedName));
      for (const c of this.courses) {
        if (c.semester === draft.semester && c.source === 'timetable' && !activeDraftNames.has(c.name)) {
          c.status = 'historical';
        }
      }
    }

    // 绑定 slots 到 stable courseId
    const committedSlots = draft.slots.map(s => {
      const cId = nameToCourseId.get(s.courseName) || (this.courses.find(c => c.name === s.courseName)?.id);
      return { ...s, courseId: cId, semester: draft.semester };
    });

    this.timetable = {
      semester: draft.semester,
      currentWeek: 10,
      slots: committedSlots
    };
  }

  // 4. 回滚撤销
  rollback() {
    if (!this.lastCommittedTimetable || !this.lastCommittedCourses) return;
    this.timetable = JSON.parse(JSON.stringify(this.lastCommittedTimetable));
    this.courses = JSON.parse(JSON.stringify(this.lastCommittedCourses));
    this.lastCommittedTimetable = null;
    this.lastCommittedCourses = null;
  }

  // 5. 双层删除
  deleteCourse(courseId, purgeAllData = false) {
    const course = this.courses.find(c => c.id === courseId);
    if (!course) return;

    this.courses = this.courses.filter(c => c.id !== courseId);

    if (purgeAllData) {
      this.sessions = this.sessions.filter(s => s.courseId !== courseId);
    } else {
      for (const s of this.sessions) {
        if (s.courseId === courseId) {
          s.courseId = null; // 安全移入未归档
        }
      }
    }
  }
}

test('1. 同一 PDF 连续导入三次不产生重复文件夹', () => {
  const mgr = new MockClassroomManager();
  const pdfData = {
    semester: '2026-2027-1',
    courses: [
      { name: '高等数学', teacher: '张老师', room: '1-101' },
      { name: '大学物理', teacher: '李老师', room: '2-202' }
    ],
    slots: [
      { courseName: '高等数学', day: 1, fromPeriod: 1, toPeriod: 2 },
      { courseName: '大学物理', day: 2, fromPeriod: 3, toPeriod: 4 }
    ]
  };

  for (let i = 0; i < 3; i++) {
    const draft = mgr.parseDraft(pdfData);
    const plan = mgr.reconcileCourses(draft);
    for (const item of draft.items) {
      const match = plan.matchedCourses.find(m => m.originalName === item.originalName);
      if (match) item.action = 'matchExisting', item.matchedCourseId = match.matchedCourseId;
    }
    mgr.commitImport(draft);
  }

  assert.equal(mgr.courses.length, 2, '三次导入后依然只有两门课，无重复文件夹');
  assert.equal(mgr.timetable.slots.length, 2);
});

test('2. 新课表比旧课表多两门课，只新增这两门', () => {
  const mgr = new MockClassroomManager();
  const pdf1 = {
    semester: '2026-2027-1',
    courses: [{ name: '线性代数' }],
    slots: [{ courseName: '线性代数', day: 1, fromPeriod: 1, toPeriod: 2 }]
  };
  const draft1 = mgr.parseDraft(pdf1);
  mgr.commitImport(draft1);
  const mathId = mgr.courses[0].id;

  const pdf2 = {
    semester: '2026-2027-1',
    courses: [{ name: '线性代数' }, { name: 'Python程序设计' }, { name: '工程制图' }],
    slots: [
      { courseName: '线性代数', day: 1, fromPeriod: 1, toPeriod: 2 },
      { courseName: 'Python程序设计', day: 2, fromPeriod: 1, toPeriod: 2 },
      { courseName: '工程制图', day: 3, fromPeriod: 1, toPeriod: 2 }
    ]
  };
  const draft2 = mgr.parseDraft(pdf2);
  const plan2 = mgr.reconcileCourses(draft2);
  assert.equal(plan2.matchedCourses.length, 1);
  assert.equal(plan2.newCourses.length, 2);

  for (const item of draft2.items) {
    const match = plan2.matchedCourses.find(m => m.originalName === item.originalName);
    if (match) item.action = 'matchExisting', item.matchedCourseId = match.matchedCourseId;
  }
  mgr.commitImport(draft2);

  assert.equal(mgr.courses.length, 3);
  assert.equal(mgr.courses.find(c => c.name === '线性代数').id, mathId, '原有课程复用 ID');
});

test('3. 旧课表中的课程消失，但原有课堂资料仍在历史课程', () => {
  const mgr = new MockClassroomManager();
  const draft1 = mgr.parseDraft({
    semester: '2026-2027-1',
    courses: [{ name: '已结课课程' }, { name: '正在上课' }],
    slots: [{ courseName: '已结课课程' }, { courseName: '正在上课' }]
  });
  mgr.commitImport(draft1);

  const oldCourse = mgr.courses.find(c => c.name === '已结课课程');
  mgr.sessions.push({ id: 's1', courseId: oldCourse.id, title: '结课记录第1讲' });

  // 导入新课表（已结课课程不再存在）
  const draft2 = mgr.parseDraft({
    semester: '2026-2027-1',
    courses: [{ name: '正在上课' }],
    slots: [{ courseName: '正在上课' }]
  });
  const plan2 = mgr.reconcileCourses(draft2);
  assert.equal(plan2.coursesToArchive.length, 1);
  assert.equal(plan2.coursesToArchive[0].name, '已结课课程');

  mgr.commitImport(draft2);

  assert.equal(oldCourse.status, 'historical', '自动转为历史课程');
  assert.equal(mgr.sessions[0].courseId, oldCourse.id, '原有课堂资料完好归档');
});

test('4. 识别错误的课程名称可以在导入前修正', () => {
  const mgr = new MockClassroomManager();
  const draft = mgr.parseDraft({
    semester: '2026-2027-1',
    courses: [{ name: '材料力字' }], // 错别字
    slots: [{ courseName: '材料力字', day: 1, fromPeriod: 1, toPeriod: 2 }]
  });

  // 用户在预览页修正为 材料力学
  draft.items[0].editedName = '材料力学';
  mgr.commitImport(draft);

  assert.equal(mgr.courses.length, 1);
  assert.equal(mgr.courses[0].name, '材料力学', '成功入库修正后的名称');
  assert.equal(mgr.timetable.slots[0].courseId, mgr.courses[0].id);
});

test('5. 错误课表导入后可以撤销并恢复', () => {
  const mgr = new MockClassroomManager();
  const goodDraft = mgr.parseDraft({
    semester: '2026-2027-1',
    courses: [{ name: '正确课程A' }],
    slots: [{ courseName: '正确课程A' }]
  });
  mgr.commitImport(goodDraft);
  assert.equal(mgr.courses[0].name, '正确课程A');

  // 误导入错误课表
  const badDraft = mgr.parseDraft({
    semester: '2026-2027-1',
    courses: [{ name: '垃圾课程X' }],
    slots: [{ courseName: '垃圾课程X' }]
  });
  mgr.commitImport(badDraft);
  assert.equal(mgr.timetable.slots[0].courseName, '垃圾课程X');

  // 撤销回滚
  mgr.rollback();
  assert.equal(mgr.timetable.slots[0].courseName, '正确课程A');
  assert.equal(mgr.courses[0].name, '正确课程A');
});

test('6. 删除空课程文件夹不影响其他课程', () => {
  const mgr = new MockClassroomManager();
  const c1 = mgr.createCourse('空课程1');
  const c2 = mgr.createCourse('正常课程2');

  mgr.deleteCourse(c1.id, false);
  assert.equal(mgr.courses.length, 1);
  assert.equal(mgr.courses[0].id, c2.id);
});

test('7. 删除有课堂资料的文件夹后，原有记录进入未归档', () => {
  const mgr = new MockClassroomManager();
  const c = mgr.createCourse('要删除的文件夹');
  mgr.sessions.push({ id: 's1', courseId: c.id, title: '录音1' });
  mgr.sessions.push({ id: 's2', courseId: c.id, title: '录音2' });

  // 仅删除文件夹
  mgr.deleteCourse(c.id, false);

  assert.equal(mgr.courses.length, 0);
  assert.equal(mgr.sessions.length, 2, '录音绝不丢失');
  assert.equal(mgr.sessions[0].courseId, null, '安全移入未归档');
  assert.equal(mgr.sessions[1].courseId, null, '安全移入未归档');
});

test('8. 搜索过滤后滑动删除不会删除错误对象 (通过目标实例 ID 精确删除)', () => {
  const mgr = new MockClassroomManager();
  const c1 = mgr.createCourse('建筑工程A');
  const c2 = mgr.createCourse('软件测试B');
  const c3 = mgr.createCourse('建筑工程C');

  // 用户搜索 "建筑"，筛选出 [c1, c3]
  const filtered = mgr.courses.filter(c => c.name.includes('建筑'));
  // 用户在 filtered[1] (即 c3) 点击删除
  const targetToDelete = filtered[1];

  mgr.deleteCourse(targetToDelete.id, false);

  assert.equal(mgr.courses.find(c => c.id === c3.id), undefined);
  assert.notEqual(mgr.courses.find(c => c.id === c1.id), undefined, 'c1 绝未误删');
  assert.notEqual(mgr.courses.find(c => c.id === c2.id), undefined, 'c2 绝未误删');
});

test('9. 课程改名、教室变更后，课堂记录仍正确归档 (基于稳定 courseId)', () => {
  const mgr = new MockClassroomManager();
  const c = mgr.createCourse('旧课程名', '旧老师', '旧教室');
  mgr.sessions.push({ id: 's1', courseId: c.id, title: '第1次上课' });

  // 课程改名并更换教室
  c.name = '新课程名（更精确）';
  c.room = '草堂新校区8-101';

  const session = mgr.sessions[0];
  const associatedCourse = mgr.courses.find(item => item.id === session.courseId);
  assert.equal(associatedCourse.name, '新课程名（更精确）', '通过 courseId 稳定关联新名称');
  assert.equal(associatedCourse.room, '草堂新校区8-101');
});

test('10. PDF 解析失败时，现有数据完全不变', () => {
  const mgr = new MockClassroomManager();
  const draft = mgr.parseDraft({
    semester: '2026-2027-1',
    courses: [{ name: '稳定课程' }],
    slots: [{ courseName: '稳定课程' }]
  });
  mgr.commitImport(draft);

  const snapshotCourses = JSON.stringify(mgr.courses);
  const snapshotTT = JSON.stringify(mgr.timetable);

  assert.throws(() => {
    mgr.parseDraft({ corrupt: true });
  }, /未能从该 PDF 中解析出课程节次/);

  assert.equal(JSON.stringify(mgr.courses), snapshotCourses, '课程数据丝毫未变');
  assert.equal(JSON.stringify(mgr.timetable), snapshotTT, '课表数据丝毫未变');
});
