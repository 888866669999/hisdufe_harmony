/**
 * 文本测量：把「这段文字在这么宽的地方要占几行」变成可计算的量。
 *
 * ===== 为什么需要它 =====
 * 课表卡片原先用「列宽 ÷ 假设字宽」估算行数：
 *
 *     chars = floor((列宽 - 10) / (11 * 1.05));   // 假设所有字号都是 11vp 宽
 *
 * 两个问题叠加，导致「格子里大片空白却仍然截断」：
 *
 *   1. **假设的字宽不对**。实际课名 12vp、教室 9vp，却统一按 11vp 算 ——
 *      教室行因此永远被算作 1 行，于是 `@9-109(章丘)`（10 字符）在窄列上
 *      必然被省略号截掉。用户明确要求「保证上课教室完整显示」。
 *   2. **行数上限写死**（课名 4/3/2 行），与格子实际高度无关。
 *      平板上一格 127vp 高、内容只占 59vp，富余 68vp 全变成卡片底部空白，
 *      课名却仍按 4 行封顶截断。
 *
 * 所以这里做**真实测量**，让「能放几行」由实际可用高度决定。
 *
 * ===== 单位问题（为什么要做系数标定）=====
 * measure 系列 API 的返回值单位在官方文档里**没有写明**（px 还是 vp）。
 * 如果按 px 处理而它实际返回 vp（或反过来），所有换算都会错一个密度倍数 ——
 * 而且错得很隐蔽：行数看着像模像样，只是偏大或偏小。
 *
 * 因此这里不假设单位，而是**用两次测量解出系数**：
 *   同一段文字在 fontS 与 2*fontS 下各测一次高度，得到 h1、h2。
 *   设 h = a + k*fontS（k 即「测量单位/vp」），则
 *       k = (h2 - h1) / fontS
 *   于是任意测量高度都能换算成 vp：hVp = h / k。
 * 这与具体单位无关，也不依赖文档没写清的地方。
 *
 * ===== 缓存 =====
 * 课表每次重排要测 O(7 天 × 5 节 × 每格课数 × 2~4 个字段) 次，
 * 而其中的字符串高度重复（同一门课在多个周次出现）。
 * 表格尺寸变化时清一次缓存（见 [invalidate]）。
 */
import { MeasureUtils, MeasureOptions } from '@kit.ArkUI';
import { Logger } from './Logger';

/** 一次测量结果（vp） */
export class TextMetrics {
  /** 单行高度（vp） */
  lineHeight: number = 0;
  /** 按给定宽度换行后需要的行数 */
  lines: number = 1;

  constructor(lineHeight: number, lines: number) {
    this.lineHeight = lineHeight;
    this.lines = lines;
  }
}

export class TextMeasure {
  private static utils: MeasureUtils | null = null;
  /** 测量单位 / vp 的系数；0 表示尚未标定 */
  private static unitsPerVp: number = 0;
  private static cache: Map<string, TextMetrics> = new Map<string, TextMetrics>();

  /** 标定用的探测字符（用汉字：与课表里的主要内容同族，字宽最接近） */
  private static readonly PROBE: string = '测';

  /**
   * 绑定 UIContext 并完成单位标定。
   *
   * 必须在组件的 `aboutToAppear` 里调用（那里能拿到 `this.getUIContext()`）。
   * 失败不影响使用 —— [ready] 为 false 时调用方应退回旧的估算方式。
   */
  static init(utils: MeasureUtils): void {
    TextMeasure.utils = utils;
    TextMeasure.cache.clear();
    TextMeasure.unitsPerVp = 0;
    try {
      TextMeasure.calibrate();
    } catch (e) {
      Logger.warn('TextMeasure 标定失败，将退回估算: ' + e);
    }
  }

  /** 是否可用于测量 */
  static get ready(): boolean {
    return TextMeasure.utils !== null && TextMeasure.unitsPerVp > 0;
  }

  /** 表格尺寸变化后调用：丢弃缓存（行数结论与宽度相关，宽度变了就全失效） */
  static invalidate(): void {
    TextMeasure.cache.clear();
  }

  /**
   * 用两个字号各测一次，解出「测量单位/vp」。
   * 取差分而不是直接相除，是为了消掉可能存在的常数项。
   */
  private static calibrate(): void {
    const utils: MeasureUtils | null = TextMeasure.utils;
    if (utils === null) {
      return;
    }
    const small: number = TextMeasure.probeHeight(utils, 10);
    const large: number = TextMeasure.probeHeight(utils, 30);
    // h = a + k*fs  ⟹  h2 - h1 = k * (30 - 10)
    const k: number = (large - small) / 20;
    if (k <= 0) {
      Logger.warn('TextMeasure 标定得到的系数非正，退回估算');
      return;
    }
    TextMeasure.unitsPerVp = k;
  }

