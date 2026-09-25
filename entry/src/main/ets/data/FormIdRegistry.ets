/*
 * FormIdRegistry：记录所有已添加的桌面卡片 id
 *
 * ===== 为什么必须存 formId =====
 * 桌面卡片由 FormExtensionAbility 驱动，渲染时间短、也不适合联网。
 * 主应用把「今日课程」算好写进 preferences 快照（CardSnapshotStore），
 * 但**写快照不等于卡片会更新** —— 已经渲染着的卡片不会自己去读 preferences，
 * 它只认 `formProvider.updateForm(formId, data)` 推给它的数据。
 *
 * 没有这段代码时的现象：应用内加了课 → 快照是新的 → 卡片仍显示旧课程，
 * 直到系统按周期（本应用 updateDuration=2，约 60 分钟）触发 onUpdateForm；
 * 用户误以为功能坏了，只能「删掉卡片重新添加」——重新添加会走 onAddForm，
 * 才会重新读一次快照。
 *
 * SDK 对 `onAddForm` 的说明也明确要求：表单信息「必须作为持久化数据管理，
 * 供后续的表单获取、更新与删除使用」。本模块就是那份持久化数据。
 *
 * ===== 为什么要落盘而不是只放内存 =====
 * FormExtensionAbility 与主应用 UIAbility **可能不在同一个进程**，
 * 且卡片常常在主应用未运行时就已经存在。因此 formId 必须落盘，
 * 由两侧各自读写同一份 preferences。
 */
import { PrefStore } from './PrefStore';
import { Logger } from '../common/Logger';
import { KEY_CARD_FORM_IDS } from '../common/Constants';

export class FormIdRegistry {
  /** 内存缓存，避免每次刷新都读盘 */
  private static cache: string[] | null = null;

  /** 解析逗号分隔的 id 串（过滤空项） */
  private static parse(raw: string): string[] {
    const out: string[] = [];
    if (raw.length === 0) {
      return out;
    }
    const parts: string[] = raw.split(',');
    for (let i = 0; i < parts.length; i++) {
      const t: string = parts[i].trim();
      if (t.length > 0) {
        out.push(t);
      }
    }
    return out;
  }

  /** 读取全部已登记的卡片 id */
  static async ids(): Promise<string[]> {
    if (FormIdRegistry.cache !== null) {
      return FormIdRegistry.cache;
    }
    const raw: string = await PrefStore.getText(KEY_CARD_FORM_IDS);
    const list: string[] = FormIdRegistry.parse(raw);
    FormIdRegistry.cache = list;
    return list;
  }

  /**
   * 登记一个卡片 id（onAddForm 时调用）。
   * 已存在则不重复写入 —— onAddForm 可能因重新添加而重复触发。
   */
  static async add(formId: string): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    const list: string[] = await FormIdRegistry.ids();
    for (let i = 0; i < list.length; i++) {
      if (list[i] === formId) {
        return;
      }
    }
    list.push(formId);
    FormIdRegistry.cache = list;
    await PrefStore.putText(KEY_CARD_FORM_IDS, list.join(','));
    Logger.info('form id registered: ' + formId + ' (total ' + list.length.toString() + ')');
  }

  /** 注销一个卡片 id（onRemoveForm 时调用），避免对已删除的卡片做无用更新 */
  static async remove(formId: string): Promise<void> {
    const list: string[] = await FormIdRegistry.ids();
    const next: string[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i] !== formId) {
        next.push(list[i]);
      }
    }
    if (next.length === list.length) {
      return;
    }
    FormIdRegistry.cache = next;
    await PrefStore.putText(KEY_CARD_FORM_IDS, next.join(','));
    Logger.info('form id unregistered: ' + formId + ' (left ' + next.length.toString() + ')');
  }

  /**
   * 清空登记（退出登录时调用）。
   * 与快照一起清，避免换账号后旧卡片的 id 仍被用于推送。
   */
  static async clear(): Promise<void> {
    FormIdRegistry.cache = [];
    await PrefStore.putText(KEY_CARD_FORM_IDS, '');
  }

  /** 供单测/排查：当前登记数量 */
  static count(): number {
    return FormIdRegistry.cache === null ? 0 : FormIdRegistry.cache.length;
  }
}