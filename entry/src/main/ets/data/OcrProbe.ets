/*
 * OcrProbe：验证码 OCR（图像预处理 + 多变体一致性投票）
 *
 * ===== 为什么要单独成文件、并且只通过动态 import 加载 =====
 * 本应用此前踩过一个坑：静态导入缺少的 HMS 导出会导致**模块加载阶段**抛
 * SyntaxError，try/catch 拦不住，还会把引用它的页面一起带崩
 * （详见 README 里 PDF 闪退那一节）。
 * OCR 能力（SystemCapability.AI.OCR.TextRecognition）在部分设备/模拟器上并不存在，
 * 因此这里绝不静态导入，只提供「被动态 import 后才执行」的实现，
 * 由调用方（ReAuthService）在确认 canIUse 之后再用 await import() 加载本文件。
 *
 * ===== 识别率是怎么提上去的 =====
 * 改造前：原图（110×70 / 120×80）→ 直接 recognizeText → substring(0,4)。
 * 三个具体缺陷：图太小（字符高约 25–30px）；黑色圆角边框会被当成 `|`/`1`
 * 挤掉真字符；灰色噪点与 1px 划痕产生假笔画。
 *
 * 现在：
 *   1. **预处理**（`CaptchaPrep`）：墨迹分数 255-min(RGB)（保住彩色字符）→
 *      Otsu 自适应二值化 → 两步裁边（先去留白、再去边框线）→ 去孤立噪点；
 *   2. **放大** ×4（最近邻），把字符高度提到 ~100px 以上；
 *   3. **多变体投票**（`CaptchaVote`）：同一张图跑 3 个变体各识别一次，
 *      收敛出「多数一致」的候选。多变体只烧端上 CPU，**不额外请求验证码、
 *      不额外提交登录**，因此不增加服务器负担或账号锁定风险。
 *
 * 之所以用「一致性投票」而不是「取分数最高」：本 SDK 的 OCR 结果
 * **没有置信度**，无从排序，只能靠不同变体互相印证。
 */
import { textRecognition } from '@kit.CoreVisionKit';
import { image } from '@kit.ImageKit';
import { Logger } from '../common/Logger';
import { CaptchaPrep, PrepResult, Bitmap, Segment } from '../model/CaptchaPrep';
import { CaptchaVote, VariantResult, VoteOutcome } from '../model/CaptchaVote';
import { TextBox } from '../model/CaptchaModels';
import { PixelBuffer } from '../model/PixelBuffer';

/** OCR 所需系统能力 */
export const OCR_SYSCAP: string = 'SystemCapability.AI.OCR.TextRecognition';

/** 放大倍数：把字符高度从 ~25px 提到 ~100px，是识别率提升的主要来源之一 */
const UPSCALE: number = 4;

/**
 * 变体清单（按「可信度」从高到低排列，投票在票数相同时取靠前的）。
 *
 * ===== 为什么是这样一组变体（实测调出来的，不是想当然）=====
 * 最初的假设是「二值化 + 放大最好」，但在真机上对 12 张带真值的语料实测后发现
 * **二值化反而有害**：通用文字识别引擎是按自然图像（平滑、灰阶）调的，
 * 硬二值化 + 最近邻放大产生锯齿边缘，会让它把 `zu79` 读成 `Zu779`（凭空多一个 7）、
 * 把 `vzpz` 读成 `vzdz`。而「仅放大」的原始图反而读对了 `zu79`。
 *
 * 因此这里把「仅放大」放在第一位（票数相同时优先采用它），
 * 二值化只作为补充变体用来在个别样本上提供第二意见。
 */
export class OcrVariant {
  name: string = '';
  /** 0 = 原图仅放大；1 = 二值化；2 = 灰度 */
  kind: number = 0;
  scale: number = 4;

  constructor(name: string, kind: number, scale: number) {
    this.name = name;
    this.kind = kind;
    this.scale = scale;
  }
}

