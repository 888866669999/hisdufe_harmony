/*
 * 设置页
 *
 * ===== 与 Flutter 端 1:1 对齐 =====
 * 本页的结构与文案以 Flutter 端 `lib/pages/settings_page.dart` 为准，
 * 五个分组、每组的行、每行的副标题与右侧值都逐条对齐：
 *
 *   学期与周次：开学日期 / 当前教学周 / 节次作息 / （恢复了才出现）恢复官方作息 / 校历与作息表
 *   上课提醒：  开启上课提醒（开关）/ 提前提醒
 *   桌面卡片：  今日课程卡片（右侧「添加桌面卡片」按钮）+ 脚注
 *   账号：      学号 / 姓名 / 退出登录
 *   关于：      版本行 + 说明段落
 *
 * 鸿蒙端独有的项目已全部移除（手动录入日期、官方校历一键采用、通知权限独立行、
 * 学校官方作息表弹窗、同步到系统日历、登录状态保活整组）—— 它们在 Flutter 端
 * 没有对应实现，留着会让两端行为分叉。被移除的项目背后的服务代码
 * （CalendarSyncService / SessionKeepAlive）也一并删除，不留死代码。
 *
 * ===== 关于反馈方式 =====
 * 原先反馈散落在三处（组内 hintText、reminderHint、showToast），
 * 现在统一成页面顶部的一条提示横幅（`hint`），与 Flutter 的 `_hint` 一致：
 * 位置固定、不会被用户忽略、也不会像 toast 那样一闪而过。
 */
import { promptAction } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { AppState } from '../data/AppState';
import { PrefStore } from '../data/PrefStore';
import { WeekService, AS_CURRENT_WEEK, AS_SEMESTER_START } from '../data/WeekService';
import { WeekCalc, DateParts } from '../common/WeekCalc';
import { ReminderService, ReminderConfig, PublishOutcome } from '../data/ReminderService';
import { SectionTimeStore, SectionTime } from '../data/SectionTimeStore';
import { CardSnapshotStore, CardSnapshot } from '../data/CardSnapshotStore';
import { ContextHolder } from '../common/ContextHolder';
import { Logger } from '../common/Logger';
import { Theme } from '../theme/Theme';
import { DateWheelContent, YmdValue, dateWheelPanelWidth, dateWheelPanelHeight } from '../components/DateWheelDialog';
import { CalendarSheet } from '../components/CalendarSheet';
import { GlassOverlay } from '../components/GlassOverlay';
import { SettingRow } from '../components/SettingRow';
import { GlassKit, PanelMaterial } from '../theme/GlassKit';
import { AS_STUDENT_NAME, AS_STUDENT_ID } from '../data/AppState';
import { BASE_ORIGIN } from '../common/Constants';

/**
 * `@ohos.app.form.formProvider` 的 default 导出形状。
 *
 * 只声明用到的成员：ArkTS 不允许把命名空间当对象用（arkts-no-ns-as-obj），
 * 因此必须通过具名 interface 描述动态 import 的返回值。
 */
interface FormManagerModule {
  default?: FormManagerApi;
}

interface FormManagerApi {
  /** 打开系统卡片管理页（部分设备/形态不支持，会抛 801） */
  openFormManager(want: Want): void;
}

@Component
export struct SettingsPage {
  @StorageProp(AS_STUDENT_NAME) studentName: string = '';
  @StorageProp(AS_STUDENT_ID) studentId: string = '';
  @StorageProp(AS_SEMESTER_START) semesterStart: string = '';
  @StorageProp(AS_CURRENT_WEEK) currentWeekNo: number = 0;
  @State account: string = '';

  /**
   * 顶部提示横幅的文案（空则整条不显示）。
   *
   * 统一入口：所有操作结果都写到这里，不再用 toast / 组内小字。
   * 与 Flutter 的 `_hint` 语义一致。
   */
  @State hint: string = '';

  /** 上课提醒 */
  @State reminderEnabled: boolean = false;
  @State reminderCount: number = 0;
  @State advanceMinutes: number = 15;
  /** 通知权限是否已开启（折叠进开关的副标题，不再单独占一行） */
  @State notificationOn: boolean = false;
  /**
   * 用户拒绝过通知授权。
   *
   * 与 notificationOn 分开的原因：两者都表示「现在没权限」，
   * 但只有「被拒绝过」才需要在界面上给一个去系统设置的入口
   * （官方限制：拒绝过一次后 requestEnableNotification 就不再弹窗，
   * 用户只能自己到系统设置里开）。
   */
  @State permDenied: boolean = false;

  /** 开学日期滚轮浮层 */
  @State dateWheelOpen: boolean = false;
  @State dateWheelInit: YmdValue = new YmdValue(2026, 1, 1);
  @State dateWheelFirstYear: number = 2023;
  @State dateWheelLastYear: number = 2029;
  /** 节次作息编辑浮层 */
  @State editorOpen: boolean = false;
  @State draftTimes: SectionTime[] = [];

