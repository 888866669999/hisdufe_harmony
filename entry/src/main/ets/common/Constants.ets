/*
 * 全局常量：域名、接口路径、断点、日志域
 */

/** hilog 域与标签 */
export const LOG_DOMAIN: number = 0x1024;
export const LOG_TAG: string = 'SdufeJw';

/** 教务系统基地址（山东财经大学） */
export const BASE_ORIGIN: string = 'http://jw.sdufe.edu.cn';

/** 登录相关 */
export const PATH_CAPTCHA: string = '/verifycode.servlet';
export const PATH_LOGON: string = '/Logon.do?method=logon';
export const PATH_LOGON_SESS: string = '/Logon.do?method=logon&flag=sess';
export const PATH_LOGOUT: string = '/Logon.do?method=logout';
export const PATH_MAIN: string = '/jsxsd/framework/xsMain.jsp';

/** 业务页面 */
export const PATH_TIMETABLE: string = '/jsxsd/xskb/xskb_list.do';
export const PATH_SCORE_LIST: string = '/jsxsd/kscj/cjcx_list';
export const PATH_PROFILE: string = '/jsxsd/grxx/xsxx';
export const PATH_WEEK_CALENDAR: string = '/jsxsd/jxzl/jxzl_query';
/** 培养方案明细（含培养方案 PDF 附件） */
export const PATH_PLAN_DETAIL: string = '/jsxsd/pyfa/topyfamx';
/** 通选课修读情况 */
export const PATH_ELECTIVE: string = '/jsxsd/xxwcqk/xstxkxdqk.do';

/**
 * 用户自录的「通选课各大类要求学分」。
 *
 * 学校页面的「要求学分（大于等于）」一列是空的，用户可按培养方案自行录入，
 * 见 ElectiveRequirementStore。按账号分片存储。
 */
export const KEY_ELECTIVE_REQUIRED: string = 'elective_required';

/** 全校性教室课表（空教室查询的数据源） */
export const PATH_CLASSROOM: string = '/jsxsd/kbcx/kbxx_classroom';
/** 教室查询结果（HTML 片段） */
export const PATH_CLASSROOM_IFR: string = '/jsxsd/kbcx/kbxx_classroom_ifr';
/** 按校区取教学楼列表（返回 JSON 数组） */
export const PATH_BUILDINGS: string = '/jsxsd/kbcx/getJxlByAjax';

/** 响应式断点（vp） */
export const BP_MEDIUM: number = 600;
export const BP_LARGE: number = 840;

/** 请求超时（ms） */
export const HTTP_CONNECT_TIMEOUT: number = 10000;
export const HTTP_READ_TIMEOUT: number = 15000;

/** 节次定义：与教务课表行一一对应
 *
 * 时刻取自学校官方的「日常教学时刻表」
 * （https://www.sdufe.edu.cn/xyfw/zxxl.htm），而非教务课表页面 ——
 * 课表页面只给节次名称、不给时刻。
 * 官方值同样内置在 data/AcademicCalendar.ets，两处保持一致；
 * 用户仍可在设置里按实际作息调整（存 preferences）。
 */
export interface SectionDef {
  index: number;
  label: string;
  start: string;
  end: string;
}

export const SECTIONS: SectionDef[] = [
  { index: 0, label: '第一、二节', start: '08:30', end: '10:00' },
  { index: 1, label: '第三、四节', start: '10:20', end: '11:50' },
  { index: 2, label: '第五、六节', start: '14:00', end: '15:30' },
  { index: 3, label: '第七、八节', start: '15:50', end: '17:20' },
  { index: 4, label: '第九~十一节', start: '18:40', end: '21:05' }
];

/** 星期标签 */
export const WEEKDAY_LABELS: string[] = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];

/** preferences 存储键 */
export const PREF_STORE: string = 'sdufe_jw_pref';
export const KEY_COOKIE: string = 'session_cookie';
export const KEY_ACCOUNT: string = 'remembered_account';
export const KEY_REMEMBER: string = 'remember_account';
export const KEY_LAST_SEMESTER: string = 'last_semester';
export const KEY_THEME: string = 'theme_mode';
/** 学期第 1 周周一的日期，格式 YYYY-MM-DD，由用户在设置里填写 */
export const KEY_SEMESTER_START: string = 'semester_start_monday';
/** 上次与系统时间对齐周次的时刻（毫秒时间戳） */
export const KEY_WEEK_ALIGN_AT: string = 'week_align_at';
/** 上次对齐得到的周次 */
export const KEY_WEEK_ALIGN_VALUE: string = 'week_align_value';
/** 上次选择周次（课表），空串表示「全部」 */
export const KEY_LAST_WEEK: string = 'last_timetable_week';
/** 上次选择成绩学期 */
export const KEY_LAST_SCORE_SEMESTER: string = 'last_score_semester';
/**
 * 桌面卡片的数据快照。
 *
 * 定义在这里而不是 CardSnapshotStore 里，是为了让 AppState 在「退出登录清理」
 * 时能直接引用它 —— CardSnapshotStore 反过来引用了 AppState，
 * 若把键留在那边就会形成循环依赖。
 */
