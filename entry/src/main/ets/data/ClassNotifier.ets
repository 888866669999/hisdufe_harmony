/*
 * ClassNotifier：上课提醒的落地实现（双通道）
 *
 * 为什么需要两条通道：
 *   1) 代理提醒（reminderAgentManager）：最理想 —— 应用被冻结或退出后，
 *      由系统服务代理触发。但**华为真机对第三方应用有管控**，
 *      未获「代理提醒使用权限」时配额为 0，调用会抛 1700002。
 *   2) 应用内定时器 + 普通通知（notificationManager）：普通通知是确定可用的，
 *      由应用自己按时间检查并发布通知。代价是必须应用进程存活
 *      （前台或短暂后台），因此适合作为受管控设备上的降级方案。
 *
 * 策略：先探测代理提醒是否可用（首次发布试一条并回滚），
 *   可用 → 走代理提醒；不可用 → 自动降级到应用内定时器。
 *   两条通道共用同一套「排期」计算结果，保证课程与时间一致。
 */
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SectionTimeStore, SectionTime } from './SectionTimeStore';
import { Timetable } from '../model/Models';
import { PendingNotice, SectionStart, ReminderPlan } from '../model/ReminderPlan';
import { Logger } from '../common/Logger';
import { APP_BUNDLE_NAME } from '../common/Constants';

/** 通知 id 基址，避免与其它通知冲突 */
const NOTIFY_BASE_ID: number = 20000;

export class ClassNotifier {
  /** 应用内定时器句柄 */
  private static timerId: number = -1;
  /** 计划中的通知（按触发时间升序） */
  private static pending: PendingNotice[] = [];
  /** 已通知过的键，避免重复提醒 */
  private static fired: string[] = [];
  /** 是否走代理提醒（探测结果） */
  private static agentOk: boolean = false;
  /** 通道描述，供界面显示 */
  private static channelText: string = '未初始化';
  /** 是否走代理提醒（探测结果） */
  /** 续排所需的原始参数（startInAppChannel 时记住） */
  private static srcTimetable: Timetable | null = null;
  private static srcStartMonday: string = '';
  private static srcAdvance: number = 15;
  private static srcMaxWeeks: number = 30;
  /** 上次构建排期的时刻，用于按 24 小时节奏续排 */
  private static lastBuildAt: number = 0;
  /** 通知 id 的自增计数器（不复用，见 notify 中的说明） */
  private static nextNotifyId: number = 0;
  /** 上次 publishAgent 因上限/失败而未能发布的条数（供界面如实提示） */
  private static agentOverLimit: number = 0;
  /**
   * 代理提醒探测失败的**真实错误码**（0 = 未探测或成功）。
   *
   * 为什么要留它：早先失败时界面直接断言「系统未向第三方应用开放代理提醒」，
   * 而那句是从结果倒推的猜测 —— 权限未授予、通知槽不可用、触发时刻非法
   * 都会走到同一个分支，却给出同一个结论。排查时看不到码就只能猜。
   */
  private static agentErrCode: number = 0;

  static channel(): string {
    return ClassNotifier.channelText;
  }

  // ==================== 探测 ====================