  /** 「提前提醒」选项浮层 */
  @State advanceOpen: boolean = false;

  /** 桌面卡片状态：只在**还不能用**时给文案，可用时留空（对齐 Flutter） */
  @State cardHint: string = '';

  /** 校历与作息表弹窗 */
  @State calendarOpen: boolean = false;

  /** 节次作息是否为官方默认值（决定「恢复官方作息」行是否出现） */
  @State sectionIsDefault: boolean = true;

  /** 当前学期的官方校历编码末位（决定弹窗初始显示哪一学期） */
  /** 校历弹窗要显示的学期代码（如 2026-2027-1） */
  @State calendarSemester: string = '';

  /**
   * 页面加载：拉齐所有状态。
   *
   * ===== 为什么必须补这一步（这是个既有 bug 的修复）=====
   * 本页原先**没有任何生命周期钩子**，`loadReminder()` / `loadAccount()` 等
   * 定义了却从未被调用。后果：进入设置页时「开启上课提醒」永远显示关闭
   * （即使实际开着）、副标题恒为 0 条、卡片提示永远停在「正在检查…」。
   * Flutter 端在 `initState` 里做这件事，这里对齐。
   */
  aboutToAppear(): void {
    this.load();
  }

  /**
   * 每次页面显示时重新核对通知权限。
   *
   * 为什么必须有：用户被拒后要跳到**系统设置**里开权限，回来时本页并没有重建
   * （设置页在导航里是常驻的），`aboutToAppear` 不会再触发 ——
   * 于是界面继续显示「未开启通知权限」，用户以为没生效，实际系统里已经开了。
   */
  onPageShow(): void {
    this.refreshPermission();
  }

  /** 只刷新权限相关的显示状态（不动其它已加载的数据） */
  private async refreshPermission(): Promise<void> {
    const on: boolean = await ReminderService.notificationOn();
    if (on !== this.notificationOn) {
      this.notificationOn = on;
    }
    // 权限已获得就收起「去系统设置」入口
    if (on && this.permDenied) {
      this.permDenied = false;
      this.hint = '通知权限已开启，可以打开上课提醒了';
    }
  }

  private async load(): Promise<void> {
    await SectionTimeStore.load();
    const cfg: ReminderConfig = await ReminderService.loadConfig();
    this.reminderEnabled = cfg.enabled;
    this.advanceMinutes = cfg.advanceMinutes;
    // 通知权限：提醒能生效的硬前提，折叠进开关副标题
    this.notificationOn = await ReminderService.notificationOn();
    // 已排定条数：向系统查询真实值（不是内存计数），这样重进页面也准确
    this.reminderCount = this.reminderEnabled ? await ReminderService.count() : 0;
    this.sectionIsDefault = SectionTimeStore.isDefault();
    this.account = await PrefStore.loadAccount();

    // 卡片提示：只在还不具备条件时说明原因；可用时不显示内部状态 ——
    // 用户看一眼桌面就知道有几节课，设置页重复一遍是噪音（对齐 Flutter）。
    const snap: CardSnapshot | null = await CardSnapshotStore.load();
    this.cardHint = (snap === null) ? '打开一次课表后即可使用' : '';

    // 校历弹窗默认展示与当前学期一致的那一学期
    // （传学期代码本身，由 CalendarSheet 去教学周历里取对应学期的数据）
    const tt = AppState.timetable;
    let code: string = (tt !== null && tt.semester.length > 0) ? tt.semester : '';
    if (code.length === 0) {
      code = await PrefStore.loadLastSemester();
    }
    this.calendarSemester = code;
  }

  // ==================== 学期与周次 ====================

  /**
   * 设置开学日期：打开年/月/日滚轮浮层。
   *
   * 只置两个 @State（是否打开 + 初始值）；关闭由浮层内的回调置回 false，
   * 不依赖框架注入 —— 早先用 CustomDialogController 时
   * `this.controller` 是 undefined，确定/取消都关不掉
   * （详见 DateWheelContent 的类注释）。
   */
  private pickSemesterStart(): void {
    const cur: DateParts | null = WeekCalc.parse(this.semesterStart);
    const now: Date = new Date();
    this.dateWheelInit = (cur !== null)
      ? new YmdValue(cur.year, cur.month, cur.day)
      : new YmdValue(now.getFullYear(), now.getMonth() + 1, now.getDate());
    this.dateWheelFirstYear = now.getFullYear() - 3;
    this.dateWheelLastYear = now.getFullYear() + 3;
    this.dateWheelOpen = true;
  }