const KIND_RAW: number = 0;
const KIND_BINARY: number = 1;
const KIND_GRAY: number = 2;
/** 逐字符切分后分别识别，再拼回 4 位（见 recognizeSegmented 的说明） */
const KIND_SEGMENT: number = 3;

/**
 * 默认变体顺序：三档放大倍数，全部走「原图 + 最近邻放大」。
 *
 * ===== 这组默认是实测调出来的，与最初设想不同 =====
 * 最初设想是「二值化 + 放大」，但真机对 12 张带真值语料的扫描结果否定了它：
 *
 *     变体        某次扫描的完全正确率
 *     raw+x2      43%   ← 最好
 *     raw+x4      29%
 *     raw+x6      29%
 *     gray+x4     29%
 *     raw+x1      14%
 *     bin+x4       0%   ← 最差，二值化反而伤识别
 *     seg+x4       0%   ← 逐字符切分完全无效（引擎需要上下文）
 *
 * 解释：识别引擎是按自然图像（平滑灰阶）训练的；硬二值化 + 最近邻放大
 * 产生的锯齿边缘会误导它（`zu79`→`Zu779` 凭空多一个 7）。
 * 而逐字符切分之所以彻底失败，是因为把单字喂进去后引擎失去了「凑成词」的
 * 上下文，直接放弃输出 —— 这也解释了它读整条时为何常只读出一部分。
 *
 * 三档不同倍数一起投票是有意的：实测发现同一张图在不同倍数下结果并不稳定，
 * 多档并存能让「多数一致」真正起到纠错作用（不一致的位本就不可信）。
 */
const VARIANTS: OcrVariant[] = [
  new OcrVariant('raw+x2', KIND_RAW, 2),
  new OcrVariant('raw+x4', KIND_RAW, 4),
  new OcrVariant('raw+x6', KIND_RAW, 6)
];

/**
 * 诊断用变体清单：一次跑完所有候选，用于**选型**而不是线上识别。
 * 只在 OCR 评测里用，让「哪个变体更好」由数据回答。
 */
const SWEEP_VARIANTS: OcrVariant[] = [
  new OcrVariant('raw+x1', KIND_RAW, 1),
  new OcrVariant('raw+x2', KIND_RAW, 2),
  new OcrVariant('raw+x4', KIND_RAW, 4),
  new OcrVariant('raw+x6', KIND_RAW, 6),
  new OcrVariant('gray+x4', KIND_GRAY, 4),
  new OcrVariant('bin+x4', KIND_BINARY, 4),
  new OcrVariant('seg+x4', KIND_SEGMENT, 4)
];

/**
 * 变体数量上限。
 * 3 个变体足以形成「两两印证」；再多只是线性增加耗时，收益很小。
 * 启动静默续期等对耗时敏感的场景可以只跑 1 个（见 ReAuthService）。
 */
const DEFAULT_VARIANTS: number = 3;

/** 识别结果 */
export class OcrOutcome {
  ok: boolean = false;
  /** 识别出的文本（已去空白） */
  text: string = '';
  /** 失败原因，便于界面提示与排查 */
  reason: string = '';
  /** 各变体的候选（自检展示用，便于看清是哪一步出了问题） */
  variants: VariantResult[] = [];
  /** 是否由「多数一致」得出 */
  agreed: boolean = false;
  /** 采用的二值化阈值（自检展示用） */
  threshold: number = 0;

  constructor(ok: boolean, text: string, reason: string) {
    this.ok = ok;
    this.text = text;
    this.reason = reason;
  }
}

export class OcrProbe {
  /** 本设备是否声明支持 OCR（不触碰 OCR 模块本身） */
  static supported(): boolean {
    try {
      return canIUse(OCR_SYSCAP);
    } catch (e) {
      return false;
    }
  }