export const KEY_CARD_SNAPSHOT: string = 'card_snapshot';

/**
 * 桌面卡片的**周级载荷**。
 *
 * 与 card_snapshot 的区别：那份是「写入那一刻算好的今天」，
 * 卡片只能重画；这份是整周课表，卡片自己按当前时间算今天，
 * 因此跨天自愈、`done` 与「下一节」会随时间变化。
 * 见 CardSnapshotStore 的类注释。
 */
export const KEY_CARD_WEEK: string = 'card_week';
/**
 * 已添加的桌面卡片 id 列表（逗号分隔）。
 *
 * 为什么必须存：卡片要能被**主动刷新**，就必须知道 formId。
 * `onAddForm` 的 want 里带着 formId，而 `formProvider.updateForm(formId, …)`
 * 是唯一能把新数据推给已经渲染着的卡片的手段 —— 没有它，
 * 主应用改了快照也只是改了磁盘，卡片会一直显示旧内容，
 * 直到系统按周期（本应用是约 60 分钟）调用 onUpdateForm，
 * 用户表现为「加了课卡片不变，得删掉重加」。
 * SDK 文档也明确要求把 onAddForm 里的表单信息「作为持久化数据管理，供后续更新与删除使用」。
 */
export const KEY_CARD_FORM_IDS: string = 'card_form_ids';

/** 上课提醒相关 */
export const KEY_SECTION_TIMES: string = 'section_times';
export const KEY_REMINDER_ON: string = 'reminder_enabled';
export const KEY_REMINDER_ADVANCE: string = 'reminder_advance_min';
export const KEY_REMINDER_RING: string = 'reminder_ring_sec';
export const KEY_REMINDER_SNOOZE_TIMES: string = 'reminder_snooze_times';
export const KEY_REMINDER_SNOOZE_INTERVAL: string = 'reminder_snooze_interval';
/** 是否把课表写入系统日历 */
/** 已写入系统日历的事件 id（按课程实例聚合，便于整体清理） */
/** 已写入系统日历时所用的课表指纹，用于判断是否需要重建 */

/** 应用包名，供代理提醒的点击跳转、桌面卡片等使用 */
export const APP_BUNDLE_NAME: string = 'com.sdufe.jwclient';

/** 桌面卡片 */
export const FORM_NAME_TODAY: string = 'todayCourseCard';

/**
 * 官网校历缓存。
 * 抓取成功才写；离线时读这里，再退回内置数据（见 AcademicCalendar）。
 */
export const KEY_CAMPUS_SECTIONS: string = 'campus_sections';
export const KEY_CAMPUS_IMAGES: string = 'campus_images';
export const KEY_CAMPUS_IMAGE_URLS: string = 'campus_image_urls';
export const KEY_CAMPUS_UPDATED: string = 'campus_updated';
export const KEY_CAMPUS_FETCHED_AT: string = 'campus_fetched_at';
/** 校历图片在 filesDir 下的子目录名 */
export const CAMPUS_DIR: string = 'campus';

/**
 * 周次与系统时间的对齐间隔：6 小时。
 * 超过该间隔后再次进入应用会重新计算周次，保证跨周/跨天时能自动跟上。
 */
export const WEEK_ALIGN_INTERVAL_MS: number = 6 * 60 * 60 * 1000;

/** 一天毫秒数 */
export const DAY_MS: number = 24 * 60 * 60 * 1000;

/** 一学期最多周数（用于校验与下拉） */
export const MAX_WEEKS: number = 30;

/**
 * AppStorage 键集中定义在这里。
 * 原因：这些键被多个模块共享（AppState / QzApi / 各页面），
 * 若定义在 AppState 里，QzApi 引用时就会与 AppState 形成循环依赖。
 */
export const AS_LOGGED_IN: string = 'loggedIn';
export const AS_STUDENT_NAME: string = 'studentName';
export const AS_STUDENT_ID: string = 'studentId';
export const AS_CURRENT_WEEK: string = 'currentWeekNo';
export const AS_SEMESTER_START: string = 'semesterStartMonday';
export const AS_WEEK_CONFIGURED: string = 'weekConfigured';
export const AS_WINDOW_WIDTH: string = 'windowWidth';
export const AS_BREAKPOINT: string = 'breakpoint';

/**
 * 是否已保存过账号密码（凭据在系统密钥库里）。
 *
 * 缓存在 AppStorage 里的原因：QzApi 判断「会话失效后该弹重新验证还是彻底退出」
 * 时是同步上下文，没法 await 去查密钥库。启动时由 AppState.restoreSession
 * 读一次写进来，登录成功/取消记住时同步更新。
 */
