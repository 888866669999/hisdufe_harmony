/*
 * QzApi：强智教务系统接口封装
 *
 * 全部接口均基于服务端渲染页面，返回解析后的模型对象。
 */
import { http } from '@kit.NetworkKit';
import { HttpClient, HttpResponse, FormField } from './HttpClient';
import { CookieJar } from './CookieJar';
import { AppError, ErrKind } from '../common/Result';
import { Logger } from '../common/Logger';
import { QzEncoder } from '../crypto/QzEncoder';
import { HtmlLite } from '../parser/HtmlLite';
import { TimetableParser } from '../parser/TimetableParser';
import { ScoreParser } from '../parser/ScoreParser';
import { ProfileParser } from '../parser/ProfileParser';
import { WeekCalendarParser } from '../parser/WeekCalendarParser';
import { PlanParser } from '../parser/PlanParser';
import { ElectiveParser } from '../parser/ElectiveParser';
import { ClassroomParser } from '../parser/ClassroomParser';
import { Timetable, ScoreRecord, StudentProfile, WeekDate, ChoiceItem,
  PlanDetail, ElectiveReport } from '../model/Models';
import { ClassroomResult, ClassroomFinder, WeekSpec } from '../model/ClassroomModels';
import { PrefStore } from '../data/PrefStore';
import {
  BASE_ORIGIN, PATH_CAPTCHA, PATH_LOGON, PATH_LOGON_SESS, PATH_MAIN,
  PATH_TIMETABLE, PATH_SCORE_LIST, PATH_PROFILE, PATH_WEEK_CALENDAR,
  PATH_PLAN_DETAIL, PATH_ELECTIVE, PATH_CLASSROOM, PATH_CLASSROOM_IFR,
  PATH_BUILDINGS, AS_LOGGED_IN, AS_HAS_CREDENTIAL
} from '../common/Constants';

/**
 * 登录失败的类别。
 *
 * 为什么需要机器可读的类别：自动登录重试**只能**在「验证码错」这类
 * 可恢复失败上触发。若靠比对界面文案来决定，一旦服务端措辞变化就会
 * 误判成可重试 —— 那意味着拿错误的账号密码反复 POST，直接踩账号锁定。
 * 因此把判断收敛到唯一一处，并让调用方按类别决策。
 */
export enum LoginFailKind {
  /** 没失败 */
  NONE = 0,
  /** 验证码不对（可换图重试） */
  CAPTCHA = 1,
  /** 账号或密码不对（绝不重试） */
  CREDENTIAL = 2,
  /** 会话/握手异常（可重试一次，但不是验证码问题） */
  SESSION = 3,
  /** 服务端拒绝了本次登录（限流/维护等），不宜立刻重试 */
  REJECTED = 4,
  /** 其他无法归类 */
  UNKNOWN = 5
}

/** 登录结果 */
export class LoginResult {
  success: boolean = false;
  message: string = '';
  /** 失败类别（成功时为 NONE） */
  kind: LoginFailKind = LoginFailKind.NONE;

  constructor(success: boolean, message: string) {
    this.success = success;
    this.message = message;
  }

  /** 便捷构造：带失败类别 */
  static fail(message: string, kind: LoginFailKind): LoginResult {
    const r: LoginResult = new LoginResult(false, message);
    r.kind = kind;
    return r;
  }
}

/** 教室查询页的可选项 */
export class ClassroomOptions {
  /** 校区，元素形如 "3|章丘校区"（value|label） */
  campuses: string[] = [];
  /** 学期代码 */
  semesters: string[] = [];
}

export class QzApi {
  private client: HttpClient;

  /**
   * 正在进行的会话探测。
   *
   * 为什么必须串行化：启动时有两处会各自探测一次会话
   * （`AppState.verifySessionInBackground` 与 `Index.trySilentRenewal`）。
   * 两条请求带着**同一个 JSESSIONID** 并发打到服务器，一旦服务端在响应中
   * 轮换会话，后到的那条就可能被判为未登录 —— 于是 `isSessionAlive()`
   * 出现假阴性，进而触发一次完全不必要的重新登录（取验证码 + 提交登录），
   * 而这次登录又会再次轮换会话，干扰其它在途请求。
   *
   * 让并发调用共享同一个 Promise，既去掉重复请求，也消除这个竞态。
   */
  private static probeInFlight: Promise<boolean> | null = null;

