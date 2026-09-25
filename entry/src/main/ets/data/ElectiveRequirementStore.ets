/*
 * ElectiveRequirementStore：通选课各大类的「总学分要求」本地配置
 *
 * ===== 为什么需要它 =====
 * 学校页面「要求学分（大于等于）」一列实测是**空的**（学校没有录入），
 * 于是 App 只能显示「学校未设置要求」，学生无从知道还差多少学分，
 * 进度条也画不出来（没有分母）。
 * 而每个专业的通选学分要求都明明白白写在培养方案里、对学生是确定的，
 * 所以让用户自己录一次：录完即可长期使用，界面立刻能算「还差 X 学分」。
 *
 * ===== 为什么按账号分片 =====
 * 要求学分挂在**专业**上，同机换账号（不同专业/年级）时要求不同，
 * 串用会让 B 看到 A 的要求 —— 与课表缓存按账号分文件是同一个理由。
 *
 * ===== 为什么不做成本地文件缓存 =====
 * 它是用户手录的少量配置（每大类一个数），不是从服务器取回的数据，
 * 没必要按学期分片、也不需要「恢复为服务器数据」这类操作。
 * 因此放在 preferences 的一张表里。
 *
 * 存储形态：一个 JSON 数组
 *   [{"a":"账号","c":"大类名","v":12},{"a":"账号","c":"其他类","v":8}]
 * 用数组而不是「账号|大类 → 值」的复合键对象：后者依赖分隔符不出现在
 * 大类名里，属于隐式约定；数组显式分字段，不会因为学校改个大类名就串行。
 */
import { PrefStore } from './PrefStore';
import { Logger } from '../common/Logger';
import { KEY_ELECTIVE_REQUIRED } from '../common/Constants';

/** 序列化用的一条要求 */
interface RequirementJson {
  /** 账号 */
  a: string;
  /** 大类名 */
  c: string;
  /** 要求学分 */
  v: number;
}

/** 要求学分的合理上限：通选课总学分不可能到这个量级，用于挡住误输入 */
const MAX_REQUIRED: number = 200;

export class ElectiveRequirementStore {
  /**
   * 读取某账号的全部自定义要求。
   *
   * 返回以**大类名**为键的 Map（调用方只关心「这个大类要求多少」，
   * 不需要再知道账号 —— 账号已在读的时候筛过了）。
   * 任何异常都返回空表：这只是锦上添花的配置，读不到不该影响主流程。
   */
  static async load(account: string): Promise<Map<string, number>> {
    const out: Map<string, number> = new Map<string, number>();
    if (account.length === 0) {
      return out;
    }
    const raw: string = await PrefStore.getText(KEY_ELECTIVE_REQUIRED);
    if (raw.length === 0) {
      return out;
    }
    try {
      const list: RequirementJson[] = JSON.parse(raw) as RequirementJson[];
      if (list === null || list === undefined) {
        return out;
      }
      for (let i = 0; i < list.length; i++) {
        const it: RequirementJson = list[i];
        if (it.a === account && it.c.length > 0 && ElectiveRequirementStore.valid(it.v)) {
          out.set(it.c, it.v);
        }
      }
    } catch (e) {
      Logger.warn('elective requirements parse failed');
      return out;
    }
    return out;
  }

  /**
   * 写入（或清除）某账号某个大类的要求学分。
   *
   * value < 0 表示**清除**该大类的自定义要求，让它回落到服务器的值
   * （学校绝大多数是空，于是界面回到「学校未设置要求」）。
   * 这样「清除」与「设为某个数」共用一条写入路径，不必各写一遍。
   */
  static async save(account: string, category: string, value: number): Promise<boolean> {
    if (account.length === 0 || category.length === 0) {
      return false;
    }
    if (value >= 0 && !ElectiveRequirementStore.valid(value)) {
      return false;
    }
    const all: RequirementJson[] = await ElectiveRequirementStore.loadAll();
    const next: RequirementJson[] = [];
    // 先原样保留其他账号与其他大类的记录
    for (let i = 0; i < all.length; i++) {
      const it: RequirementJson = all[i];
      const sameAccount: boolean = it.a === account;
      const sameCategory: boolean = it.c === category;
      if (sameAccount && sameCategory) {
        continue;   // 由下面按 value 决定是否重新写入
      }
      next.push(it);
    }
    if (value >= 0) {
      const item: RequirementJson = { a: account, c: category, v: value };
      next.push(item);
    }
    try {
      await PrefStore.putText(KEY_ELECTIVE_REQUIRED, JSON.stringify(next));
      Logger.info('elective requirement saved: category=' + category +
        ' value=' + value.toString());
      return true;
    } catch (e) {
      Logger.warn('elective requirement save failed');
      return false;
    }
  }

  /** 清除某账号的全部自定义要求（退出登录时调用，避免跨账号串用） */
  static async clearAccount(account: string): Promise<void> {
    if (account.length === 0) {
      return;
    }
    const all: RequirementJson[] = await ElectiveRequirementStore.loadAll();
    const next: RequirementJson[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].a !== account) {
        next.push(all[i]);
      }
    }
    try {
      await PrefStore.putText(KEY_ELECTIVE_REQUIRED, JSON.stringify(next));
    } catch (e) {
      Logger.warn('elective requirement clear failed');
    }
  }

  /**
   * 解析全部记录（所有账号）。
   *
   * 单独抽出来是因为 save / clear 都要「读全量 → 改 → 写回」，
   * 若各自解析一遍，两处的容错行为容易走偏。
   */
  private static async loadAll(): Promise<RequirementJson[]> {
    const raw: string = await PrefStore.getText(KEY_ELECTIVE_REQUIRED);
    if (raw.length === 0) {
      return [];
    }
    try {
      const list: RequirementJson[] = JSON.parse(raw) as RequirementJson[];
      if (list === null || list === undefined) {
        return [];
      }
      const out: RequirementJson[] = [];
      for (let i = 0; i < list.length; i++) {
        const it: RequirementJson = list[i];
        if (it.a !== undefined && it.a !== null && it.a.length > 0 &&
          it.c !== undefined && it.c !== null && it.c.length > 0 &&
          ElectiveRequirementStore.valid(it.v)) {
          out.push(it);
        }
      }
      return out;
    } catch (e) {
      // 内容损坏时当作空表：宁可让用户重录，也不能让整个页面加载失败
      Logger.warn('elective requirements parse failed, treat as empty');
      return [];
    }
  }

  /** 合法范围：0 以上且不超上限（0 表示「不需要修」也是一种合法要求） */
  private static valid(v: number): boolean {
    return !isNaN(v) && v >= 0 && v <= MAX_REQUIRED;
  }

  /** 把用户输入解析成数值；非法返回 -1 */
  static parseInput(text: string): number {
    const t: string = text.trim();
    if (t.length === 0) {
      return -1;
    }
    // 只接受「数字 + 最多一个小数点」，避免 parseFloat 把 "12abc" 读成 12
    if (!/^\d+(\.\d)?$/.test(t)) {
      return -1;
    }
    const v: number = parseFloat(t);
    return ElectiveRequirementStore.valid(v) ? v : -1;
  }
}
