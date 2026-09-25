/*
 * ContextHolder：集中持有应用上下文
 *
 * 为什么需要它：
 *   - getContext(this) 已废弃（@deprecated），且新版 ArkUI 推荐用 UIContext 取上下文
 *   - 在组件里取 context 存在版本差异（getUIContext().getHostContext() 为 API 12+）
 *   - preferences 与 window 都需要 Context
 * 因此由 EntryAbility 在 onCreate 时注入一次，其它模块统一从这里取，
 * 既避免废弃 API，也保证在 API 20 及以上行为一致。
 *
 * 为什么还要接受 FormExtensionContext：
 *   桌面卡片跑在**独立的 FormExtensionAbility 进程**里，那边的 onCreate 不会执行，
 *   ContextHolder 会一直是空的。而卡片侧同样要读写同一份 preferences
 *   （读快照、登记 formId）。因此卡片侧在 onAddForm/onUpdateForm 里
 *   把自己的 context 注入进来，让 PrefStore 在卡片进程内也能正常工作。
 *
 * 为什么 get() 仍返回 UIAbilityContext：
 *   多数调用方（window、各类业务代码）需要的是 UIAbilityContext。
 *   卡片进程注入的是 FormExtensionContext，两者在 preferences/资源访问所需的
 *   能力上是重叠的，因此这里用重载区分：
 *     - get()            → 只在上层是 UIAbilityContext 时返回它，否则 null
 *     - getAny()         → 返回原始上下文，供 PrefStore 这类只需要存储能力的模块使用
 *   这样既不改动既有调用方的类型，又能让卡片侧拿到上下文。
 */
import { common } from '@kit.AbilityKit';

export class ContextHolder {
  private static ui: common.UIAbilityContext | null = null;
  private static form: common.FormExtensionContext | null = null;

  /** 主应用入口注入 */
  static set(ctx: common.UIAbilityContext): void {
    ContextHolder.ui = ctx;
  }

  /** 卡片侧注入（FormExtensionAbility） */
  static setForm(ctx: common.FormExtensionContext): void {
    ContextHolder.form = ctx;
  }

  /** 只取 UIAbilityContext；卡片进程里为 null，调用方需自行兜底 */
  static get(): common.UIAbilityContext | null {
    return ContextHolder.ui;
  }

  /**
   * 取任意可用上下文（UIAbility 优先）。
   *
   * 供「只需要 preferences / 资源」的模块使用：这类模块在卡片进程里也要能工作，
   * 而卡片进程没有 UIAbilityContext。返回类型用 UNION 显式声明，
   * 调用方按需判断（PrefStore 只用 preferences，两者都适用）。
   */
  static getAny(): common.Context | null {
    if (ContextHolder.ui !== null) {
      return ContextHolder.ui;
    }
    if (ContextHolder.form !== null) {
      return ContextHolder.form;
    }
    return null;
  }

  /** 是否已注入任一上下文 */
  static ready(): boolean {
    return ContextHolder.ui !== null || ContextHolder.form !== null;
  }
}