/*
 * ReminderService：上课提醒
 *
 * 机制说明（为什么用代理提醒）：
 *   使用 @kit.BackgroundTasksKit 的 reminderAgentManager。按官方说明，
 *   应用被冻结或退出后，定时提醒由系统服务代理触发，因此关掉应用也能收到提醒。
 *
 * 关键约束（已核实）：
 *   - 单个普通应用最多 30 条提醒（超出会抛 1700002），
 *     因此按「课程 × 星期 × 节次」聚合，而不是每次上课发一条；
 *   - 必须先调用 notificationManager.requestEnableNotification 获得通知授权，
 *     否则抛 1700001；
 *   - 需要 ohos.permission.PUBLISH_AGENT_REMINDER（已在 module.json5 声明）；
 *   - daysOfWeek 取值 1=周一 … 7=周日。
 *
 * 排期方式：对每门课发布一条 ReminderRequestCalendar：
 *   dateTime    = 该课首次上课（起始周）那天的「上课时间 - 提前量」
 *   daysOfWeek  = [星期几]
 *   endDateTime = 该课最后一次上课（结束周）那天，从而把重复限制在周次区间内
 *   单双周     = 通过 addExcludeDate 排除不符合的周
 */
import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppState } from './AppState';
import { PrefStore } from './PrefStore';
import { ClassNotifier } from './ClassNotifier';
import { SectionTimeStore, SectionTime } from './SectionTimeStore';
import { WeekCalc, DateParts } from '../common/WeekCalc';
import { WeekService } from './WeekService';
import { Timetable, CellData, CourseEntry } from '../model/Models';
import { Logger } from '../common/Logger';
import {
  MAX_WEEKS, KEY_REMINDER_ON, KEY_REMINDER_ADVANCE, KEY_REMINDER_RING,
  KEY_REMINDER_SNOOZE_TIMES, KEY_REMINDER_SNOOZE_INTERVAL, APP_BUNDLE_NAME
} from '../common/Constants';

/** 代理提醒数量上限（官方文档：单个普通应用不超过 30 个） */
export const REMINDER_LIMIT: number = 30;

/** 提醒配置 */
export class ReminderConfig {
  enabled: boolean = false;
  /** 提前多少分钟提醒 */
  advanceMinutes: number = 15;
  /** 响铃时长（秒） */
  ringDuration: number = 5;
  /** 稍后提醒次数 */
  snoozeTimes: number = 2;
  /** 稍后提醒间隔（秒），最小 30 */
  snoozeInterval: number = 300;
}


/** 发布结果 */
export class PublishOutcome {
  published: number = 0;
  /** 因为超过上限而未发布的条数 */
  overLimit: number = 0;
  /** 是否缺少通知授权 */
  needPermission: boolean = false;
  message: string = '';

  constructor(published: number, overLimit: number, needPermission: boolean, message: string) {
    this.published = published;
    this.overLimit = overLimit;
    this.needPermission = needPermission;
    this.message = message;
  }
}

export class ReminderService {
  private static config: ReminderConfig | null = null;

  // ==================== 配置读写 ====================

  static async loadConfig(): Promise<ReminderConfig> {
    if (ReminderService.config !== null) {
      return ReminderService.config;
    }
    const c: ReminderConfig = new ReminderConfig();
    c.enabled = (await PrefStore.getText(KEY_REMINDER_ON)) === '1';
    c.advanceMinutes = ReminderService.intOf(await PrefStore.getText(KEY_REMINDER_ADVANCE), 15);
    c.ringDuration = ReminderService.intOf(await PrefStore.getText(KEY_REMINDER_RING), 5);
    c.snoozeTimes = ReminderService.intOf(await PrefStore.getText(KEY_REMINDER_SNOOZE_TIMES), 2);
    c.snoozeInterval = ReminderService.intOf(await PrefStore.getText(KEY_REMINDER_SNOOZE_INTERVAL), 300);
    ReminderService.config = c;
    return c;
  }

  static async saveConfig(c: ReminderConfig): Promise<void> {
    ReminderService.config = c;
    await PrefStore.putText(KEY_REMINDER_ON, c.enabled ? '1' : '0');
    await PrefStore.putText(KEY_REMINDER_ADVANCE, c.advanceMinutes.toString());
    await PrefStore.putText(KEY_REMINDER_RING, c.ringDuration.toString());
    await PrefStore.putText(KEY_REMINDER_SNOOZE_TIMES, c.snoozeTimes.toString());
    await PrefStore.putText(KEY_REMINDER_SNOOZE_INTERVAL, c.snoozeInterval.toString());
  }