  constructor(jar: CookieJar) {
    this.client = new HttpClient(jar);
  }

  cookieJar(): CookieJar {
    return this.client.cookieJar();
  }

  /**
   * 获取验证码图片。
   * 关键：必须与登录请求共用同一个会话，验证码才有效。
   */
  async fetchCaptcha(): Promise<ArrayBuffer> {
    const url: string = BASE_ORIGIN + PATH_CAPTCHA;
    // 诊断价值：验证码与它绑定的会话必须和后续提交登录时一致，
    // 否则服务端会判定「验证码错误」。这一行把会话打出来便于比对。
    const before: string = this.client.cookieJar().toHeader();
    const buf: ArrayBuffer = await this.client.getBinary(url);
    const after: string = this.client.cookieJar().toHeader();
    if (before !== after) {
      Logger.info('captcha refresh rotated session: ' + after);
    }
    return buf;
  }

  /**
   * 登录。
   * 与门户 login() 完全一致：
   *   1. POST /Logon.do?method=logon&flag=sess 取 scode#sxh
   *   2. 生成 encoded
   *   3. POST /Logon.do?method=logon 提交 userAccount/userPassword/RANDOMCODE/encoded
   * 注意：页面同时提交原始密码字段，这里保持一致。
   */
  async login(account: string, password: string, captcha: string): Promise<LoginResult> {
    // 诊断：登录前的会话状态。
    // 用 toLogSummary 而不是 toHeader：后者会把 JSESSIONID 原文写进系统日志，
    // 而那是「持有即可用」的凭据（见 CookieJar.toLogSummary 的说明）。
    Logger.info('login start, jar=[' + this.client.cookieJar().toLogSummary() + ']');

    // 1. 会话握手
    const sessRes: HttpResponse = await this.client.postForm(BASE_ORIGIN + PATH_LOGON_SESS, []);
    const sessText: string = sessRes.body.trim();
    Logger.info('handshake status=' + sessRes.status + ' len=' + sessText.length +
      ' hasHash=' + (sessText.indexOf('#') >= 0) +
      ' jar=[' + this.client.cookieJar().toLogSummary() + ']');

    if (QzEncoder.isRejected(sessText)) {
      return LoginResult.fail('教务系统暂不允许登录，请稍后再试', LoginFailKind.REJECTED);
    }
    const encoded: string = QzEncoder.buildEncoded(sessText, account, password);
    if (encoded.length === 0) {
      Logger.warn('login handshake malformed, len=' + sessText.length);
      return LoginResult.fail('登录握手失败，请重试', LoginFailKind.SESSION);
    }
    // 注意：**不打印密码长度**。它是密码的派生量，配合「密码通常不长」这一常识
    // 能缩小猜测空间，属于没必要承担的风险；排查握手问题只看 encoded 长度即可。
    Logger.info('encoded len=' + encoded.length);

    // 2. 提交登录
    const fields: FormField[] = [
      new FormField('userAccount', account),
      new FormField('userPassword', password),
      new FormField('RANDOMCODE', captcha),
      new FormField('encoded', encoded)
    ];
    const res: HttpResponse = await this.client.postForm(BASE_ORIGIN + PATH_LOGON, fields);
    const body: string = res.body;
    Logger.info('login response status=' + res.status + ' bodyLen=' + body.length);

    // 3. 判定结果
    // 关键：登录成功后，服务器不是直接返回页面，而是下发一张 ticket 并重定向到
    //   /jsxsd/xk/LoginToXk?method=jwxt&ticket=...
    // 必须再访问该地址，才能换成 /jsxsd/ 下的学生端会话。
    const location: string = res.header('location');
    if (location.length > 0) {
      const target: string = QzApi.absolute(location);
      Logger.info('login redirect -> ' + QzApi.maskTicket(target));
      const uni: HttpResponse = await this.client.get(target);
      Logger.info('unified login status=' + uni.status + ' bodyLen=' + uni.body.length +
        ' jar=[' + this.client.cookieJar().toHeader() + ']');
      if (HtmlLite.isLoginPage(uni.body)) {
        return LoginResult.fail('登录未能建立会话，请重试', LoginFailKind.SESSION);
      }
      return new LoginResult(true, '登录成功');
    }

    // 兜底：部分版本直接返回门户页面
    if (HtmlLite.isLoginPage(body)) {
      const hint: string = QzApi.extractError(body);
      // 诊断：把服务端返回的错误原文打出来，便于区分
      // 「验证码错」「账号密码错」「会话与验证码不匹配」这几种情况
      Logger.warn('login rejected by server: hint=' + hint +
        ' jar=[' + this.client.cookieJar().toHeader() + ']');
      const kind: LoginFailKind = QzApi.classifyFail(hint);
      return LoginResult.fail(hint.length > 0 ? hint : '账号或密码或验证码有误', kind);
    }
    if (body.indexOf('xsMain') >= 0 || body.indexOf('教学一体化服务平台') >= 0 ||
      body.indexOf('framework') >= 0) {
      return new LoginResult(true, '登录成功');
    }
    return LoginResult.fail('登录失败，请检查账号密码与验证码', LoginFailKind.UNKNOWN);
  }