  private async applyStartText(text: string): Promise<void> {
    try {
      await WeekService.setStartMonday(text);
      this.semesterStart = text;
      this.hint = '已设为 ' + text
        + (this.currentWeekNo > 0 ? ('，当前第 ' + this.currentWeekNo.toString() + ' 周') : '');
      // 开学日期变了：提醒要重排，桌面卡片也要跟着更新
      await this.republishIfEnabled();
      await CardSnapshotStore.refresh().catch(() => {
        Logger.warn('card refresh after start date failed');
      });
    } catch (e) {
      this.hint = '日期无效，保存失败';
      Logger.warn('save semester start failed');
    }
  }

  // ==================== 节次作息 ====================

  private sectionTimeHint(): string {
    const list: SectionTime[] = SectionTimeStore.all();
    if (list.length === 0) {
      return '未设置';
    }
    return '第1大节 ' + list[0].start + ' 起，共 ' + list.length.toString() + ' 段';
  }

  /**
   * 节次作息的副标题：是否为官方值。
   *
   * 与 Flutter 的「跟随学校官网时刻表 / 已自定义」两态一致 ——
   * 这一栏同时承担「值是多少」与「来源是谁」两个信息，副标题说来源。
   */
  private sectionSubtitle(): string {
    return this.sectionIsDefault ? '跟随学校官网时刻表' : '已自定义';
  }

  /** 打开作息编辑：复制一份草稿 */
  private openTimeEditor(): void {
    const src: SectionTime[] = SectionTimeStore.all();
    const draft: SectionTime[] = [];
    for (let i = 0; i < src.length; i++) {
      draft.push(new SectionTime(src[i].index, src[i].label, src[i].start, src[i].end));
    }
    this.draftTimes = draft;
    this.editorOpen = true;
  }

  /** 修改草稿中的某个时刻；ArkTS 对数组元素的可观测性有限，整体替换触发刷新 */
  private patchTime(idx: number, value: string, isStart: boolean): void {
    const next: SectionTime[] = [];
    for (let i = 0; i < this.draftTimes.length; i++) {
      const s: SectionTime = this.draftTimes[i];
      if (i === idx) {
        next.push(new SectionTime(s.index, s.label,
          isStart ? value : s.start, isStart ? s.end : value));
      } else {
        next.push(new SectionTime(s.index, s.label, s.start, s.end));
      }
    }
    this.draftTimes = next;
  }

  /** 保存作息：校验 → 落盘 → 重排提醒 → 刷新卡片 → 关浮层 */
  private async saveTimes(): Promise<void> {
    // 校验并归一化
    const cleaned: SectionTime[] = [];
    for (let i = 0; i < this.draftTimes.length; i++) {
      const s: SectionTime = this.draftTimes[i];
      const a: number = SectionTimeStore.toMinutes(s.start);
      const b: number = SectionTimeStore.toMinutes(s.end);
      if (a < 0 || b < 0) {
        this.hint = s.label + '：时间格式应为 HH:mm，例如 08:30';
        return;
      }
      if (b <= a) {
        this.hint = s.label + '：结束时间应晚于开始时间';
        return;
      }
      cleaned.push(new SectionTime(s.index, s.label, s.start, s.end));
    }
    await SectionTimeStore.save(cleaned);
    this.sectionIsDefault = SectionTimeStore.isDefault();
    this.editorOpen = false;
    this.hint = '作息时间已保存';
    await this.republishIfEnabled();
    // 作息变了卡片上的上课时刻也要跟着变 —— 不推一次的话，
    // 用户改完回到桌面看到的还是旧时间（Flutter 端同样在这里刷新）
    await CardSnapshotStore.refresh().catch(() => {
      Logger.warn('card refresh after section times failed');
    });
  }

  /**
   * 恢复官方作息（对齐 Flutter 的独立行 + 确认弹窗）。
   *
   * 与编辑器里的「恢复默认」不同：那个只改草稿、还要点保存；
   * 这里直接落盘并清掉自定义标记，之后官网再改作息也能同步进来。
   */
  private async restoreOfficialTimes(): Promise<void> {
    const ok: boolean = await this.confirm(
      '恢复官方作息',
      '将清除你自定义的节次时间，恢复为学校官方时刻表，之后随官网自动更新。是否继续？',
      '恢复'
    );
    if (!ok) {
      return;
    }
    await SectionTimeStore.resetToDefault();
    this.sectionIsDefault = true;
    this.hint = '已恢复官方作息';
    await this.republishIfEnabled();
    await CardSnapshotStore.refresh().catch(() => {
      Logger.warn('card refresh after section reset failed');
    });
  }

  // ==================== 上课提醒 ====================

