/*
 * CaptchaVote：OCR 候选的清洗与选择（纯逻辑，可离线单测）
 *
 * ===== 为什么要「多变体 + 一致性」而不是「挑分数最高的」=====
 * 本 SDK 的 OCR（Core Vision Kit）只返回文本与包围盒，**没有置信度、
 * 也没有字符级框**。因此无法用「按分数排序取第一」这种常规做法。
 *
 * 替代方案是：同一张验证码图，用几个不同预处理变体各识别一次，
 * 再按**一致性**选择多数派 —— 若两个不同变体独立给出同一个 4 位结果，
 * 该结果正确的概率远高于任一单次识别。这也让「识别率是否真的提高」
 * 变成可测量的事（开发期用 tools/ocr_eval 实测）。
 *
 * 注意：多变体只增加**端上计算**，不额外请求验证码、不额外提交登录，
 * 因此不会加重服务器负担或提高账号锁定风险。
 *
 * ===== 为什么要用包围盒剔词 =====
 * 黑边框被识别成 `|`/`1`/`_` 时，会产出「4 个字符 + 多出来的长条 token」，
 * 若直接 substring(0,4) 就会把真字符挤掉。包围盒能识别这类伪 token：
 * 它又扁又长（长宽比异常），或贴在图像最边缘。按 x 排序拼接前先剔除它们。
 */
import { TextBox } from './CaptchaModels';

/** 一个变体给出的候选 */
export class VariantResult {
  /** 变体名（自检展示用） */
  variant: string = '';
  /** 清洗后的候选（可能为空） */
  candidate: string = '';
  /** 原始文本（排查用） */
  raw: string = '';

  constructor(variant: string, candidate: string, raw: string) {
    this.variant = variant;
    this.candidate = candidate;
    this.raw = raw;
  }
}

/** 投票结论 */
export class VoteOutcome {
  /** 最终采用的验证码；空串表示没有可用的 4 位候选 */
  code: string = '';
  /** 参与投票的变体数 */
  variants: number = 0;
  /** 是否由「多数一致」得出（false 表示只有一个变体给出合理候选） */
  agreed: boolean = false;

  constructor(code: string, variants: number, agreed: boolean) {
    this.code = code;
    this.variants = variants;
    this.agreed = agreed;
  }
}

export class CaptchaVote {
  /** 验证码固定 4 位 */
  static readonly LENGTH: number = 4;
  /** 判定「长条伪 token」的长宽比上限 */
  private static readonly MAX_ASPECT: number = 3.0;
  /** 包围盒高度小于此值视为噪声 token */
  private static readonly MIN_BOX_HEIGHT: number = 6;

  /**
   * 清洗 OCR 文本：只保留字母与数字。
   *
   * 刻意**不做**易混字符纠正（如 1l、0↔O）：服务端按原样比对，
   * 擅自替换只会在本来识别正确时引入错误。由多变体投票去消除这类不确定性 ——
   * 若一个变体读成 `1`、另一个读成 `l`，两者不一致，正好说明该位不可信。
   */
  static clean(raw: string): string {
    if (raw === undefined || raw === null) {
      return '';
    }
    let out: string = '';
    for (let i = 0; i < raw.length; i++) {
      const c: string = raw.charAt(i);
      if (/[A-Za-z0-9]/.test(c)) {
        out = out + c;
      }
    }
    return out;
  }

  /** 是否是一个「看起来合理」的验证码候选：恰好 4 位字母数字 */
  static isPlausible(candidate: string): boolean {
    return candidate.length === CaptchaVote.LENGTH;
  }

  /**
   * 由包围盒重建候选：按 x 排序拼接，剔除长条/过扁的伪 token。
   *
   * @param boxes 识别出的文字块（含包围盒）
   */
  static fromBoxes(boxes: TextBox[]): string {
    const kept: TextBox[] = [];
    for (let i = 0; i < boxes.length; i++) {
      const b: TextBox = boxes[i];
      const text: string = CaptchaVote.clean(b.value);
      if (text.length === 0) {
        continue;
      }
      const w: number = b.width();
      const h: number = b.height();
      // 过扁的（疑似下划线 / 边框横线）直接丢
      if (h < CaptchaVote.MIN_BOX_HEIGHT) {
        continue;
      }
      // 又长又扁的（疑似边框竖线 / 整条边框）也丢
      if (h > 0 && (w / h) > CaptchaVote.MAX_ASPECT) {
        continue;
      }
      kept.push(b);
    }
    kept.sort((a: TextBox, b: TextBox): number => a.left() - b.left());
    let out: string = '';
    for (let i = 0; i < kept.length; i++) {
      out = out + CaptchaVote.clean(kept[i].value);
    }
    return out;
  }

  /**
   * 在多个变体的候选之间投票。
   *
   * 规则（按优先级）：
   *   1. 恰好 4 位、且被**两个以上**变体独立给出一致结果 → 采用（agreed=true）；
   *   2. 否则取第一个「恰好 4 位」的候选（变体按可信度排序，全管线在前）→ agreed=false；
   *   3. 都不满足 → 返回空串，判为识别失败。
   *
   * 第 2 条为何要有：若只有一个变体读出 4 位、其余读出 3 位或 5 位，
   * 那个 4 位结果仍值得一试 —— 登录失败是可恢复的（会重试/转手动），
   * 而直接放弃则必然要用户手输。
   */
  static decide(results: VariantResult[]): VoteOutcome {
    const counts: Map<string, number> = new Map<string, number>();
    let firstPlausible: string = '';
    let variants: number = 0;
    for (let i = 0; i < results.length; i++) {
      const c: string = CaptchaVote.clean(results[i].candidate);
      if (c.length === 0) {
        continue;
      }
      variants++;
      if (!CaptchaVote.isPlausible(c)) {
        continue;
      }
      if (firstPlausible.length === 0) {
        firstPlausible = c;
      }
      const prev: number | undefined = counts.get(c);
      counts.set(c, (prev === undefined ? 0 : prev) + 1);
    }

    let best: string = '';
    let bestCount: number = 0;
    counts.forEach((n: number, c: string) => {
      // 取票数最高；票数相同时保留先出现的（Map 迭代按插入序）
      if (n > bestCount) {
        best = c;
        bestCount = n;
      }
    });

    if (bestCount >= 2) {
      return new VoteOutcome(best, variants, true);
    }
    if (firstPlausible.length > 0) {
      return new VoteOutcome(firstPlausible, variants, false);
    }
    return new VoteOutcome('', variants, false);
  }
}