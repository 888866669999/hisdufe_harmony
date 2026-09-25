/*
 * CardPusher：把最新的「今日课程」推给已经存在的桌面卡片
 *
 * ===== 为什么需要它（这就是「加了课卡片不变」的根修）=====
 * 主应用改了课表后，`CardSnapshotStore.refresh()` 只是把新快照写进 preferences。
 * 但桌面卡片**不会自己去读 preferences** —— 它渲染的是 formBindingData 注入的数据，
 * 只有 `formProvider.updateForm(formId, data)` 能把新数据推过去。
 *
 * 改造前全仓库**没有任何一处从主应用调用 updateForm**（唯一的调用在
 * FormExtensionAbility.onUpdateForm 里，是系统按周期触发的，本应用约 60 分钟一次）。
 * 于是应用内加课→卡片不变，用户只能删掉卡片重加（重新添加会走 onAddForm 重新读快照）。
 *
 * ===== 为什么单独成文件、且用动态 import =====
 * 本仓库踩过「静态导入缺失的 HMS 导出会在模块加载期抛 SyntaxError、把引用它的页面一起带崩」
 * 的坑（详见 README 的 PDF 闪退一节）。`@kit.FormKit` 的 formProvider 在个别设备/形态上
 * 可能不可用，因此这里不静态导入，由卡片链路在真正要推送时才 `await import()`。
 *
 * 另：本模块**不 import CardSnapshotStore**（后者依赖 AppState），由调用方把
 * 绑定数据算好传进来，避免形成循环依赖。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import formBindingData from '@ohos.app.form.formBindingData';
import formInfo from '@ohos.app.form.formInfo';
import { Logger } from '../common/Logger';

/** 推送结果，供日志与自检展示 */
export class PushOutcome {
  total: number = 0;
  ok: number = 0;

  constructor(total: number, ok: number) {
    this.total = total;
    this.ok = ok;
  }
}

/**
 * 卡片绑定数据。
 *
 * ArkTS 要求对象字面量必须对应显式声明的类型（arkts-no-untyped-obj-literals），
 * 因此这里定义一个具名类，而不是到处写匿名对象。
 * 字段名必须与卡片侧 `@LocalStorageProp('snapshot'/'maxRows'/'week')` 完全一致 ——
 * 名字对不上不会有任何报错，只是卡片读不到值（表现为一直空白）。
 */
export class CardBinding {
  /** 今日快照 JSON（旧版卡片与兜底用） */
  snapshot: string = '';
  /** 建议显示的行数（由主应用按卡片尺寸估算） */
  maxRows: string = '';
  /**
   * 周级载荷 JSON（新版卡片用它自己算「今天」）。
   *
   * 为空串时卡片退回 `snapshot` 那条老路径 —— 这样老卡片在升级瞬间
   * 仍有内容，不至于空白。
   */
  week: string = '';

  constructor(snapshot: string, maxRows: string, week: string) {
    this.snapshot = snapshot;
    this.maxRows = maxRows;
    this.week = week;
  }
}

/**
 * 动态加载 formProvider。
 *
 * 为什么直接 import `@ohos.app.form.formProvider` 而不是 `@kit.FormKit`：
 * 两者都是 `export default` 模块，但实测 `await import('@kit.FormKit')`
 * 得到的命名空间里既没有 `formProvider`、也没有 `default`（报
 * "FormKit exports missing"），kit 的再导出在动态 import 下拿不到。
 * 直接引 `@ohos.app.form.formProvider` 拿到的是该模块的 default 导出本身。
 *
 * 仍然坚持动态 import（而非静态）的原因与本仓库其它 HMS 依赖一致：
 * 静态导入缺失的导出会在**模块加载期**抛错，try/catch 拦不住。
 */
async function loadFormProvider(): Promise<FormProviderApi | null> {
  try {
    const m: FormProviderModule = await import('@ohos.app.form.formProvider');
    if (m === undefined || m === null) {
      return null;
    }
    const p: FormProviderApi | undefined = m.default;
    return (p !== undefined) ? p : null;
  } catch (e) {
    return null;
  }
}

/** @ohos.app.form.formProvider 的 default 导出形状（只声明用到的成员） */
interface FormProviderModule {
  default?: FormProviderApi;
}

interface FormProviderApi {
  updateForm(formId: string, data: formBindingData.FormBindingData): Promise<void>;
  getPublishedRunningFormInfos(): Promise<formInfo.RunningFormInfo[]>;
}

export class CardPusher {
  /**
   * 发现本应用当前所有在桌面上运行的卡片 id。
   *
   * 为什么需要这个「补救」路径：formId 是**卡片被创建时**才由 onAddForm 登记的。
   * 对于本次修复**之前就已经添加**的卡片，onAddForm 早已跑完，登记表里没有它们 ——
   * 只靠登记表的话，那些卡片仍收不到推送，用户还是得删掉重加一次。
   * 这里用系统的「已发布卡片」查询把它们找回来，让修复对老卡片同样生效，
   * 用户无需做任何操作。
   */
  static async discover(): Promise<string[]> {
    const fp: FormProviderApi | null = await loadFormProvider();
    if (fp === null) {
      return [];
    }
    try {
      const infos: formInfo.RunningFormInfo[] = await fp.getPublishedRunningFormInfos();
      const ids: string[] = [];
      if (infos === undefined || infos === null) {
        return ids;
      }
      for (let i = 0; i < infos.length; i++) {
        const id: string = infos[i].formId;
        if (id !== undefined && id !== null && id.length > 0) {
          ids.push(id);
        }
      }
      return ids;
    } catch (e) {
      // 个别设备/版本可能不支持该查询；退回「只用登记表」即可，不是错误
      Logger.warn('discover running forms unsupported, using registry only');
      return [];
    }
  }

  /**
   * 把绑定数据推给给定的卡片 id 列表。
   *
   * @param formIds 目标卡片 id
   * @param data    绑定数据（snapshot + maxRows）
   */
  static async push(formIds: string[], data: CardBinding): Promise<PushOutcome> {
    const out: PushOutcome = new PushOutcome(formIds.length, 0);
    if (formIds.length === 0) {
      return out;
    }
    const fp: FormProviderApi | null = await loadFormProvider();
    if (fp === null) {
      Logger.warn('formProvider unavailable, card push skipped');
      return out;
    }
    let binding: formBindingData.FormBindingData;
    try {
      binding = formBindingData.createFormBindingData(data);
    } catch (e) {
      const err: Error = e as Error;
      Logger.warn('createFormBindingData failed: ' +
        (err !== undefined && err.message !== undefined ? err.message : String(e)));
      return out;
    }
    for (let i = 0; i < formIds.length; i++) {
      const id: string = formIds[i];
      try {
        await fp.updateForm(id, binding);
        out.ok++;
      } catch (e) {
        // 单个卡片失败（例如已被删除但 id 还留着）不应影响其余卡片
        const err: BusinessError = e as BusinessError;
        Logger.warn('updateForm failed for ' + id +
          (err !== undefined && err.code !== undefined ? (' code=' + err.code) : ''));
      }
    }
    Logger.info('card push: ' + out.ok.toString() + '/' + out.total.toString() + ' ok');
    return out;
  }
}