  /**
   * 开关提醒。
   *
   * 与 Flutter 一致：先做**预检**（通知权限 → 开学日期 → 课表），
   * 任何一项没就绪就给明确提示并保持关闭，而不是「打开→静默失败」。
   *
   * ===== 打开开关时主动申请通知权限（而不是只提示）=====
   * 原先这里只检查 `notificationOn`，未开启就显示「请先开启通知权限」——
   * 但用户在这一步**没有任何可操作的地方**：设置页没有申请权限的入口，
   * 他只能自己去系统设置里翻，于是这个开关实际上打不开。
   * 现在直接调 `ensureNotificationEnabled`：它内部会调
   * `notificationManager.requestEnableNotification`，**系统授权弹窗会自动弹出**，
   * 用户在弹窗里点「允许」即可继续；拒绝才有必要引导去系统设置。
   */
  private async onReminderToggle(on: boolean): Promise<void> {
    if (!on) {
      const cfg: ReminderConfig = await ReminderService.loadConfig();
      cfg.enabled = false;
      await ReminderService.saveConfig(cfg);
      await ReminderService.cancelAll();
      this.reminderEnabled = false;
      this.reminderCount = 0;
      this.hint = '已关闭上课提醒';
      return;
    }

    const ctx: common.UIAbilityContext | null = ContextHolder.get();
    if (ctx === null) {
      this.hint = '无法获取应用上下文';
      return;
    }

    // 预检一：通知权限。未开启时直接弹出系统授权弹窗。
    if (!this.notificationOn) {
      const granted: boolean = await ReminderService.ensureNotificationEnabled(ctx);
      this.notificationOn = granted;
      if (!granted) {
        // 用户拒绝（或此前已拒绝过、系统不再弹窗）：给出可执行的去处。
        // 官方限制：拒绝过一次后 requestEnableNotification 不再弹窗，
        // 只能由用户到系统设置里手动开启。
        this.permDenied = true;
        this.hint = '未获得通知权限，提醒无法生效 —— 点下方「去系统设置」开启后回来重试';
        return;
      }
    }
    this.permDenied = false;

    // 预检二：开学日期（没有它算不出哪天上课）
    if (this.semesterStart.length === 0) {
      this.hint = '请先在「学期与周次」里设置开学日期';
      return;
    }
    // 预检三：课表（提醒的内容来自课表）
    if (AppState.timetable === null) {
      this.hint = '请先打开一次课表';
      return;
    }

    const cfg: ReminderConfig = await ReminderService.loadConfig();
    cfg.enabled = true;
    await ReminderService.saveConfig(cfg);
    this.reminderEnabled = true;

    this.hint = '正在发布提醒…';
    const out: PublishOutcome = await ReminderService.publishAll(ctx);
    this.reminderCount = out.published;
    this.hint = out.message;
  }

  /** 跳到系统通知设置页（用户拒绝过授权后，系统不再弹窗，只能走这里） */
  private openNotificationSettings(): void {
    const ctx: common.UIAbilityContext | null = ContextHolder.get();
    if (ctx === null) {
      return;
    }
    ReminderService.openSystemNotificationSettings(ctx);
  }

  /** 若提醒已开启，按最新配置重排 */
  private async republishIfEnabled(): Promise<void> {
    if (!this.reminderEnabled) {
      return;
    }
    const ctx: common.UIAbilityContext | null = ContextHolder.get();
    if (ctx === null) {
      return;
    }
    const out: PublishOutcome = await ReminderService.publishAll(ctx);
    this.reminderCount = out.published;
  }

  private advanceLabel(): string {
    return '课前 ' + this.advanceMinutes.toString() + ' 分钟';
  }

  private async applyAdvance(minutes: number): Promise<void> {
    this.advanceOpen = false;
    this.advanceMinutes = minutes;
    const cfg: ReminderConfig = await ReminderService.loadConfig();
    cfg.advanceMinutes = minutes;
    await ReminderService.saveConfig(cfg);
    // 改了提前量需要重排提醒，否则已排的那些仍按旧提前量触发
    await this.republishIfEnabled();
    this.hint = '已设为' + this.advanceLabel();
  }

  // ==================== 桌面卡片 ====================

  /**
   * 打开系统的卡片管理页。
   *
   * ===== 平台差异（与 Flutter 的「一键添加到桌面」不等价，如实说明）=====
   * Android 有 `requestPinAppWidget`，可以一键把卡片钉到桌面。
   * 鸿蒙**没有**对应的 pin API（SDK 里不存在 formHost/requestPinForm），
   * 只有 `formProvider.openFormManager` —— 它打开的是系统的卡片管理界面，
   * 用户在那里挑选并添加。因此这里能做的极限是「把用户送到正确的地方」，
   * 而不是替他把卡片放好。
   *
   * 部分设备/形态上该能力不可用（抛 801），此时降级为文案指引 ——
   * 这也是应用里脚注那段话存在的原因。
   */
  private async addWidget(): Promise<void> {
    const ctx: common.UIAbilityContext | null = ContextHolder.get();
    if (ctx === null) {
      this.hint = '无法获取应用上下文';
      return;
    }
    // 动态导入：静态导入缺失的 HMS 导出会在**模块加载期**抛错、try/catch 拦不住
    // （本仓库在 FormKit 上踩过这个坑，见 CardPusher 的说明）。
    const fp: FormManagerApi | null = await SettingsPage.loadFormProvider();
    if (fp === null || fp.openFormManager === undefined) {
      this.hint = '当前设备不支持一键添加，请长按桌面空白处手动添加';
      return;
    }
    try {
      const want: Want = {
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name
      };
      fp.openFormManager(want);
      this.hint = '已打开卡片管理，选择「今日课程」添加';
    } catch (e) {
      // 801 = 设备能力不支持；其余异常同样降级为指引文案
      this.hint = '当前设备不支持一键添加，请长按桌面空白处手动添加';
      Logger.warn('openFormManager unavailable');
    }
  }

