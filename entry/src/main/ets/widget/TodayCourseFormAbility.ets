/*
 * TodayCourseFormAbility：桌面「今日课程」卡片的 FormExtensionAbility
 *
 * 职责很窄：被系统要求创建/刷新卡片时，把主应用写好的快照读出来，
 * 通过 formBindingData 交给卡片渲染。
 *
 * 快照由主应用在课表变化时写入（见 CardSnapshotStore），
 * 卡片侧不联网、不解析、也不依赖登录态。
 */
import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { Want, Context } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PrefStore } from '../data/PrefStore';
import { FormIdRegistry } from '../data/FormIdRegistry';
import { ContextHolder } from '../common/ContextHolder';
import { KEY_CARD_SNAPSHOT, KEY_CARD_WEEK } from '../data/CardSnapshotStore';
import { Logger } from '../common/Logger';

/** 2*2 小尺寸显示 2 行，4*2/4*4 显示更多 */
const ROWS_2X2: number = 2;
const ROWS_4X2: number = 4;
const ROWS_4X4: number = 6;

export default class TodayCourseFormAbility extends FormExtensionAbility {
  /** 创建卡片 */
  onAddForm(want: Want): formBindingData.FormBindingData {
    // 卡片进程里 ContextHolder 是空的（UIAbility.onCreate 不会跑），
    // 而登记 formId 需要写 preferences —— 这里先把自己的 context 注入进去。
    ContextHolder.setForm(this.context);
    // 关键：把 formId 记下来。
    // 卡片渲染的是 formBindingData 注入的数据，主应用改了课表后若不主动
    // updateForm(formId, …)，卡片不会自己重读快照 —— 这就是「应用内加课、
    // 卡片不变，要删掉重加」的根因。SDK 文档也要求把表单信息持久化保存。
    const formId: string = TodayCourseFormAbility.formIdOf(want);
    if (formId.length > 0) {
      FormIdRegistry.add(formId).catch(() => {
        Logger.warn('form id register failed');
      });
    } else {
      Logger.warn('onAddForm: form id missing in want');
    }
    if (formId.length > 0) {
      TodayCourseFormAbility.scheduleNext(formId,
        TodayCourseFormAbility.minutesToNextBoundary(this.context));
    }
    Logger.info('form onAddForm');
    return TodayCourseFormAbility.buildBindingData(this.context, want);
  }

  /** 系统按周期或主动触发的刷新 */
  onUpdateForm(formId: string): void {
    ContextHolder.setForm(this.context);
    // 顺手补登记：本机实测 `getPublishedRunningFormInfos` 不可用（返回 801），
    // 因此主应用无法自行「发现」已存在的卡片。onUpdateForm 是系统送来 formId 的
    // 另一个时机，在这里登记，配合主应用侧的推送，老卡片也能在下一轮生效。
    if (formId !== undefined && formId !== null && formId.length > 0) {
      FormIdRegistry.add(formId).catch(() => {
        Logger.warn('form id register on update failed');
      });
    }
    // 行数用 2*2 的初值即可：卡片拿到尺寸后会自己实测覆盖，
    // 这里写死 4 会让 2*2 的卡片被要求画 4 行（早先的 bug）。
    const data: formBindingData.FormBindingData =
      TodayCourseFormAbility.buildBindingDataWithRows(this.context, ROWS_2X2);
    formProvider.updateForm(formId, data).catch((err: BusinessError) => {
      Logger.warn('updateForm failed: code=' + err.code);
    });
    // 每次被刷新都顺手把下一次排上，保证刷新链不断
    TodayCourseFormAbility.scheduleNext(formId,
      TodayCourseFormAbility.minutesToNextBoundary(this.context));
  }

  /** 卡片被删除 */
  onRemoveForm(formId: string): void {
    // 注销 formId，避免主应用继续对已删除的卡片做无用推送
    FormIdRegistry.remove(formId).catch(() => {
      Logger.warn('form id unregister failed');
    });
    Logger.info('form removed: ' + formId);
  }

  /** 从 want 参数里取出 formId（系统创建卡片时带上） */
  private static formIdOf(want: Want): string {
    try {
      const params = want.parameters;
      if (params === undefined || params === null) {
        return '';
      }
      const id: Object | undefined = params[formInfo.FormParam.IDENTITY_KEY];
      if (id === undefined || id === null) {
        return '';
      }
      return id.toString();
    } catch (e) {
      return '';
    }
  }

  /**
   * 组装绑定数据。
   * 尺寸从 want 参数里读（系统在创建时会带上 DIMENSION_KEY），
   * 不同尺寸给不同的行数上限，避免小卡片被内容撑破。
   */
  private static buildBindingData(ctx: Context, want: Want): formBindingData.FormBindingData {
    let rows: number = ROWS_2X2;
    try {
      const params = want.parameters;
      if (params !== undefined && params !== null) {
        const dim: Object | undefined = params[formInfo.FormParam.DIMENSION_KEY];
        if (dim !== undefined && dim !== null) {
          rows = TodayCourseFormAbility.rowsOf(dim as number);
        }
      }
    } catch (e) {
      // 参数缺失时用默认值，不影响卡片创建
    }
    return TodayCourseFormAbility.buildBindingDataWithRows(ctx, rows);
  }