  private static intOf(s: string, def: number): number {
    const v: number = parseInt(s, 10);
    return isNaN(v) ? def : v;
  }

  // ==================== 权限 ====================

  /**
   * 确认通知已开启。
   *
   * publishReminder 的硬前提：通知未启用时会失败。
   * 官方把「未开启通知」与「未获代理提醒使用权限」都归到 1700002 / 1700001，
   * 因此这里必须确保通知真的被打开，并把结果如实回传给界面。
   */
  static async ensureNotificationEnabled(context: common.UIAbilityContext): Promise<boolean> {
    try {
      if (notificationManager.isNotificationEnabledSync()) {
        return true;
      }
    } catch (e) {
      // 同步接口不可用时退化为异步查询
    }
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (enabled) {
        return true;
      }
      // 只能在 UI 加载后调用；若用户拒绝过，则需要去系统设置里手动开启
      await notificationManager.requestEnableNotification(context);
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.warn('requestEnableNotification failed: ' + err.code);
      return false;
    }
  }

  /** 通知是否已开启（供界面显示状态） */
  static async notificationOn(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (e) {
      return false;
    }
  }

  /**
   * 打开系统的通知设置页。
   * 用户若拒绝过一次通知授权，就无法再用 requestEnableNotification 弹窗，
   * 只能引导其去系统设置里手动开启。
   */
  static async openSystemNotificationSettings(context: common.UIAbilityContext): Promise<void> {
    try {
      await notificationManager.openNotificationSettings(context);
    } catch (e) {
      Logger.warn('openNotificationSettings failed');
    }
  }

  // ==================== 排期计算 ====================

  /** "HH:mm" 平移若干分钟 */
  static shiftMinutes(hhmm: string, delta: number): string {
    const total: number = SectionTimeStore.toMinutes(hhmm);
    if (total < 0) {
      return hhmm;
    }
    let m: number = total + delta;
    // 跨日则收敛到当天边界，避免生成非法时刻
    if (m < 0) {
      m = 0;
    }
    if (m > 23 * 60 + 59) {
      m = 23 * 60 + 59;
    }
    const h: number = Math.floor(m / 60);
    const mm: number = m % 60;
    return (h < 10 ? '0' + h.toString() : h.toString()) + ':' +
      (mm < 10 ? '0' + mm.toString() : mm.toString());
  }

  // ==================== 发布 / 取消 ====================

  /**
   * 依当前课表重新排布提醒。
   *
   * 双通道策略：
   *   先探测系统代理提醒是否可用（某些华为设备对第三方应用有管控，配额为 0），
   *   可用 → 发布代理提醒（应用退出后仍能触发）；
   *   不可用 → 自动降级为应用内定时器 + 普通通知。
   * 两条通道的判断与降级对用户透明，界面会显示实际生效的通道。
   */
  static async publishAll(context: common.UIAbilityContext): Promise<PublishOutcome> {
    const cfg: ReminderConfig = await ReminderService.loadConfig();
    if (!cfg.enabled) {
      return new PublishOutcome(0, 0, false, '未开启上课提醒');
    }

    // 1. 通知授权（两条通道都需要）
    const ok: boolean = await ReminderService.ensureNotificationEnabled(context);
    if (!ok) {
      return new PublishOutcome(0, 0, true, '需要先允许通知，才能收到上课提醒');
    }

    // 2. 依赖：课表 + 学期开始日期 + 节次作息
    await SectionTimeStore.load();
    await WeekService.load();
    const startMonday: string = WeekService.start();
    if (startMonday.length === 0) {
      return new PublishOutcome(0, 0, false, '请先在「学期与周次」里设置开学日期');
    }
    const timetable: Timetable | null = AppState.timetable;
    if (timetable === null) {
      return new PublishOutcome(0, 0, false, '请先打开一次课表');
    }

    // 3. 清掉两条通道的旧安排，避免重复提醒
    await ReminderService.cancelAll();
    ClassNotifier.stopInAppChannel();

    // 4. 先试系统代理提醒
    const agentOk: boolean = await ClassNotifier.probeAgent();
    if (agentOk) {
      const n: number = await ClassNotifier.publishAgent(timetable, startMonday,
        cfg.advanceMinutes, MAX_WEEKS, cfg.ringDuration, cfg.snoozeTimes,
        cfg.snoozeInterval, REMINDER_LIMIT);
      if (n > 0) {
        // 如实告知是否触达系统上限（单个普通应用最多 30 条代理提醒），
        // 否则用户会以为整学期都排好了，实际只排了一部分。
        const skipped: number = ClassNotifier.overLimit();
        let msg: string = '已通过「系统代理提醒」发布 ' + n.toString() +
          ' 条上课提醒（应用关闭后仍会提醒）';
        if (skipped > 0) {
          msg = msg + '；另有 ' + skipped.toString() +
            ' 条超出单应用 ' + REMINDER_LIMIT.toString() + ' 条上限未发布，' +
            '可用「同步到系统日历」覆盖完整学期';
        }
        Logger.info('reminders via agent: ' + n + ' skipped=' + skipped);
        return new PublishOutcome(n, skipped, false, msg);
      }
    }

    // 5. 降级：应用内定时器 + 普通通知
    const m: number = ClassNotifier.startInAppChannel(timetable, startMonday,
      cfg.advanceMinutes, MAX_WEEKS);
    // 带上真实错误码：早先这句写死了「系统未向第三方应用开放」，而权限未授予、
    // 通知槽不可用、触发时刻非法都会走到这里，同一个结论会把人带偏。
    const code: number = ClassNotifier.agentErrorCode();
    const why: string = code === 0 ? '' : '（系统返回 ' + code.toString() + '）';
    const msg2: string = '系统代理提醒不可用' + why + '，已降级为应用内提醒：' +
      '未来 7 天有 ' + m.toString() + ' 节课待提醒（需保持应用运行）';
    Logger.info('reminders via in-app channel: ' + m + ' agentErr=' + code);
    return new PublishOutcome(m, 0, false, msg2);
  }

  /** 当前生效的提醒通道说明 */
  static channelText(): string {
    return ClassNotifier.channel();
  }

  /**
   * 诊断：区分「代理提醒被管控」与「通知本身不可用」。
   * 先试普通通知（立即发布一条），再试代理提醒。
   */
  static async diagnose(): Promise<string> {
    // 1. 普通通知是否可用
    let notifyText: string = '';
    try {
      const req: notificationManager.NotificationRequest = {
        id: 90001,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: '诊断通知', text: '能看到这条说明通知可用' }
        }
      };
      await notificationManager.publish(req);
      notifyText = '普通通知可用';
      try {
        await notificationManager.cancel(90001);
      } catch (e) {
        // 忽略
      }
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      notifyText = '普通通知不可用(code=' + err.code + ')';
    }

    // 2. 代理提醒是否可用
    const req2: reminderAgentManager.ReminderRequestTimer = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
      triggerTimeInSeconds: 60,
      title: '诊断提醒',
      content: '代理提醒可用',
      ringDuration: 3,
      slotType: notificationManager.SlotType.SERVICE_INFORMATION
    };
    let reminderText: string = '';
    try {
      const id: number = await reminderAgentManager.publishReminder(req2);
      try {
        await reminderAgentManager.cancelReminder(id);
      } catch (e) {
        // 忽略
      }
      reminderText = '代理提醒可用';
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      if (err.code === 1700002) {
        reminderText = '代理提醒被系统管控（1700002，配额为 0）';
      } else if (err.code === 1700001) {
        reminderText = '通知未开启（1700001）';
      } else {
        reminderText = '代理提醒失败(code=' + err.code + ')';
      }
    }

    return notifyText + '；' + reminderText;
  }

  /**
   * 取消本应用全部提醒：系统代理提醒 + 应用内定时器通道。
   *
   * 两条通道必须一起清。早先只调 cancelAllReminders()，结果「关了提醒仍会弹通知」——
   * 因为应用内通道是 ClassNotifier 用 setInterval 自己检查到点后发通知的，
   * 系统接口停不掉它。
   */
  static async cancelAll(): Promise<void> {
    ClassNotifier.stopInAppChannel();
    try {
      await reminderAgentManager.cancelAllReminders();
    } catch (e) {
      Logger.warn('cancelAllReminders failed');
    }
  }

  /** 当前已发布的提醒条数 */
  static async count(): Promise<number> {
    try {
      const list: reminderAgentManager.ReminderInfo[] = await reminderAgentManager.getAllValidReminders();
      return list.length;
    } catch (e) {
      return 0;
    }
  }
}