  /**
   * 动态加载 formProvider。
   *
   * 与 CardPusher 同一手法：直接引 `@ohos.app.form.formProvider`（拿到的是
   * 该模块的 default 导出本身），而不是 `@kit.FormKit` —— 后者的再导出在
   * 动态 import 下取不到（实测报 "FormKit exports missing"）。
   */
  private static async loadFormProvider(): Promise<FormManagerApi | null> {
    try {
      const m: FormManagerModule = await import('@ohos.app.form.formProvider');
      if (m === undefined || m === null) {
        return null;
      }
      const p: FormManagerApi | undefined = m.default;
      return (p !== undefined) ? p : null;
    } catch (e) {
      return null;
    }
  }

  // ==================== 账号 ====================

  private confirmLogout(): void {
    promptAction.showDialog({
      title: '退出登录',
      message: '将清除本地会话，需重新登录。是否继续？',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '退出', color: '#D92D20' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.doLogout();
      }
    }).catch(() => {
      // 忽略取消
    });
  }

  /**
   * 真正执行退出：停掉跟账号绑定的后台行为 → 清凭据 → 清卡片 → 清会话。
   *
   * 与 Flutter 对齐的三件事：
   *   1. 清掉已保存的凭据（否则下次启动会拿别人的账号自动登录）；
   *   2. 清掉卡片快照并**推一张空卡片**（否则桌面会继续显示上一个账号的
   *      今日课程，直到系统下次周期刷新 —— 最长约 30 分钟）；
   *   3. 停掉应用内提醒定时器。
   */
  private async doLogout(): Promise<void> {
    try {
      await ReminderService.cancelAll();
    } catch (e) {
      // 清理失败不阻塞退出
    }
    // 卡片清空要在清会话之前做：清会话后就没有账号可用于推送了
    await CardSnapshotStore.clear().catch(() => {
      Logger.warn('card clear failed');
    });
    await AppState.logout();
    this.account = '';
    this.reminderCount = 0;
  }

  // ==================== 通用 ====================

  /** 通用确认弹窗；返回用户是否点了确认 */
  private async confirm(title: string, message: string, okText: string): Promise<boolean> {
    return await new Promise<boolean>((resolve) => {
      promptAction.showDialog({
        title: title,
        message: message,
        buttons: [
          { text: '取消', color: '#666666' },
          { text: okText, color: '#2957C9' }
        ]
      }).then((result: promptAction.ShowDialogSuccessResponse) => {
        resolve(result.index === 1);
      }).catch(() => {
        resolve(false);
      });
    });
  }

  // 设置行的渲染已抽到 components/SettingRow.ets。
  //
  // 原来这里是 `@Builder settingRow(...)` / `readonlyRow(...)`，两者都改由
  // 那个组件承担 —— 原因是 @Builder 的参数按值传递，异步加载来的状态更新
  // 不会刷新已建的行（详见该文件顶部说明，那里记录了实测到的表现）。

  /** 只读信息行（右侧值可空） */
  @Builder
  infoRow(label: string, value: string, danger: boolean) {
    Row() {
      Text(label)
        .fontSize(Theme.FS_BODY)
        .fontColor(danger ? $r('app.color.danger') : $r('app.color.text_primary'))
        .layoutWeight(1)
      if (value.length > 0) {
        Text(value)
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .padding({ left: Theme.GAP, right: Theme.GAP, top: 14, bottom: 14 })
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
  }

  /** 可点击的只读行（退出登录：danger 色 + 右箭头） */
  @Builder
  actionInfoRow(label: string, action: () => void) {
    Row() {
      Text(label)
        .fontSize(Theme.FS_BODY)
        .fontColor($r('app.color.danger'))
        .layoutWeight(1)
      Text('›')
        .fontSize(Theme.FS_SECTION)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding({ left: Theme.GAP, right: Theme.GAP, top: 14, bottom: 14 })
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
    .onClick(() => {
      action();
    })
  }

  /** 分组标题 */
  @Builder
  groupTitle(text: string) {
    Text(text)
      .fontSize(Theme.FS_SMALL)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .padding({ left: Theme.GAP, right: Theme.GAP, top: Theme.GAP, bottom: Theme.GAP_S })
  }

  // ==================== 浮层 ====================

  /**
   * 节次作息编辑浮层的内容。
   *
   * 只含内容，不含面板外框 —— 边框、圆角、玻璃底、遮罩全由 [GlassOverlay] 负责。
   * 这样五个浮层的「壳」逻辑只有一份，改一次全局生效。
   */
  @Builder
  timeEditor() {
    Column({ space: Theme.GAP }) {
      Column({ space: 2 }) {
        Text('节次作息时间')
          .fontSize(Theme.FS_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('教务课表只给出节次名称、不含时刻；请按实际作息填写，提醒时间据此计算')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Scroll() {
        Column({ space: Theme.GAP_S }) {
          ForEach(this.draftTimes, (st: SectionTime, idx: number) => {
            Row({ space: Theme.GAP_S }) {
              Text(st.label)
                .fontSize(Theme.FS_SMALL)
                .fontColor($r('app.color.text_primary'))
                .width(96)
              TextInput({ text: st.start })
                .layoutWeight(1)
                .height(42)
                .fontSize(Theme.FS_BODY)
                .backgroundColor($r('app.color.surface_variant'))
                .backgroundEffect(GlassKit.fieldEffect())
                // 面板是不透明的，模糊背后只有一块纯色 —— 补一道高光细边，
                // 输入框才不像「贴在纸上的灰色方块」（见 GlassKit.FIELD_EDGE）
                .border({ width: 0.5, color: GlassKit.FIELD_EDGE })
                .borderRadius(Theme.RADIUS_SM)
                .textAlign(TextAlign.Center)
                .onChange((v: string) => {
                  this.patchTime(idx, v, true);
                })
              Text('—')
                .fontSize(Theme.FS_SMALL)
                .fontColor($r('app.color.text_tertiary'))
              TextInput({ text: st.end })
                .layoutWeight(1)
                .height(42)
                .fontSize(Theme.FS_BODY)
                .backgroundColor($r('app.color.surface_variant'))
                .backgroundEffect(GlassKit.fieldEffect())
                .border({ width: 0.5, color: GlassKit.FIELD_EDGE })
                .borderRadius(Theme.RADIUS_SM)
                .textAlign(TextAlign.Center)
                .onChange((v: string) => {
                  this.patchTime(idx, v, false);
                })
            }
            .width('100%')
          }, (st: SectionTime, idx: number) => 'st-' + idx.toString() + '-' + st.start + '-' + st.end)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.TopStart)

      // 按钮与 Flutter 的 SectionTimeDialog 一致：取消 / 保存
      Row({ space: Theme.GAP_S }) {
        Button('取消')
          .layoutWeight(1)
          .height(46)
          .fontSize(Theme.FS_BODY)
          .backgroundColor($r('app.color.surface_variant'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.editorOpen = false;
          })
        Button('保存')
          .layoutWeight(1)
          .height(46)
          .fontSize(Theme.FS_BODY)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.on_brand'))
          .onClick(() => {
            this.saveTimes();
          })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(GlassKit.PANEL_PAD)
  }

  /**
   * 「提前提醒」选项浮层的内容。
   *
   * 从 `promptAction.showActionMenu` 换成自绘的原因：系统菜单**无法**
   * 标出当前选中项，而这一栏的价值就在于「一眼看到现在设的是多少」。
   * 自绘后可以给当前值加勾选（对齐 Flutter 的 SimpleDialog）。
   */
  @Builder
  advancePicker() {
    Column({ space: 2 }) {
      Text('提前多久提醒')
        .fontSize(Theme.FS_SECTION)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .padding({ bottom: Theme.GAP_S })

      ForEach([5, 10, 15, 20, 30], (m: number) => {
        Row() {
          Text('课前 ' + m.toString() + ' 分钟')
            .fontSize(Theme.FS_BODY)
            .fontColor(this.advanceMinutes === m
              ? $r('app.color.brand') : $r('app.color.text_primary'))
            .layoutWeight(1)
          if (this.advanceMinutes === m) {
            Text('✓')
              .fontSize(Theme.FS_BODY)
              .fontColor($r('app.color.brand'))
          }
        }
        .width('100%')
        .height(46)
        .padding({ left: Theme.GAP, right: Theme.GAP })
        .borderRadius(Theme.RADIUS_SM)
        .onClick(() => {
          this.applyAdvance(m);
        })
      }, (m: number) => 'adv-' + m.toString())
    }
    .width('100%')
    .height('100%')
    .padding(GlassKit.PANEL_PAD)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: Theme.GAP }) {
          // ---- 顶部提示横幅（统一反馈入口）----
          if (this.hint.length > 0) {
            Text(this.hint)
              .fontSize(Theme.FS_SMALL)
              .fontColor($r('app.color.brand'))
              .width('100%')
              .padding(Theme.GAP)
              .backgroundColor($r('app.color.brand_soft'))
              .borderRadius(Theme.RADIUS_SM)
          }

          // ---- 学期与周次 ----
          Column() {
            this.groupTitle('学期与周次')

            SettingRow({
              label: '开学日期（第 1 周周一）',
              subtitle: this.semesterStart.length > 0
                ? ('已设为 ' + this.semesterStart)
                : '未设置 —— 设置后可自动定位当前周',
              value: this.semesterStart.length > 0 ? '修改' : '设置',
              chevron: true,
              onTap: () => {
                this.pickSemesterStart();
              }
            })

            SettingRow({
              label: '当前教学周',
              value: this.currentWeekNo > 0 ? ('第 ' + this.currentWeekNo.toString() + ' 周') : '未知',
              // 有效周次才用品牌色强调（判断属于调用方语义，见组件说明）
              brandValue: this.currentWeekNo > 0
            })

            SettingRow({
              label: '节次作息',
              subtitle: this.sectionSubtitle(),
              value: this.sectionTimeHint(),
              chevron: true,
              onTap: () => {
                this.openTimeEditor();
              }
            })

            // 只有自定义过才出现（对齐 Flutter）
            if (!this.sectionIsDefault) {
              SettingRow({
                label: '恢复官方作息',
                subtitle: '清除自定义，之后跟随学校官网自动更新',
                value: '恢复',
                chevron: true,
                onTap: () => {
                  this.restoreOfficialTimes();
                }
              })
            }

            SettingRow({
              label: '校历与作息表',
              value: '查看',
              chevron: true,
              onTap: () => {
                this.calendarOpen = true;
              }
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(Theme.RADIUS_SM)
          .clip(true)

          // ---- 上课提醒 ----
          Column() {
            this.groupTitle('上课提醒')

            // 总开关：副标题权限优先（对齐 Flutter）
            Row({ space: Theme.GAP_S }) {
              Column({ space: 2 }) {
                Text('开启上课提醒')
                  .fontSize(Theme.FS_BODY)
                  .fontColor($r('app.color.text_primary'))
                Text(!this.notificationOn
                  ? '未开启通知权限 —— 提醒必须先允许通知'
                  : (this.reminderEnabled
                    ? ('已排定 ' + this.reminderCount.toString() + ' 条（应用关闭也会提醒）')
                    : '按课表在课前自动提醒'))
                  .fontSize(Theme.FS_TINY)
                  .fontColor(!this.notificationOn
                    ? $r('app.color.danger') : $r('app.color.text_tertiary'))
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.reminderEnabled })
                .selectedColor($r('app.color.brand'))
                .onChange((on: boolean) => {
                  this.onReminderToggle(on);
                })
            }
            .width('100%')
            .padding({ left: Theme.GAP, right: Theme.GAP, top: 12, bottom: 12 })
            .border({ width: { top: 0.5 }, color: $r('app.color.divider') })

            SettingRow({
              label: '提前提醒',
              value: this.advanceLabel(),
              chevron: true,
              onTap: () => {
                this.advanceOpen = true;
              }
            })

            // 被拒绝过授权时给一个明确的去处：系统不会再弹窗，
            // 只提示「未获得通知权限」用户就卡住了。
            if (this.permDenied) {
              Row() {
                Text('去系统设置开启通知')
                  .fontSize(Theme.FS_SMALL)
                  .fontColor($r('app.color.brand'))
              }
              .width('100%')
              .height(44)
              .justifyContent(FlexAlign.Center)
              .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
              .onClick(() => {
                this.openNotificationSettings();
              })
            }
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(Theme.RADIUS_SM)
          .clip(true)

          // ---- 桌面卡片 ----
          Column() {
            this.groupTitle('桌面卡片')

            // 「添加桌面卡片」做成一个玻璃按钮放在右侧（对齐 Flutter 的 GlassButton）
            Row({ space: Theme.GAP_S }) {
              Column({ space: 2 }) {
                Text('今日课程卡片')
                  .fontSize(Theme.FS_BODY)
                  .fontColor($r('app.color.text_primary'))
                if (this.cardHint.length > 0) {
                  Text(this.cardHint)
                    .fontSize(Theme.FS_TINY)
                    .fontColor($r('app.color.text_tertiary'))
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Text('添加桌面卡片')
                .fontSize(Theme.FS_SMALL)
                .fontColor($r('app.color.brand'))
                .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                .backgroundColor($r('app.color.brand_soft'))
                .borderRadius(999)
                .onClick(() => {
                  this.addWidget();
                })
            }
            .width('100%')
            .padding({ left: Theme.GAP, right: Theme.GAP, top: 12, bottom: 12 })
            .border({ width: { top: 0.5 }, color: $r('app.color.divider') })

            Text('长按桌面空白处添加桌面卡片，或点击「添加桌面卡片」按钮一键添加到桌面')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .padding({ left: Theme.GAP, right: Theme.GAP, bottom: 12 })
              .lineHeight(18)
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(Theme.RADIUS_SM)
          .clip(true)

          // ---- 账号 ----
          Column() {
            this.groupTitle('账号')
            // 学号可能来自异步加载的 account（@State），同样必须走响应式组件
            SettingRow({
              label: '学号',
              value: this.studentId.length > 0 ? this.studentId : this.account
            })
            if (this.studentName.length > 0) {
              SettingRow({ label: '姓名', value: this.studentName })
            }
            this.actionInfoRow('退出登录', () => {
              this.confirmLogout();
            })
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(Theme.RADIUS_SM)
          .clip(true)

          // ---- 关于 ----
          Column() {
            this.groupTitle('关于')
            SettingRow({ label: 'hi山财 v1.0.0' })
            Text('数据来源：' + BASE_ORIGIN + '\n'
              + '本应用为个人学习用途的第三方客户端，仅供查询本人教务数据。'
              + '应用不保存密码（除非你主动勾选记住），仅在本机保存会话与偏好设置。'
              + '课表可离线查看。')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .padding(Theme.GAP)
              .lineHeight(18)
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(Theme.RADIUS_SM)
          .clip(true)
        }
        .width('100%')
        // 底部留出浮层 dock 的高度，否则最后一项设置会被玻璃压住
        .padding({ left: Theme.GAP, right: Theme.GAP, top: Theme.GAP,
          bottom: Theme.GAP + Theme.bottomInset() })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .backgroundColor($r('app.color.bg'))

      // ---- 浮层 ----
      // 每个浮层都是页面内容之后的**单个**兄弟节点：GlassOverlay 内部把
      // AppleUI 透镜放在第一个子位置，从而上溯一层取到上面的 Scroll 作为折射源
      // （层级约束的完整说明见 GlassOverlay 类注释）。
      // 开学日期滚轮浮层。宽度/高度用精确 vp：按比例算在平板上会拉得很宽。
      if (this.dateWheelOpen) {
        GlassOverlay({
          panelWidthVp: dateWheelPanelWidth(),
          panelHeightVp: dateWheelPanelHeight(),
          onDismiss: () => {
            this.dateWheelOpen = false;
          }
        }) {
          DateWheelContent({
            initial: this.dateWheelInit,
            firstYear: this.dateWheelFirstYear,
            lastYear: this.dateWheelLastYear,
            onPicked: (v: YmdValue) => {
              this.dateWheelOpen = false;
              this.applyStartText(WeekCalc.format(new DateParts(v.year, v.month, v.day)));
            },
            onCancel: () => {
              this.dateWheelOpen = false;
            }
          })
        }
      }

      // 节次作息编辑：材质为**系统默认**（不透明面板）。
      // 它是一屏密集的表单（五行 × 两个输入框 + 说明文字），
      // 磨砂玻璃下这些细小文字会被 16 点采样的模糊糊成一片（见 PanelMaterial）。
      if (this.editorOpen) {
        GlassOverlay({
          material: PanelMaterial.SYSTEM,
          panelWidthRatio: 0.92,
          panelHeightRatio: 0.72,
          onDismiss: () => {
            this.editorOpen = false;
          }
        }) {
          this.timeEditor()
        }
      }

      if (this.advanceOpen) {
        GlassOverlay({
          // 选项浮层：宽高都按内容精确给定。
          // 高度 = 5 行 × 46 + 标题（约 24）+ 标题下间距（6）+ 上下内边距（2×20）
          //      = 230 + 30 + 40 = 300，留一点余量到 310。
          // 用精确 vp 而不是比例：比例是按「可用高度」算的，平板上算出来
          // 比内容矮，后两个选项会被裁掉（实测过）。
          panelWidthVp: 320,
          panelHeightVp: 310,
          onDismiss: () => {
            this.advanceOpen = false;
          }
        }) {
          this.advancePicker()
        }
      }

      // 校历与作息表：内容里有大图，需要更高的面板。
      // 材质为**系统默认**（不透明面板）：面板里是密集的月历网格与说明文字，
      // 磨砂玻璃上会被糊开（见 PanelMaterial 的说明）。
      if (this.calendarOpen) {
        GlassOverlay({
          material: PanelMaterial.SYSTEM,
          panelWidthRatio: 0.94,
          panelHeightRatio: 0.86,
          maxPanelWidth: 720,
          onDismiss: () => {
            this.calendarOpen = false;
          }
        }) {
          CalendarSheet({
            initialSemester: this.calendarSemester,
            onClose: () => {
              this.calendarOpen = false;
            }
          })
        }
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