  /**
   * 按服务端错误原文判定失败类别。
   *
   * 只把明确的「验证码」措辞归为可重试；其余一律保守归类，
   * 宁可不重试也不要把账号密码类的失败当成验证码错去反复 POST。
   */
  private static classifyFail(hint: string): LoginFailKind {
    if (hint.length === 0) {
      return LoginFailKind.UNKNOWN;
    }
    if (hint.indexOf('验证码') >= 0) {
      return LoginFailKind.CAPTCHA;
    }
    if (hint.indexOf('密码') >= 0 || hint.indexOf('账号') >= 0 ||
      hint.indexOf('用户名') >= 0) {
      return LoginFailKind.CREDENTIAL;
    }
    if (hint.indexOf('会话') >= 0 || hint.indexOf('超时') >= 0) {
      return LoginFailKind.SESSION;
    }
    return LoginFailKind.UNKNOWN;
  }

  /** 把 Location 里的相对地址补成绝对地址 */
  private static absolute(loc: string): string {
    if (loc.startsWith('http://') || loc.startsWith('https://')) {
      return loc;
    }
    if (loc.startsWith('/')) {
      return BASE_ORIGIN + loc;
    }
    return BASE_ORIGIN + '/' + loc;
  }

  /** 日志用：隐去 ticket 内容，避免敏感串进日志 */
  private static maskTicket(url: string): string {
    const i: number = url.indexOf('ticket=');
    if (i < 0) {
      return url;
    }
    return url.substring(0, i + 7) + '***';
  }

  /**
   * 会话是否仍然有效。
   *   - true  ：服务器返回了正常页面，会话可用（顺带刷新 cookie）
   *   - false ：服务器明确要求登录（返回了登录页或重定向到登录）
   *   - 抛异常：网络层失败（不在校园网、超时等），调用方应保持原状态而不是登出
   */
  async isSessionAlive(): Promise<boolean> {
    // 并发调用共享同一次探测结果（见 probeInFlight 的说明）
    if (QzApi.probeInFlight !== null) {
      return await QzApi.probeInFlight;
    }
    QzApi.probeInFlight = this.probeSession();
    try {
      return await QzApi.probeInFlight;
    } finally {
      QzApi.probeInFlight = null;
    }
  }

  /** 真正的探测动作；只应由 isSessionAlive 调用（它负责去重） */
  private async probeSession(): Promise<boolean> {
    const res: HttpResponse = await this.client.get(BASE_ORIGIN + PATH_MAIN);
    // 请求可能被重定向到登录页；两种判据都视为失效
    const location: string = res.header('location');
    const isLogin: boolean = HtmlLite.isLoginPage(res.body);
    Logger.info('session probe: status=' + res.status + ' len=' + res.body.length +
      ' isLogin=' + isLogin + ' loc=[' + (location.length > 0 ? 'redirect' : '') + ']');
    if (location.length > 0 && (location.indexOf('Logon') >= 0 || location.indexOf('logon') >= 0)) {
      return false;
    }
    if (isLogin) {
      return false;
    }
    return true;
  }

  /** 兼容旧调用：仅用于「确定能区分网络错误」的场景 */
  async checkSession(): Promise<boolean> {
    return await this.isSessionAlive();
  }