export const AS_HAS_CREDENTIAL: string = 'hasStoredCredential';
/** 是否正在等待用户重新验证（会话失效且已有凭据）。界面据此弹验证码弹窗。 */
export const AS_REAUTH_PENDING: string = 'reauthPending';
/**
 * 会话保活：最近一次保活成功的时间戳（毫秒），0 表示本次启动尚未成功过。
 * 设置页据此显示「上次保活」状态。
 */
/** 会话保活：最近一次保活的结果描述（供设置页显示，含失败原因） */

/** 会话保活：开关（默认开启） */
/** 会话保活：最近一次成功时间戳落盘，重启后设置页仍能显示 */

/**
 * 底部 dock 浮层占用的高度（vp），0 表示当前布局没有底部 dock。
 *
 * 为什么需要这个值：dock 现在是**浮在内容之上**的玻璃胶囊（内容从它下面滚过，
 * 这样玻璃中心透明才能看到被遮挡的内容）。代价是滚动到底时最后一行会压在
 * dock 下面，因此页面滚动内容必须留出这么高的底部空白。
 *
 * 为什么走 AppStorage 而不是各页面写死常量：平板（宽屏）布局用左侧导航栏，
 * 底部没有 dock，多留这段空白只会浪费屏幕。由 Index 按当前布局写入，
 * 页面订阅后可在折叠屏展开/折叠时自动适配。
 */
export const AS_BOTTOM_INSET: string = 'bottomInset';

/**
 * 窗口高度（vp）。AppleUI 的 Height 是 number，侧栏玻璃要占满高度，
 * 因此需要真实高度值（与 AS_WINDOW_WIDTH 配对）。
 */
export const AS_WINDOW_HEIGHT: string = 'windowHeight';

// ==================== 页面缓存 ====================
//
// 见 data/PageCache.ets。这里只放「缓存标识」与「新鲜期」。
// 与 Flutter 端 common/constants.dart 的 kCache* / kTtl* 一一对应，
// 两端的过期策略保持一致 —— 改一边就要改另一边。

/** 缓存标识：页面名（参与缓存 key，不要随意改名，否则旧缓存会失配） */
export const CACHE_SCORE_LIST: string = 'score_list';
export const CACHE_SCORE_SEMESTERS: string = 'score_semesters';
export const CACHE_PLAN: string = 'plan';
export const CACHE_ELECTIVE: string = 'elective';
export const CACHE_PROFILE: string = 'profile';
export const CACHE_CLASSROOM_OPTIONS: string = 'classroom_options';
export const CACHE_CLASSROOM_BUILDINGS: string = 'classroom_buildings';
export const CACHE_CLASSROOM_USAGE: string = 'classroom_usage';
export const CACHE_SEMESTER_CALENDAR: string = 'semester_calendar';
export const CACHE_SEMESTER_LIST: string = 'semester_list';

/**
 * 新鲜期（毫秒）。
 *
 * 判据：数据多久变一次 vs 重复请求的代价。
 *   成绩：出分时段学生反复刷 → 2 分钟
 *   空教室占用：反映「此刻哪间空着」→ 2 分钟
 *   修读进度：变动不频繁 → 10 分钟
 *   培养方案/个人信息/校历/静态配置：一学期甚至一年才变 → 6 小时
 *
 * 宁可偏保守（短）：实机观察后可调，而调长的风险只是多几次请求，
 * 调太长才会让用户看到过期数据。
 */
export const TTL_SCORE_LIST: number = 2 * 60 * 1000;
export const TTL_SCORE_SEMESTERS: number = 6 * 60 * 60 * 1000;
export const TTL_ELECTIVE: number = 10 * 60 * 1000;
export const TTL_PLAN: number = 6 * 60 * 60 * 1000;
export const TTL_PROFILE: number = 6 * 60 * 60 * 1000;
export const TTL_CLASSROOM_OPTIONS: number = 6 * 60 * 60 * 1000;
export const TTL_CLASSROOM_BUILDINGS: number = 6 * 60 * 60 * 1000;
export const TTL_CLASSROOM_USAGE: number = 2 * 60 * 1000;
export const TTL_SEMESTER_CALENDAR: number = 6 * 60 * 60 * 1000;
export const TTL_SEMESTER_LIST: number = 6 * 60 * 60 * 1000;

/**
 * 上次「因系统时间已超出周历而自动拉取」的日期（`yyyy-MM-dd`）。
 *
 * 用于把这种自动拉取限制为**每天一次**：触发条件（今天晚于周历最后一周）
 * 在放假期间持续成立，不限制就会每次启动/每次打开校历都联网。
 */
export const KEY_SEMESTER_AUTO_FETCH_DAY: string = 'semester_auto_fetch_day';