  /** 测一行文本的高度（不设宽度约束 = 不换行） */
  private static probeHeight(utils: MeasureUtils, fontSizeVp: number): number {
    const opt: MeasureOptions = {
      textContent: TextMeasure.PROBE,
      fontSize: fontSizeVp + 'vp'
    };
    return TextMeasure.asNumber(utils.measureTextSize(opt).height);
  }

  /**
   * SizeOptions 的 width/height 声明是可选 `Length`
   * （`number | string | Resource | undefined`），而这两个 API 实际返回数值。
   * 这里安全地取出 number：万一将来变成字符串（例如带单位）或缺失，
   * 退回 0 让调用方走估算分支 —— 而不是让整个课表因为一个类型不符而崩掉。
   */
  private static asNumber(v: Length | undefined): number {
    return typeof v === 'number' ? v : 0;
  }

  /**
   * 测「这段文字在这个宽度下要占几行」，同时给出单行高度（vp）。
   *
   * @param text 文本
   * @param fontSizeVp 字号（vp）
   * @param usableWidthVp 可用宽度（vp）。传 0 或负数表示不换行。
   */
  static measure(text: string, fontSizeVp: number, usableWidthVp: number): TextMetrics {
    if (text.length === 0) {
      return new TextMetrics(TextMeasure.fallbackLineHeight(fontSizeVp), 0);
    }
    const utils: MeasureUtils | null = TextMeasure.utils;
    if (utils === null || TextMeasure.unitsPerVp <= 0) {
      return TextMeasure.estimate(text, fontSizeVp, usableWidthVp);
    }

    const key: string = fontSizeVp + '|' + Math.round(usableWidthVp) + '|' + text;
    const hit: TextMetrics | undefined = TextMeasure.cache.get(key);
    if (hit !== undefined) {
      return hit;
    }

    let result: TextMetrics;
    try {
      // 单行高度：不设约束
      const oneLineUnits: number = TextMeasure.asNumber(
        utils.measureTextSize({
          textContent: text,
          fontSize: fontSizeVp + 'vp'
        } as MeasureOptions).height);
      const lineHeightVp: number = oneLineUnits / TextMeasure.unitsPerVp;
      if (lineHeightVp <= 0) {
        result = TextMeasure.estimate(text, fontSizeVp, usableWidthVp);
      } else if (usableWidthVp <= 0) {
        result = new TextMetrics(lineHeightVp, 1);
      } else {
        // 换行后的总高度：约束宽度用带单位的字符串，让 API 自己换单位
        const wrappedUnits: number = TextMeasure.asNumber(
          utils.measureTextSize({
            textContent: text,
            fontSize: fontSizeVp + 'vp',
            constraintWidth: usableWidthVp + 'vp'
          } as MeasureOptions).height);
        let n: number = wrappedUnits > 0 ? Math.round(wrappedUnits / oneLineUnits) : 1;
        if (n < 1) {
          n = 1;
        }
        result = new TextMetrics(lineHeightVp, n);
      }
    } catch (e) {
      // 测量异常（例如 UIContext 已失效）：退回估算，不让它影响渲染
      result = TextMeasure.estimate(text, fontSizeVp, usableWidthVp);
    }
    TextMeasure.cache.set(key, result);
    return result;
  }

  /** 单行高度（vp），不需要知道行数时用它 */
  static lineHeight(fontSizeVp: number): number {
    return TextMeasure.measure('测', fontSizeVp, 0).lineHeight;
  }

  /** 测量不可用时的兜底行高：按字号的常见行高比例 */
  private static fallbackLineHeight(fontSizeVp: number): number {
    return fontSizeVp * 1.32;
  }

  /**
   * 估算兜底（标定失败时用）。
   *
   * 与旧实现的关键差别：**汉字按 1.0 em 估宽**（CJK 全角字宽≈字号），
   * 而旧实现用 1.05 倍 —— 那个系数让可用宽度变小、行数偏多，
   * 又叠加了「所有字号都按 11vp」的错误，最终把教室行算成 1 行。
   */
  private static estimate(text: string, fontSizeVp: number, usableWidthVp: number): TextMetrics {
    const lineH: number = TextMeasure.fallbackLineHeight(fontSizeVp);
    if (usableWidthVp <= 0) {
      return new TextMetrics(lineH, 1);
    }
    const charsPerLine: number = Math.max(1, Math.floor(usableWidthVp / fontSizeVp));
    return new TextMetrics(lineH, Math.max(1, Math.ceil(text.length / charsPerLine)));
  }
}