  /** 课程表 */
  async getTimetable(semester: string, week: string): Promise<Timetable> {
    const fields: FormField[] = [];
    if (semester.length > 0) {
      fields.push(new FormField('xnxq01id', semester));
    }
    // 只把**纯数字周次**提交给服务器。
    //
    // 为什么必须在这里挡一道：客户端用 'auto' 表示「跟随本周」、空串表示「全部」，
    // 这两个都是**本地语义**，服务器只认数字。把 'auto' 当 zc 提交上去，
    // 未登录时会被登录页短路（所以离线怎么测都「正常」），而一旦会话有效、
    // 服务器真正去解析这个参数，就会返回 404 空响应 ——
    // 用户看到的是「课表打不开」，且点多少次重试都不会成功。
    //
    // 与 Flutter 端保持一致：取网络数据时不带周次，取回后再按本地周次过滤
    // （见 SchedulePage.weekNumber / displayWeek）。
    if (week.length > 0) {
      if (/^\d+$/.test(week)) {
        fields.push(new FormField('zc', week));
      } else {
        Logger.warn('dropped non-numeric week param: ' + week);
      }
    }
    let res: HttpResponse;
    if (fields.length > 0) {
      res = await this.client.postForm(BASE_ORIGIN + PATH_TIMETABLE, fields);
    } else {
      res = await this.client.get(BASE_ORIGIN + PATH_TIMETABLE);
    }
    this.checkResponse(res);
    const tt: Timetable = TimetableParser.parse(res.body);
    Logger.info('timetable fetch: http=' + res.status + ' len=' + res.body.length +
      ' hasKbtable=' + (res.body.indexOf('kbtable') >= 0) +
      ' cells=' + tt.cells.length);
    return tt;
  }

  /** 成绩 */
  async getScores(semester: string): Promise<ScoreRecord[]> {
    return ScoreParser.parse(await this.getScoresHtml(semester));
  }

  /**
   * 成绩页**原文**。
   *
   * 缓存层存的是原文（理由见 data/PageCache.ets）：解析器是「解读页面」的
   * 唯一真相，缓存数据走同一条解析路径，解析器修好 bug 后旧缓存自动被正确重读，
   * 不需要改缓存版本号，也不会出现「模型加字段、序列化器忘了同步」那类静默错误。
   */
  async getScoresHtml(semester: string): Promise<string> {
    let url: string = BASE_ORIGIN + PATH_SCORE_LIST;
    if (semester.length > 0) {
      url = url + '?kksj=' + encodeURIComponent(semester);
    }
    const res: HttpResponse = await this.client.get(url);
    this.checkResponse(res);
    return res.body;
  }

  /** 成绩查询页的学期筛选项 */
  async getScoreSemesters(): Promise<ChoiceItem[]> {
    return ScoreParser.readSemesters(await this.getScoreSemestersHtml());
  }

  /** 成绩学期列表页原文 */
  async getScoreSemestersHtml(): Promise<string> {
    const res: HttpResponse = await this.client.get(BASE_ORIGIN + '/jsxsd/kscj/cjcx_query');
    this.checkResponse(res);
    Logger.info('score semesters: http=' + res.status + ' len=' + res.body.length +
      ' hasSelect=' + (res.body.indexOf('<select') >= 0));
    return res.body;
  }

  /** 个人信息（学籍卡片） */
  async getProfile(): Promise<StudentProfile> {
    return ProfileParser.parse(await this.getProfileHtml());
  }

  /** 个人信息页原文 */
  async getProfileHtml(): Promise<string> {
    const res: HttpResponse = await this.client.get(BASE_ORIGIN + PATH_PROFILE);
    this.checkResponse(res);
    return res.body;
  }

  /**
   * 教学周历页原文。
   *
   * [semester] 非空时取指定学年那学期（服务端的表单是
   * `post xnxq01id=<学期>`，不传则返回当前学期）。
   *
   * 这个页面是**唯一权威且能随年份自动更新**的校历数据源：
   * 它给出「第 N 周 ←→ 周一日期」的完整对照，学校每学期排课时录入。
   * 学校官网那张校历图只是它的图片版，图里能算的这里都有结构化字段。
   */
  async getWeekCalendarHtml(semester: string): Promise<string> {
    let res: HttpResponse;
    if (semester.length === 0) {
      res = await this.client.get(BASE_ORIGIN + PATH_WEEK_CALENDAR);
    } else {
      const fields: FormField[] = [new FormField('xnxq01id', semester)];
      res = await this.client.postForm(BASE_ORIGIN + PATH_WEEK_CALENDAR, fields);
    }
    this.checkResponse(res);
    return res.body;
  }