  /**
   * 探测代理提醒是否可用。
   * 用一条 1 分钟后的倒计时提醒试发，成功后立即取消。
   */
  static async probeAgent(): Promise<boolean> {
    const req: reminderAgentManager.ReminderRequestTimer = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
      triggerTimeInSeconds: 60,
      title: '探测',
      content: '探测代理提醒可用性',
      ringDuration: 1,
      slotType: notificationManager.SlotType.SERVICE_INFORMATION
    };
    try {
      const id: number = await reminderAgentManager.publishReminder(req);
      try {
        await reminderAgentManager.cancelReminder(id);
      } catch (e) {
        // 忽略
      }
      ClassNotifier.agentOk = true;
      ClassNotifier.agentErrCode = 0;
      return true;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      const code: number = (err !== undefined && err.code !== undefined) ? err.code : -1;
      Logger.warn('probeAgent failed: code=' + code);
      ClassNotifier.agentOk = false;
      ClassNotifier.agentErrCode = code;
      return false;
    }
  }

  /** 探测失败的原始错误码（0 = 成功或未探测）；供界面如实展示 */
  static agentErrorCode(): number {
    return ClassNotifier.agentErrCode;
  }

  static agentAvailable(): boolean {
    return ClassNotifier.agentOk;
  }

  /** 上次代理提醒因上限/失败未发布的条数 */
  static overLimit(): number {
    return ClassNotifier.agentOverLimit;
  }

  /** 确保通知通道已建立 */
  private static async ensureSlot(): Promise<void> {
    try {
      await notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION);
    } catch (e) {
      // 已存在时会抛错，忽略
    }
  }

  // ==================== 排期（两条通道共用） ====================

  /**
   * 由课表生成未来 7 天的「上课通知」列表。
   * 只排未来 7 天，因为应用内定时器方案需要应用存活，
   * 时间跨度太大不现实；代理提醒可用时则由系统长期托管。
   *
   * 具体算法在 ReminderPlan（纯计算、可单测），这里只负责把
   * 用户配置的作息时间翻译成它要的形式。
   */
  static buildUpcoming(timetable: Timetable, startMonday: string,
    advanceMinutes: number, maxWeeks: number): PendingNotice[] {
    const times: SectionTime[] = SectionTimeStore.all();
    const sections: SectionStart[] = [];
    for (let i = 0; i < times.length; i++) {
      const t: SectionTime = times[i];
      sections.push(new SectionStart(t.label, t.start, t.startMinutes()));
    }
    return ReminderPlan.buildUpcoming(timetable, startMonday, advanceMinutes,
      maxWeeks, sections, Date.now());
  }

  // ==================== 应用内定时器通道 ====================

  /**
   * 启动应用内定时器（每 10 秒检查一次是否有到点的课）。
   *
   * 会记住课表与参数：排期窗口只有 7 天，必须能在窗口用尽后**自动续排**，
   * 否则应用连续运行超过 7 天后会静默停止提醒（见 tick 中的续排逻辑）。
   */
  static startInAppChannel(timetable: Timetable, startMonday: string,
    advanceMinutes: number, maxWeeks: number): number {
    ClassNotifier.stopInAppChannel();
    // 记住参数用于续排（stopInAppChannel 会清掉它们，所以放在它之后赋值）
    ClassNotifier.srcTimetable = timetable;
    ClassNotifier.srcStartMonday = startMonday;
    ClassNotifier.srcAdvance = advanceMinutes;
    ClassNotifier.srcMaxWeeks = maxWeeks;
    ClassNotifier.pending = ClassNotifier.buildUpcoming(timetable, startMonday, advanceMinutes, maxWeeks);
    ClassNotifier.lastBuildAt = Date.now();
    ClassNotifier.channelText = '应用内提醒（' + ClassNotifier.pending.length.toString() + ' 节待提醒）';
    Logger.info('in-app channel started: ' + ClassNotifier.pending.length + ' pending');

    ClassNotifier.tick();
    ClassNotifier.ensureTimer();
    return ClassNotifier.pending.length;
  }

  static stopInAppChannel(): void {
    if (ClassNotifier.timerId >= 0) {
      clearInterval(ClassNotifier.timerId);
      ClassNotifier.timerId = -1;
    }
    ClassNotifier.pending = [];
    ClassNotifier.fired = [];
    ClassNotifier.srcTimetable = null;
    ClassNotifier.srcStartMonday = '';
  }

  /**
   * 续排：用记住的课表与参数重新生成未来 7 天的排期。
   * 排期窗口是 7 天，应用长期存活时必须周期性重建，
   * 否则窗口过后 pending 清空、定时器空转，用户以为提醒开着却收不到通知。
   */
  private static rebuildIfNeeded(): void {
    if (ClassNotifier.srcTimetable === null || ClassNotifier.srcStartMonday.length === 0) {
      return;
    }
    // 每 24 小时重建一次，既保证窗口连续，也不会过于频繁
    const REBUILD_INTERVAL: number = 24 * 60 * 60 * 1000;
    if (Date.now() - ClassNotifier.lastBuildAt < REBUILD_INTERVAL) {
      return;
    }
    const tt: Timetable | null = ClassNotifier.srcTimetable;
    if (tt === null) {
      return;
    }
    const fresh: PendingNotice[] = ClassNotifier.buildUpcoming(tt,
      ClassNotifier.srcStartMonday, ClassNotifier.srcAdvance, ClassNotifier.srcMaxWeeks);
    // 保留还没到点的旧条目与新条目合并去重（避免边界上漏排）
    const merged: PendingNotice[] = [];
    const seen: string[] = [];
    const push = (p: PendingNotice) => {
      if (seen.indexOf(p.key) < 0) {
        seen.push(p.key);
        merged.push(p);
      }
    };
    for (let i = 0; i < ClassNotifier.pending.length; i++) {
      push(ClassNotifier.pending[i]);
    }
    for (let i = 0; i < fresh.length; i++) {
      push(fresh[i]);
    }
    merged.sort((a: PendingNotice, b: PendingNotice) => a.at - b.at);
    ClassNotifier.pending = merged;
    ClassNotifier.lastBuildAt = Date.now();
    Logger.info('in-app schedule rebuilt: ' + merged.length + ' pending');
  }

  /** 检查一次是否有到点需要通知的课 */
  private static tick(): void {
    ClassNotifier.rebuildIfNeeded();
    const now: number = Date.now();
    const keep: PendingNotice[] = [];
    for (let i = 0; i < ClassNotifier.pending.length; i++) {
      const p: PendingNotice = ClassNotifier.pending[i];
      // 已到点：发出通知（允许一定迟到，避免定时器抖动导致漏发）
      if (p.at <= now) {
        if (!ClassNotifier.alreadyFired(p.key)) {
          // 不阻塞 tick：通知发送失败不应影响后续排期
          ClassNotifier.notify(p);
          ClassNotifier.fired.push(p.key);
        }
        continue;
      }
      keep.push(p);
    }
    ClassNotifier.pending = keep;
    ClassNotifier.trimFired();
  }

  /**
   * 限制已发记录的长度。
   *
   * fired 里的 key 含日期，只会不断增加（应用长期开着会一直涨）。
   * 排期窗口只有 7 天，保留最近 200 条足够覆盖去重需求，
   * 超出就丢掉最早的，避免无界增长。
   */
  private static trimFired(): void {
    const LIMIT: number = 200;
    if (ClassNotifier.fired.length > LIMIT) {
      ClassNotifier.fired = ClassNotifier.fired.slice(ClassNotifier.fired.length - LIMIT);
    }
  }

  private static alreadyFired(key: string): boolean {
    for (let i = 0; i < ClassNotifier.fired.length; i++) {
      if (ClassNotifier.fired[i] === key) {
        return true;
      }
    }
    return false;
  }

  /** 发布一条上课通知 */
  private static async notify(p: PendingNotice): Promise<void> {
    try {
      await ClassNotifier.ensureSlot();
      // 通知 id 必须唯一，且不能随 fired 长度变化而回绕复用。
      //
      // 早先用 `NOTIFY_BASE_ID + fired.length % 1000`，有两个问题：
      //   1. tick() 对同一时刻到点的多条课是同步连续调用 notify()，
      //      而 notify 是 async —— 两条通知在 await ensureSlot() 之后
      //      读到的 fired.length 很可能相同，于是拿到同一个 id，
      //      后发的把先发的覆盖掉，用户只看到一条提醒；
      //   2. trimFired() 截断后 id 会回绕，复用已被系统占用的 id。
      // 改为单调自增计数器取模，保证长期运行也不会撞号。
      ClassNotifier.nextNotifyId = (ClassNotifier.nextNotifyId + 1) % 1000000;
      // 不显式指定 slotType：NotificationRequest 上该字段的类型来自
      // reminder 模块引用的 notification 命名空间，与 notificationManager 的
      // SlotType 枚举不是同一类型，显式赋值会报类型不匹配；用默认通道即可。
      const req: notificationManager.NotificationRequest = {
        id: NOTIFY_BASE_ID + ClassNotifier.nextNotifyId,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: '即将上课：' + p.title, text: p.content }
        }
      };
      await notificationManager.publish(req);
      Logger.info('class notified: ' + p.title);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.warn('notify failed: code=' + err.code);
    }
  }

  /**
   * 排一条 30 秒后的测试通知，用于验证「应用内提醒」链路真的能弹出通知。
   * 用户日后也可用它自检；不依赖课表与开学日期。
   */
  static scheduleTestNotification(): void {
    const at: number = Date.now() + 30 * 1000;
    const p: PendingNotice = new PendingNotice();
    p.at = at;
    p.title = '测试课程';
    p.content = '这是一条测试提醒，看到即表示上课提醒可用';
    p.key = 'test-' + at.toString();
    ClassNotifier.pending.push(p);
    ClassNotifier.pending.sort((a: PendingNotice, b: PendingNotice) => a.at - b.at);
    // 无论是否已有定时器，都用同一个入口确保「只存在一个定时器」，
    // 否则重复点击会叠加多个定时器，导致同一条提醒被发多次。
    ClassNotifier.ensureTimer();
    // 立即检查一次，让 30 秒内的测试通知尽快发出
    ClassNotifier.tick();
    ClassNotifier.channelText = '已排一条测试提醒（约 30 秒后，请下拉通知栏查看）';
    Logger.info('test notification scheduled at ' + at);
  }

  /** 确保全局只有一个检查定时器 */
  private static ensureTimer(): void {
    if (ClassNotifier.timerId >= 0) {
      return;
    }
    // 10 秒粒度：上课提醒对秒级精度不敏感，但也不能太粗，
    // 否则用户会觉得「到点了却没提醒」。
    ClassNotifier.timerId = setInterval(() => {
      ClassNotifier.tick();
    }, 10000);
  }

  // ==================== 代理提醒通道 ====================

  /** 用代理提醒发布未来 7 天的上课提醒 */
  static async publishAgent(timetable: Timetable, startMonday: string,
    advanceMinutes: number, maxWeeks: number, ringDuration: number,
    snoozeTimes: number, snoozeInterval: number, limit: number): Promise<number> {
    const list: PendingNotice[] = ClassNotifier.buildUpcoming(
      timetable, startMonday, advanceMinutes, maxWeeks);
    ClassNotifier.agentOverLimit = 0;
    let n: number = 0;
    for (let i = 0; i < list.length; i++) {
      // 代理提醒有条数上限（单个普通应用最多 30 条），
      // 达到上限就停止并如实回报剩余数量，而不是安静地少发。
      if (n >= limit) {
        ClassNotifier.agentOverLimit = list.length - n;
        Logger.warn('agent reminder limit reached: published=' + n +
          ' skipped=' + ClassNotifier.agentOverLimit);
        break;
      }
      const p: PendingNotice = list[i];
      const d: Date = new Date(p.at);
      const dt: reminderAgentManager.LocalDateTime = {
        year: d.getFullYear(), month: d.getMonth() + 1, day: d.getDate(),
        hour: d.getHours(), minute: d.getMinutes()
      };
      const req: reminderAgentManager.ReminderRequestCalendar = {
        reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: dt,
        title: p.title,
        content: p.content,
        ringDuration: ringDuration,
        snoozeTimes: snoozeTimes,
        timeInterval: snoozeInterval < 30 ? 30 : snoozeInterval,
        slotType: notificationManager.SlotType.SERVICE_INFORMATION,
        wantAgent: { pkgName: APP_BUNDLE_NAME, abilityName: 'EntryAbility' },
        tapDismissed: true
      };
      try {
        await reminderAgentManager.publishReminder(req);
        n++;
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        Logger.warn('publishReminder failed: ' + err.code);
        // 失败时如实记录剩余条数，便于界面提示「因系统限制只发布了一部分」
        ClassNotifier.agentOverLimit = list.length - n;
        break;
      }
    }
    ClassNotifier.channelText = '系统代理提醒（' + n.toString() + ' 条）';
    return n;
  }
}