  private static rowsOf(dimension: number): number {
    // FormDimension: 1=1*2, 2=2*2, 3=2*4, 4=4*4, 5=1*1 ...
    switch (dimension) {
      case 1: return ROWS_2X2;
      case 2: return ROWS_2X2;
      case 3: return ROWS_4X2;
      case 4: return ROWS_4X4;
      default: return ROWS_2X2;
    }
  }

  /**
   * 读快照与周级载荷，生成绑定数据。
   *
   * 读不到（用户没打开过应用）时给出空值，卡片会显示引导文案。
   *
   * `maxRows` 只是一个**初值**：卡片拿到实际尺寸后会用 onAreaChange 实测并
   * 覆盖它（见 TodayCourseCard 的说明）。这里给的值只在首帧生效。
   */
  private static buildBindingDataWithRows(ctx: Context,
    rows: number): formBindingData.FormBindingData {
    const snapshot: string = PrefStore.readTextSync(ctx, KEY_CARD_SNAPSHOT);
    const week: string = PrefStore.readTextSync(ctx, KEY_CARD_WEEK);
    const obj: Record<string, string> = {
      'snapshot': snapshot,
      'week': week,
      'maxRows': rows.toString()
    };
    return formBindingData.createFormBindingData(obj);
  }

  /**
   * 安排下一次自动刷新（节次边界或零点）。
   *
   * ===== 为什么必须自己排（与 Flutter 端 AlarmManager 同一思路）=====
   * 卡片内容是「今天第几节课、哪节已上完、下一节是什么」，这些**只在节次
   * 起止时刻**会变。平台给的 `updateDuration` 最短 30 分钟且是批量调度，
   * 一节课 10:00 下课后状态可能拖到 11:00 才更新 —— 用户看到的就是
   * 「卡片和实际时间对不上」。
   *
   * `setFormNextRefreshTime(formId, minute)` 是鸿蒙版的等价能力：
   * 指定「多少分钟后刷新这张卡片」。**下限 5 分钟**，因此精度不如
   * Flutter 的 AlarmManager 精确（那边能卡到秒），但相比 30 分钟已是量级改善。
   *
   * 取「到下一个节次起止时刻」与「到次日零点」中更近的那个。
   */
  private static scheduleNext(formId: string, minute: number): void {
    // 下限 5：小于 5 会被系统拒绝（401）
    const m: number = minute < 5 ? 5 : minute;
    try {
      formProvider.setFormNextRefreshTime(formId, m).catch((err: BusinessError) => {
        Logger.warn('setFormNextRefreshTime failed: code=' + err.code);
      });
    } catch (e) {
      Logger.warn('setFormNextRefreshTime unavailable');
    }
  }

  /**
   * 距离下一个「需要更新卡片」的时刻还有几分钟。
   *
   * 候选：当天的节次起止时刻里第一个还没到的；都过了就取次日第一个节次，
   * 再与次日零点比较取更近者（跨天切换必须及时）。
   *
   * 时刻表从周级载荷里读（用户自定义过就用自定义值）；读不到就用内置官方值 ——
   * 这样即使卡片是在「应用从未打开过」的状态下被创建，这个函数也总能返回
   * 一个合理值，不会让刷新链断掉。
   */
  private static minutesToNextBoundary(ctx: Context): number {
    const mins: number[] = [];
    try {
      const raw: string = PrefStore.readTextSync(ctx, KEY_CARD_WEEK);
      if (raw.length > 0) {
        const w: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
        const secs: Object | undefined = w['sections'];
        const ends: Object | undefined = w['sectionEnds'];
        TodayCourseFormAbility.collectMinutes(secs, mins);
        TodayCourseFormAbility.collectMinutes(ends, mins);
      }
    } catch (e) {
      // 落到下面的内置值
    }
    if (mins.length === 0) {
      // 内置官方时刻（与 CardsnapshotStore 的默认作息一致）
      const def: number[] = [510, 600, 620, 710, 840, 930, 950, 1040, 1120, 1265];
      for (let i = 0; i < def.length; i++) {
        mins.push(def[i]);
      }
    }
    mins.sort((a: number, b: number) => a - b);

    const now: Date = new Date();
    const nowMin: number = now.getHours() * 60 + now.getMinutes();
    for (let i = 0; i < mins.length; i++) {
      if (mins[i] > nowMin) {
        return mins[i] - nowMin;
      }
    }
    // 今天的边界都过了 → 次日第一个边界，与零点取更近者
    const toMidnight: number = 24 * 60 - nowMin;
    const toFirst: number = toMidnight + mins[0];
    return toMidnight < toFirst ? toMidnight : toFirst;
  }

  /** 把 "HH:mm" 数组里的时刻转成分钟数塞进 out（解析不出的跳过） */
  private static collectMinutes(arr: Object | undefined, out: number[]): void {
    if (arr === undefined || arr === null) {
      return;
    }
    const list: string[] = arr as string[];
    for (let i = 0; i < list.length; i++) {
      const t: string = list[i];
      if (t === undefined || t === null || t.length === 0) {
        continue;
      }
      const at: number = t.indexOf(':');
      if (at <= 0) {
        continue;
      }
      const h: number = parseInt(t.substring(0, at), 10);
      const m: number = parseInt(t.substring(at + 1), 10);
      if (!isNaN(h) && !isNaN(m)) {
        out.push(h * 60 + m);
      }
    }
  }
}