  /** 教学周历：周次与日期对照 */
  async getWeekCalendar(semester: string): Promise<WeekDate[]> {
    return WeekCalendarParser.parseWeekDates(await this.getWeekCalendarHtml(semester));
  }

  /** 培养方案明细（含培养方案的课程设置总表与 PDF 附件地址） */
  async getPlanDetail(): Promise<PlanDetail> {
    return PlanParser.parse(await this.getPlanHtml());
  }

  /** 培养方案页原文 */
  async getPlanHtml(): Promise<string> {
    const res: HttpResponse = await this.client.get(BASE_ORIGIN + PATH_PLAN_DETAIL);
    this.checkResponse(res);
    return res.body;
  }

  /** 通选课修读情况 */
  async getElectiveReport(): Promise<ElectiveReport> {
    return ElectiveParser.parse(await this.getElectiveHtml());
  }

  /** 通选课页原文 */
  async getElectiveHtml(): Promise<string> {
    const res: HttpResponse = await this.client.get(BASE_ORIGIN + PATH_ELECTIVE);
    this.checkResponse(res);
    return res.body;
  }

  // ==================== 空教室查询 ====================

  /** 教室查询页的选项（校区与学期） */
  async getClassroomOptions(): Promise<ClassroomOptions> {
    return QzApi.parseClassroomOptions(await this.getClassroomOptionsHtml());
  }

  /** 空教室查询页原文 */
  async getClassroomOptionsHtml(): Promise<string> {
    const res: HttpResponse = await this.client.get(BASE_ORIGIN + PATH_CLASSROOM);
    this.checkResponse(res);
    return res.body;
  }

  /** 校区/学期选项的解析（静态，供缓存层复用） */
  static parseClassroomOptions(body: string): ClassroomOptions {
    const opt: ClassroomOptions = new ClassroomOptions();
    opt.campuses = ClassroomParser.parseCampuses(body);
    opt.semesters = ClassroomParser.parseSemesters(body);
    return opt;
  }

  /** 教学楼列表页原文 */
  async getBuildingsHtml(campusId: string): Promise<string> {
    const res: HttpResponse = await this.client.postForm(BASE_ORIGIN + PATH_BUILDINGS, [
      new FormField('xqid', campusId)
    ]);
    this.checkResponse(res);
    return res.body;
  }

  /** 教室占用页原文 */
  async getClassroomUsageHtml(semester: string, campusId: string, buildingId: string,
    sectionRow: number): Promise<string> {
    const codes: string[] = ClassroomFinder.sectionCodes(sectionRow);
    const fields: FormField[] = [
      new FormField('xnxqh', semester),
      new FormField('xqid', campusId),
      new FormField('jzwid', buildingId),
      new FormField('zc1', ''),
      new FormField('zc2', ''),
      new FormField('jc1', codes[0]),
      new FormField('jc2', codes[1])
    ];
    const res: HttpResponse = await this.client.postForm(BASE_ORIGIN + PATH_CLASSROOM_IFR, fields);
    this.checkResponse(res);
    return res.body;
  }

  /**
   * 按校区取教学楼列表。
   * 该接口返回 JSON 数组（Content-Type 虽为 text/html，但内容是 JSON）。
   */
  async getBuildings(campusId: string): Promise<ChoiceItem[]> {
    return QzApi.parseBuildings(await this.getBuildingsHtml(campusId));
  }

  /**
   * 查询某教学楼某节次的占用情况。
   *
   * 注意：**故意不传 zc1/zc2**。服务端的周次筛选不可靠——
   * 「被借用」类记录不受周次影响，且筛选后会丢掉该周无占用记录的教室
   * （真正全周空闲的教室恰好都在被丢掉的那批里）。
   * 拿到全学期占用文本后，由客户端按周判断，见 ClassroomModels 顶部说明。
   *
   * 原文与解析分开：解析要带上 sectionRow（节次决定读哪两列），
   * 所以缓存存原文，取出时按当前的 sectionRow 解析。
   */
  async getClassroomUsage(semester: string, campusId: string, buildingId: string,
    sectionRow: number): Promise<ClassroomResult> {
    return ClassroomParser.parseResult(
      await this.getClassroomUsageHtml(semester, campusId, buildingId, sectionRow), sectionRow);
  }