  /**
   * 识别验证码图片。
   *
   * @param jpeg 验证码原图（JPEG 字节）
   * @param maxVariants 最多跑几个变体（默认 3；1 表示只跑最好的那个，最省时）
   */
  static async recognizeCaptcha(jpeg: ArrayBuffer,
    maxVariants: number = DEFAULT_VARIANTS): Promise<OcrOutcome> {
    return await OcrProbe.runVariants(jpeg, VARIANTS, maxVariants);
  }

  /**
   * 诊断入口：一次跑完全部候选变体，用于**选型**（哪个预处理/倍数最好）。
   * 线上识别不走这里，避免无谓耗时。
   */
  static async sweep(jpeg: ArrayBuffer): Promise<OcrOutcome> {
    return await OcrProbe.runVariants(jpeg, SWEEP_VARIANTS, SWEEP_VARIANTS.length);
  }

  private static async runVariants(jpeg: ArrayBuffer, variants: OcrVariant[],
    limit: number): Promise<OcrOutcome> {
    let src: image.ImageSource | null = null;
    const temps: image.PixelMap[] = [];
    try {
      src = image.createImageSource(jpeg);
      const info: image.ImageInfo = await src.getImageInfo();
      const rawBuf: PixelBuffer | null = await OcrProbe.readPixels(src, info);
      if (rawBuf === null || !rawBuf.isValid()) {
        return new OcrOutcome(false, '', '验证码图片解码失败');
      }

      // 二值化预处理只算一次，供二值化变体复用
      const prep: PrepResult = CaptchaPrep.prepare(rawBuf, false);
      const n: number = limit > variants.length ? variants.length : limit;

      const results: VariantResult[] = [];
      await textRecognition.init();
      try {
        for (let i = 0; i < n; i++) {
          const v: OcrVariant = variants[i];
          let pm: image.PixelMap | null = null;
          if (v.kind === KIND_RAW) {
            pm = await OcrProbe.rawScaled(rawBuf, v.scale);
          } else if (v.kind === KIND_GRAY) {
            pm = OcrProbe.grayScaled(rawBuf, v.scale);
          } else if (v.kind === KIND_SEGMENT) {
            // 逐字符识别：不走「单张 PixelMap」这条路，单独处理
            const seg: VariantResult = await OcrProbe.recognizeSegmented(prep, v.name);
            results.push(seg);
            continue;
          } else {
            pm = OcrProbe.binaryScaled(prep, v.scale);
          }
          if (pm === null) {
            continue;
          }
          temps.push(pm);
          results.push(await OcrProbe.recognizeOne(pm, v.name));
        }
      } finally {
        try {
          await textRecognition.release();
        } catch (e) {
          // 释放失败无所谓
        }
      }

      const vote: VoteOutcome = CaptchaVote.decide(results);
      const out: OcrOutcome = new OcrOutcome(
        vote.code.length === CaptchaVote.LENGTH, vote.code,
        vote.code.length === CaptchaVote.LENGTH ? '' : '未能识别出 4 位验证码');
      out.variants = results;
      out.agreed = vote.agreed;
      out.threshold = prep.threshold;
      Logger.info('ocr captcha: variants=' + results.length.toString() +
        ' agreed=' + vote.agreed + ' codeLen=' + vote.code.length.toString() +
        ' thr=' + prep.threshold.toString());
      // 逐变体候选：调参时唯一有用的信息 —— 能看出是预处理有害还是放大有害
      for (let i = 0; i < results.length; i++) {
        Logger.info('ocr variant[' + results[i].variant + '] cand=[' +
          results[i].candidate + '] rawLen=' + results[i].raw.length.toString());
      }
      return out;
    } catch (e) {
      const err: Error = e as Error;
      const msg: string = (err !== undefined && err.message !== undefined) ? err.message : String(e);
      Logger.warn('ocr failed: ' + msg);
      return new OcrOutcome(false, '', msg);
    } finally {
      // ImageSource 与 PixelMap 都持有 native 资源，必须显式 release；
      // 只释放 PixelMap 会泄漏 —— OCR 在每次会话失效重试时都会调用，累积后可致解码失败。
      for (let i = 0; i < temps.length; i++) {
        try {
          temps[i].release();
        } catch (e) {
          // 忽略
        }
      }
      if (src !== null) {
        try {
          src.release();
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  /**
   * 解码并读出像素，压成紧凑的 RGBA 缓冲。
   *
   * 为什么要处理 stride：PixelMap 的行字节数可能大于 width×4（对齐填充），
   * 直接按 width×4 解读会把每行错位、整幅图斜切。
   * 实测本设备 `getBytesNumberPerRow()` 就等于 width×4，但代码不能依赖这一点。
   */
  private static async readPixels(src: image.ImageSource,
    info: image.ImageInfo): Promise<PixelBuffer | null> {
    const w: number = info.size.width;
    const h: number = info.size.height;
    if (w <= 0 || h <= 0) {
      return null;
    }
    const pm: image.PixelMap = await src.createPixelMap({
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: true
    });
    try {
      const stride: number = pm.getBytesNumberPerRow();
      const total: ArrayBuffer = new ArrayBuffer(stride * h);
      await pm.readPixelsToBuffer(total);
      const view: Uint8Array = new Uint8Array(total);
      const tight: Uint8Array = new Uint8Array(w * h * 4);
      if (stride === w * 4) {
        tight.set(view.subarray(0, w * h * 4));
      } else {
        // 按行去 stride
        for (let y = 0; y < h; y++) {
          const from: number = y * stride;
          const to: number = y * w * 4;
          tight.set(view.subarray(from, from + w * 4), to);
        }
      }
      return new PixelBuffer(w, h, tight);
    } finally {
      try {
        pm.release();
      } catch (e) {
        // 忽略
      }
    }
  }

  /**
   * 逐字符切分识别。
   *
   * ===== 为什么需要 =====
   * 实测（开发期用 tools/ocr_eval 扫描过）发现通用 OCR 会把 4 字符的整条归并成更短的串：
   * `qj3n` → `3n`、`9dvp` → `p`、`hrpx` → `xp`。
   * 它把整条当成「一个词」做语言层面的合并，而验证码不是词。
   *
   * 切成单字分别识别能消除这种归并：每次只喂一个字符，
   * 引擎没有「凑成词」的余地。代价是识别次数变为 4 倍
   * （但只在扫描/自检时启用，线上默认变体不含它）。
   */
  private static async recognizeSegmented(prep: PrepResult,
    variant: string): Promise<VariantResult> {
    const bm = prep.bitmap;
    // 字符内部空隙上限：按图宽估算（验证码 4 位，单字约 1/4 宽）
    const maxGap: number = Math.max(1, Math.floor(bm.width / 24));
    const segs: Segment[] = CaptchaPrep.segments(bm, maxGap);
    let out: string = '';
    let rawAll: string = '';
    for (let i = 0; i < segs.length; i++) {
      const one: Bitmap = CaptchaPrep.cropColumns(bm, segs[i]);
      const pm: image.PixelMap | null = OcrProbe.binaryScaledFrom(one, 4);
      if (pm === null) {
        continue;
      }
      try {
        const r: VariantResult = await OcrProbe.recognizeOne(pm, variant + '#' + i.toString());
        // 单个字符：取清洗后的第一个字符即可
        const c: string = CaptchaVote.clean(r.candidate);
        if (c.length > 0) {
          out = out + c.charAt(0);
        }
        rawAll = rawAll + r.raw;
      } finally {
        try {
          pm.release();
        } catch (e) {
          // 忽略
        }
      }
    }
    return new VariantResult(variant, out, rawAll);
  }

  /**
   * 原图变体：直接把 RGBA 缓冲按最近邻放大。
   *
   * 为什么不用解码器的 `desiredSize` 缩放：实测它带平滑插值，会把细小笔画糊掉；
   * 而识别引擎对「保持边缘锐利」的放大更友好，因此统一走自己搬像素这条路。
   */
  private static rawScaled(buf: PixelBuffer, scale: number): image.PixelMap | null {
    if (scale <= 1) {
      return OcrProbe.makePixelMap(buf.data, buf.width, buf.height);
    }
    const w: number = buf.width * scale;
    const h: number = buf.height * scale;
    const out: Uint8Array = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) {
      const sy: number = (y / scale) | 0;
      for (let x = 0; x < w; x++) {
        const sx: number = (x / scale) | 0;
        const s: number = (sy * buf.width + sx) * 4;
        const d: number = (y * w + x) * 4;
        out[d] = buf.data[s];
        out[d + 1] = buf.data[s + 1];
        out[d + 2] = buf.data[s + 2];
        out[d + 3] = 255;
      }
    }
    return OcrProbe.makePixelMap(out, w, h);
  }

  /**
   * 灰度变体：按整数亮度公式转灰后再放大（保持平滑、无锯齿）。
   *
   * 为什么保留灰度而不是只留二值化：识别引擎是按自然图像调的，
   * 灰阶保留了抗锯齿边缘，实测比硬二值化更稳。
   */
  private static grayScaled(buf: PixelBuffer, scale: number): image.PixelMap | null {
    const w: number = buf.width * scale;
    const h: number = buf.height * scale;
    const out: Uint8Array = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) {
      const sy: number = (y / scale) | 0;
      for (let x = 0; x < w; x++) {
        const sx: number = (x / scale) | 0;
        const s: number = (sy * buf.width + sx) * 4;
        // 整数亮度（ITU-R BT.601）：避免浮点、且在低端设备上也够快
        const g: number = (buf.data[s] * 77 + buf.data[s + 1] * 151 +
          buf.data[s + 2] * 28) >> 8;
        const d: number = (y * w + x) * 4;
        out[d] = g;
        out[d + 1] = g;
        out[d + 2] = g;
        out[d + 3] = 255;
      }
    }
    return OcrProbe.makePixelMap(out, w, h);
  }

  /** 二值化变体（预处理结果，黑白两色） */
  private static binaryScaled(prep: PrepResult, scale: number): image.PixelMap | null {
    return OcrProbe.binaryScaledFrom(prep.bitmap, scale);
  }

  /** 二值化变体：直接给 Bitmap（供逐字符切分复用） */
  private static binaryScaledFrom(bm: Bitmap, scale: number): image.PixelMap | null {
    const src: Uint8Array = OcrProbe.bitmapToRgba(bm);
    if (scale <= 1) {
      return OcrProbe.makePixelMap(src, bm.width, bm.height);
    }
    const w: number = bm.width * scale;
    const h: number = bm.height * scale;
    const out: Uint8Array = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) {
      const sy: number = (y / scale) | 0;
      for (let x = 0; x < w; x++) {
        const sx: number = (x / scale) | 0;
        const s: number = (sy * bm.width + sx) * 4;
        const d: number = (y * w + x) * 4;
        out[d] = src[s];
        out[d + 1] = src[s];
        out[d + 2] = src[s];
        out[d + 3] = 255;
      }
    }
    return OcrProbe.makePixelMap(out, w, h);
  }

  /** 二值图 → 黑字白底 RGBA */
  private static bitmapToRgba(bm: Bitmap): Uint8Array {
    const n: number = bm.width * bm.height;
    const out: Uint8Array = new Uint8Array(n * 4);
    for (let i = 0; i < n; i++) {
      const v: number = bm.data[i] === 1 ? 0 : 255;
      const o: number = i * 4;
      out[o] = v;
      out[o + 1] = v;
      out[o + 2] = v;
      out[o + 3] = 255;
    }
    return out;
  }

  /** 用裸 RGBA 字节建 PixelMap */
  private static makePixelMap(rgba: Uint8Array, w: number, h: number): image.PixelMap | null {
    try {
      return image.createPixelMapSync(rgba.buffer as ArrayBuffer, {
        size: { width: w, height: h },
        srcPixelFormat: image.PixelMapFormat.RGBA_8888,
        pixelFormat: image.PixelMapFormat.RGBA_8888,
        alphaType: image.AlphaType.OPAQUE,
        editable: false
      });
    } catch (e) {
      Logger.warn('makePixelMap failed');
      return null;
    }
  }

  /**
   * 对单个 PixelMap 跑一次识别，产出候选。
   *
   * 候选有两个来源，取「更像 4 位验证码」的那个：
   *   - `res.value`：OCR 拼接好的整段文本；
   *   - 按包围盒重建：可剔除边框被识别成的长条伪 token（见 CaptchaVote.fromBoxes）。
   */
  private static async recognizeOne(pixelMap: image.PixelMap,
    variant: string): Promise<VariantResult> {
    const info: textRecognition.VisionInfo = { pixelMap: pixelMap };
    // 验证码是正向的，关掉方向检测可少一次猜测
    const res: textRecognition.TextRecognitionResult =
      await textRecognition.recognizeText(info, { isDirectionDetectionSupported: false });
    const raw: string = (res !== null && res.value !== undefined) ? res.value : '';
    const byValue: string = CaptchaVote.clean(raw);
    const boxes: TextBox[] = OcrProbe.collectBoxes(res);
    const byBoxes: string = CaptchaVote.fromBoxes(boxes);

    // 优先取恰好 4 位的那个；都合法时优先按包围盒的结果（更不容易混入边框伪 token）
    let candidate: string = byValue;
    if (CaptchaVote.isPlausible(byBoxes) && !CaptchaVote.isPlausible(byValue)) {
      candidate = byBoxes;
    } else if (CaptchaVote.isPlausible(byBoxes) && CaptchaVote.isPlausible(byValue) &&
      byBoxes !== byValue) {
      candidate = byBoxes;
    }
    return new VariantResult(variant, candidate, raw);
  }

  /** 把 OCR 结果的 word 级 cornerPoints 归约成包围盒 */
  private static collectBoxes(res: textRecognition.TextRecognitionResult): TextBox[] {
    const out: TextBox[] = [];
    if (res === null || res.blocks === undefined || res.blocks === null) {
      return out;
    }
    for (let i = 0; i < res.blocks.length; i++) {
      const block = res.blocks[i];
      if (block.lines === undefined || block.lines === null) {
        continue;
      }
      for (let j = 0; j < block.lines.length; j++) {
        const line = block.lines[j];
        if (line.words === undefined || line.words === null) {
          continue;
        }
        for (let k = 0; k < line.words.length; k++) {
          const word = line.words[k];
          const pts = word.cornerPoints;
          if (pts === undefined || pts === null || pts.length === 0) {
            continue;
          }
          let x0: number = pts[0].x;
          let y0: number = pts[0].y;
          let x1: number = pts[0].x;
          let y1: number = pts[0].y;
          for (let p = 1; p < pts.length; p++) {
            if (pts[p].x < x0) {
              x0 = pts[p].x;
            }
            if (pts[p].y < y0) {
              y0 = pts[p].y;
            }
            if (pts[p].x > x1) {
              x1 = pts[p].x;
            }
            if (pts[p].y > y1) {
              y1 = pts[p].y;
            }
          }
          out.push(new TextBox(word.value, x0, y0, x1, y1));
        }
      }
    }
    return out;
  }

  /** 清洗 OCR 文本：只保留字母与数字（转调 CaptchaVote.clean，保持单一实现） */
  static clean(raw: string): string {
    return CaptchaVote.clean(raw);
  }
}