  /**
   * 解析教学楼 JSON：形如 [{"dm":"3","dmmc":"7号楼"},...]。
   * 服务端 Content-Type 是 text/html，但内容是 JSON，因此不能用 content-type 判断。
   * 返回 label=dmmc / value=dm 的选项；末尾附一个「全部教学楼」选项（value 为空）。
   *
   * 公开为 static 是为了让缓存层复用同一个解析器（见 data/PageCache.ets）。
   */
  static parseBuildings(body: string): ChoiceItem[] {
    const out: ChoiceItem[] = [];
    out.push(new ChoiceItem('全部教学楼', ''));
    const text: string = body === undefined || body === null ? '' : body.trim();
    if (text.length === 0 || text.charAt(0) !== '[') {
      Logger.warn('buildings response is not a JSON array');
      return out;
    }
    // 用正则逐条取 dm / dmmc，避免依赖 JSON.parse 对上游脏数据的容忍度
    const re: RegExp = /"dm"\s*:\s*"([^"]*)"\s*,\s*"dmmc"\s*:\s*"([^"]*)"/g;
    const ms: string[] | null = text.match(re);
    if (ms === null) {
      return out;
    }
    for (let i = 0; i < ms.length; i++) {
      const m: RegExpMatchArray | null = ms[i].match(/"dm"\s*:\s*"([^"]*)"\s*,\s*"dmmc"\s*:\s*"([^"]*)"/);
      if (m !== null && m.length >= 3 && m[1].length > 0) {
        out.push(new ChoiceItem(m[2], m[1]));
      }
    }
    Logger.info('buildings parsed: ' + (out.length - 1));
    return out;
  }

  /**
   * 业务响应的统一检查：先看 HTTP 状态，再看是否被打回登录页。
   *
   * 为什么要检查状态码：会话失效或后端异常时，服务端可能返回 4xx/5xx 错误页
   * 而不是登录页。若不检查，解析器会把错误页解析成「空数据」，
   * 界面显示「暂无数据」—— 用户完全看不出其实是请求失败了。
   *
   * 为什么排除带 location 的响应：登录流程**依赖** 404 + `location: ...ticket=...`
   * 这个形态来拿到票据（见 login()），所以有 location 时交给调用方自行判断。
   */
  private checkResponse(res: HttpResponse): void {
    if (res.status >= 400 && res.header('location').length === 0) {
      Logger.warn('business request failed: http=' + res.status);
      throw new AppError(ErrKind.SERVER, '教务系统响应异常，请稍后重试', 'http=' + res.status);
    }
    this.ensureAuthed(res.body);
  }

  /**
   * 业务请求返回登录页 = 会话确实失效。
   *
   * 处理方式：**只抛错，不在这里置「等待重新验证」标记**。
   *
   * 为什么不能直接置标记（这是个踩过的坑）：
   *   `ensureAuthed` 是所有业务请求的公共出口，其中也包括**页面首次自动加载**
   *   （进入某页 → 拉数据）。若在这里就置标记，用户一进页面就会看到
   *   「需要重新登录」弹窗 —— 而他可能只是想看一眼本地缓存的课表。
   *   正确顺序是「先静默续期，失败才弹窗」，而这个判断需要知道调用方是
   *   「自动加载」还是「用户主动操作」，只有页面自己知道。
   *   因此把置标记的时机交给页面（见 `ReAuthService.recoverIfExpired`）。
   *
   * 若登录页里确实带着交互提示，仍然抛出 AUTH_EXPIRED —— 页面据此决定
   * 是静默续期、内联提示还是弹窗。
   */
  private ensureAuthed(body: string): void {
    if (!HtmlLite.isLoginPage(body)) {
      return;
    }
    throw new AppError(ErrKind.AUTH_EXPIRED, '登录状态已失效，需要重新验证');
  }

  /** 从登录失败页提取错误提示 */
  private static extractError(body: string): string {
    const m: RegExpMatchArray | null = body.match(/id="showMsg"[^>]*>([^<]*)</i);
    if (m !== null) {
      const t: string = HtmlLite.decode(m[1]).trim();
      if (t.length > 0) {
        return t;
      }
    }
    if (body.indexOf('验证码') >= 0) {
      return '验证码错误，请重新输入';
    }
    return '';
  }

}
