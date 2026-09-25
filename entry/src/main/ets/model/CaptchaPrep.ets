/*
 * CaptchaPrep：验证码图像预处理（纯像素运算，可离线单测）
 *
 * ===== 为什么要做预处理 =====
 * 教务系统的验证码原图只有 110×70 / 120×80，字符高约 25–30px ——
 * 对通用文字识别来说偏小。直接把它丢给 OCR（改造前的做法）有三个具体干扰：
 *
 *   1. **黑色圆角边框**：它是整张图上最强的深色结构，OCR 容易把它当成
 *      `|`/`I`/下划线一类的「字符」，从而把真正的第 4 位字符挤掉；
 *   2. **灰色 JPEG 噪点**：背景并非纯白（实测纯白占比仅 ~83%），
 *      固定白阈值会把噪点也算成笔画；
 *   3. **1px 划痕曲线**：细、低墨量，二值化后变成一堆孤立小点。
 *
 * 更关键的是：**每个字符颜色不同**（深绿 / 黑 / 棕 / 青紫…），
 * 且多为低饱和度的深色。因此这里不用灰度（luma）——
 * 灰度会把「蓝紫色」这类字符压到与背景接近，直接丢字。
 * 改用**墨迹分数**：
 *
 *     ink = 255 - min(R, G, B)
 *
 * 只要某个通道很暗，就认为这里有笔画。对纯灰噪声 min≈max，得分也低，
 * 因此它天然比灰度更能保住彩色字符、同时不怎么放大灰噪点。
 *
 * ===== 阈值为什么用 Otsu 而不是固定值 =====
 * 背景不是纯白、字符颜色又各不相同，任何固定阈值都会在某些样本上失效。
 * Otsu 按当前图的直方图自行找「类间方差最大」的分割点，实测阈值落在
 * 92–106 之间（开发期在 12 个真实验证码样本上测过），自适应明显更稳。
 *
 * ===== 为什么不做 1px 膨胀 =====
 * 原型验证的结论：膨胀会把相邻字符粘连（`r`+`3` 粘成一体、`9` 的字腔被填死），
 * 反而降低可读性。因此本模块**默认不做膨胀**，只提供开关留给极端细笔画的场景，
 * 并明确记录它是「实测后判定为有害」的选项。
 */
import { PixelBuffer } from './PixelBuffer';

/** 二值图：0 = 背景，1 = 笔画；行优先 */
export class Bitmap {
  width: number = 0;
  height: number = 0;
  /** 长度 = width * height */
  data: Uint8Array;

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
    this.data = new Uint8Array(width * height);
  }

  at(x: number, y: number): number {
    if (x < 0 || y < 0 || x >= this.width || y >= this.height) {
      return 0;
    }
    return this.data[y * this.width + x];
  }

  set(x: number, y: number, v: number): void {
    if (x < 0 || y < 0 || x >= this.width || y >= this.height) {
      return;
    }
    this.data[y * this.width + x] = v;
  }
}

/** 裁边结果：新位图 + 四边各裁掉多少像素 */
export class CropBox {
  bitmap: Bitmap;
  left: number = 0;
  top: number = 0;
  right: number = 0;
  bottom: number = 0;

  constructor(bitmap: Bitmap, left: number, top: number, right: number, bottom: number) {
    this.bitmap = bitmap;
    this.left = left;
    this.top = top;
    this.right = right;
    this.bottom = bottom;
  }
}

/** 预处理结果：二值图 + 统计信息（便于自检展示与调参） */
export class PrepResult {
  bitmap: Bitmap;
  /** 采用的 Otsu 阈值 */
  threshold: number = 0;
  /** 裁掉的边框厚度（左/上/右/下） */
  cropLeft: number = 0;
  cropTop: number = 0;
  cropRight: number = 0;
  cropBottom: number = 0;

  constructor(bitmap: Bitmap) {
    this.bitmap = bitmap;
  }

  /** 输出供 OCR 使用的「黑字白底」RGBA 字节 */
  toRgba(): Uint8Array {
    const n: number = this.bitmap.width * this.bitmap.height;
    const out: Uint8Array = new Uint8Array(n * 4);
    for (let i = 0; i < n; i++) {
      const v: number = this.bitmap.data[i] === 1 ? 0 : 255;
      const o: number = i * 4;
      out[o] = v;
      out[o + 1] = v;
      out[o + 2] = v;
      out[o + 3] = 255;
    }
    return out;
  }
}

/** 一个横向字符段，区间为 [x0, x1) */
export class Segment {
  x0: number = 0;
  x1: number = 0;

  constructor(x0: number, x1: number) {
    this.x0 = x0;
    this.x1 = x1;
  }

  width(): number {
    return this.x1 - this.x0;
  }
}

export class CaptchaPrep {
  /**
   * 判定「某行/某列是边框」的墨迹密度下限。
   *
   * 取值依据（对语料逐列实测）：圆角边框的竖直边密度峰值 0.71–0.83，
   * 而最「竖」的字母（d / p / q / l / 1）整列密度只有 0.36–0.51。
   * 0.6 落在两者之间且留有余量，既能切掉边框又不会咬到字符。
   */
  private static readonly BORDER_DENSITY: number = 0.6;
  /**
   * 判定「某行/某列是空白留白」的墨迹密度上限。
   *
   * 真实截图里验证码控件四周是对话框背景（无墨迹），实测密度为 0，
   * 因此 0.02 足以把它们与字符区分开；真正的空白行/列几乎都是 0，
   * 而任何跨过字符的行都远高于此值。
   */
  private static readonly EMPTY_DENSITY: number = 0.02;
  /**
   * 裁边时每边最多允许裁掉的比例。
   *
   * 为什么必须有这个上限：若整张图墨迹偏多（极端压缩噪声、或图像本身就是深底），
   * 逐边内缩会一路吃到字符。它同时保证了「裁边后一定还剩大部分画面」，
   * 是这一类「按统计量自动裁剪」逻辑的必要保险。
   */
  private static readonly MAX_CROP_RATIO: number = 0.2;
  /** 去噪：孤立点所需的「相邻墨水像素」下限（8 邻域，不含自身） */
  private static readonly MIN_NEIGHBOURS: number = 2;

  /**
   * 墨迹分数：255 - min(R,G,B)。
   *
   * 与灰度的区别（实测最关键的一点）：
   * 蓝色字符 (40,80,160) 的灰度约 79，判定含混；而 min=40 → ink=215，非常明确。
   */
  static ink(r: number, g: number, b: number): number {
    const mn: number = Math.min(r, Math.min(g, b));
    return 255 - mn;
  }

  /**
   * Otsu 阈值分割。
   *
   * 按灰度直方图最大化类间方差，得到「笔画 / 背景」的最佳分界。
   * 入参是 256 桶直方图，返回阈值（>= 阈值判为笔画）。
   */
  static otsu(hist: Int32Array, total: number): number {
    if (total <= 0) {
      return 127;
    }
    let sumAll: number = 0;
    for (let i = 0; i < 256; i++) {
      sumAll += i * hist[i];
    }
    let sumB: number = 0;
    let wB: number = 0;
    let best: number = -1;
    let threshold: number = 127;
    for (let t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB === 0) {
        continue;
      }
      const wF: number = total - wB;
      if (wF === 0) {
        break;
      }
      sumB += t * hist[t];
      const mB: number = sumB / wB;
      const mF: number = (sumAll - sumB) / wF;
      const between: number = wB * wF * (mB - mF) * (mB - mF);
      if (between > best) {
        best = between;
        threshold = t;
      }
    }
    return threshold;
  }

  /**
   * 主入口：把 RGBA 像素缓冲处理成 OCR 友好的黑白二值图。
   *
   * 步骤：墨迹分数 → Otsu 二值化 → 按投影裁掉黑边框 → 去孤立噪点。
   *
   * @param buf  RGBA_8888 像素缓冲
   * @param dilate 是否做 1px 膨胀。默认 false —— 实测会让字符粘连，见文件头说明。
   */
  static prepare(buf: PixelBuffer, dilate: boolean): PrepResult {
    const w: number = buf.width;
    const h: number = buf.height;
    const ink: Uint8Array = new Uint8Array(w * h);
    const hist: Int32Array = new Int32Array(256);
    for (let i = 0; i < w * h; i++) {
      const o: number = i * 4;
      const v: number = CaptchaPrep.ink(buf.data[o], buf.data[o + 1], buf.data[o + 2]);
      ink[i] = v;
      hist[v]++;
    }
    const threshold: number = CaptchaPrep.otsu(hist, w * h);

    const bin: Bitmap = new Bitmap(w, h);
    for (let i = 0; i < w * h; i++) {
      bin.data[i] = ink[i] > threshold ? 1 : 0;
    }

    const crop: CropBox = CaptchaPrep.cropBorder(bin);
    const cleaned: Bitmap = CaptchaPrep.denoise(crop.bitmap);
    const finalMap: Bitmap = dilate ? CaptchaPrep.dilate1(cleaned) : cleaned;

    const res: PrepResult = new PrepResult(finalMap);
    res.threshold = threshold;
    res.cropLeft = crop.left;
    res.cropTop = crop.top;
    res.cropRight = crop.right;
    res.cropBottom = crop.bottom;
    return res;
  }

  /**
   * 裁边：先去掉四周空白，再去掉边框线。
   *
   * ===== 为什么必须分两步（实测踩坑）=====
   * 真实截图里验证码控件外面还有一层对话框背景，因此**黑框并不贴着图像边缘** ——
   * 实测 `cap1`/`cap2` 的竖直边框线落在 x=11..13，前面 11 列是背景。
   * 如果只做「从边缘按密度找边框」，第 0 列密度是 0，循环立刻停下，
   * 边框根本不会被裁掉（结果就是那条黑竖线一直留着干扰 OCR）。
   *
   * 所以顺序是：
   *   1. 先裁掉四周「几乎全空」的边（密度 < EMPTY_DENSITY）—— 去掉背景留白；
   *   2. 再裁掉四周「几乎全实」的边（密度 >= BORDER_DENSITY）—— 去掉边框线。
   *
   * 第 1 步顺带还有一个好处：让字符尽量填满整幅图，等于给 OCR 做了隐式放大。
   *
   * 每步都限制最大裁剪量（MAX_CROP_RATIO），避免异常图被裁到只剩一点。
   */
  static cropBorder(bin: Bitmap): CropBox {
    const w: number = bin.width;
    const h: number = bin.height;
    const rowDensity: number[] = [];
    for (let y = 0; y < h; y++) {
      let n: number = 0;
      for (let x = 0; x < w; x++) {
        n += bin.at(x, y);
      }
      rowDensity.push(n / w);
    }
    const colDensity: number[] = [];
    for (let x = 0; x < w; x++) {
      let n: number = 0;
      for (let y = 0; y < h; y++) {
        n += bin.at(x, y);
      }
      colDensity.push(n / h);
    }

    const maxRows: number = Math.floor(h * CaptchaPrep.MAX_CROP_RATIO);
    const maxCols: number = Math.floor(w * CaptchaPrep.MAX_CROP_RATIO);

    let top: number = 0;
    let bottom: number = h - 1;
    let left: number = 0;
    let right: number = w - 1;

    // 第 1 步：裁空白（每边限量）
    let moved: number = 0;
    while (top < h - 1 && moved < maxRows && rowDensity[top] < CaptchaPrep.EMPTY_DENSITY) {
      top++;
      moved++;
    }
    moved = 0;
    while (bottom > top && moved < maxRows && rowDensity[bottom] < CaptchaPrep.EMPTY_DENSITY) {
      bottom--;
      moved++;
    }
    moved = 0;
    while (left < w - 1 && moved < maxCols && colDensity[left] < CaptchaPrep.EMPTY_DENSITY) {
      left++;
      moved++;
    }
    moved = 0;
    while (right > left && moved < maxCols && colDensity[right] < CaptchaPrep.EMPTY_DENSITY) {
      right--;
      moved++;
    }

    // 第 2 步：裁边框线（每边限量）
    moved = 0;
    while (top < bottom && moved < maxRows && rowDensity[top] >= CaptchaPrep.BORDER_DENSITY) {
      top++;
      moved++;
    }
    moved = 0;
    while (bottom > top && moved < maxRows && rowDensity[bottom] >= CaptchaPrep.BORDER_DENSITY) {
      bottom--;
      moved++;
    }
    moved = 0;
    while (left < right && moved < maxCols && colDensity[left] >= CaptchaPrep.BORDER_DENSITY) {
      left++;
      moved++;
    }
    moved = 0;
    while (right > left && moved < maxCols && colDensity[right] >= CaptchaPrep.BORDER_DENSITY) {
      right--;
      moved++;
    }

    const nw: number = right - left + 1;
    const nh: number = bottom - top + 1;
    if (nw <= 0 || nh <= 0) {
      // 裁没了说明判定异常，退回原图更安全
      return new CropBox(bin, 0, 0, 0, 0);
    }
    const out: Bitmap = new Bitmap(nw, nh);
    for (let y = 0; y < nh; y++) {
      for (let x = 0; x < nw; x++) {
        out.set(x, y, bin.at(left + x, top + y));
      }
    }
    return new CropBox(out, left, top, w - 1 - right, h - 1 - bottom);
  }

  /**
   * 去孤立噪点：8 邻域内墨水邻居少于 MIN_NEIGHBOURS 的墨点判为噪声。
   *
   * 这一条主要干掉 JPEG 噪点和 1px 划痕留下的碎点；
   * 真正的字符笔画在任意像素上都至少连着两个邻居，不会被误删。
   */
  static denoise(bin: Bitmap): Bitmap {
    const w: number = bin.width;
    const h: number = bin.height;
    const out: Bitmap = new Bitmap(w, h);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        if (bin.at(x, y) === 0) {
          continue;
        }
        let n: number = 0;
        for (let dy = -1; dy <= 1; dy++) {
          for (let dx = -1; dx <= 1; dx++) {
            if (dx === 0 && dy === 0) {
              continue;
            }
            n += bin.at(x + dx, y + dy);
            if (n >= CaptchaPrep.MIN_NEIGHBOURS) {
              break;
            }
          }
          if (n >= CaptchaPrep.MIN_NEIGHBOURS) {
            break;
          }
        }
        out.set(x, y, n >= CaptchaPrep.MIN_NEIGHBOURS ? 1 : 0);
      }
    }
    return out;
  }

  /**
   * 按竖直投影把二值图切成字符段（纯计算，可单测）。
   *
   * ===== 为什么要切分 =====
   * 实测发现通用 OCR 会把 4 个字符的整条读成更少的字符
   * （`qj3n` → `3n`、`9dvp` → `p`、`hrpx` → `xp`）——
   * 它把整条当成「一个词」去做语言层面的归并，而验证码恰恰不是词。
   * 切成单字分别识别，可以消除这种归并倾向。
   *
   * ===== 算法 =====
   * 逐列统计墨迹像素数，得到「有墨 / 无墨」的列序列；
   * 连续的「有墨」列即一个字符段；宽度过小（<= maxGap 的一半）的段判为
   * 噪声/划痕残渣并丢弃。返回各段的 [x0, x1) 区间。
   *
   * @param maxGap 允许被当作「字符内部空隙」的最大列数；
   *               超过它才算字符之间的分隔。之所以需要：`i`/`j` 这类
   *               字母自身有细窄空隙，一刀切会把一个字劈成两半。
   */
  static segments(bin: Bitmap, maxGap: number): Segment[] {
    const w: number = bin.width;
    const h: number = bin.height;
    if (w <= 0 || h <= 0) {
      return [];
    }
    const colInk: number[] = [];
    for (let x = 0; x < w; x++) {
      let n: number = 0;
      for (let y = 0; y < h; y++) {
        n += bin.at(x, y);
      }
      colInk.push(n);
    }
    // 列是否「有墨」：至少有 1 个墨点，且不是偶然的单点
    const minColInk: number = 1;
    const raw: Segment[] = [];
    let start: number = -1;
    let gap: number = 0;
    for (let x = 0; x < w; x++) {
      const has: boolean = colInk[x] > minColInk;
      if (has) {
        if (start < 0) {
          start = x;
        }
        gap = 0;
      } else {
        if (start >= 0) {
          gap++;
          if (gap > maxGap) {
            // 结束当前段（回退这段空隙）
            const end: number = x - gap + 1;
            if (end > start) {
              raw.push(new Segment(start, end));
            }
            start = -1;
            gap = 0;
          }
        }
      }
    }
    if (start >= 0) {
      raw.push(new Segment(start, w));
    }

    // 丢过窄的段（噪声/划痕残渣）
    const minWidth: number = Math.max(2, Math.floor(maxGap / 2) + 1);
    const out: Segment[] = [];
    for (let i = 0; i < raw.length; i++) {
      if (raw[i].width() >= minWidth) {
        out.push(raw[i]);
      }
    }
    return out;
  }

  /** 裁出二值图的某个横向区间 */
  static cropColumns(bin: Bitmap, seg: Segment): Bitmap {
    const x0: number = seg.x0 < 0 ? 0 : seg.x0;
    const x1: number = seg.x1 > bin.width ? bin.width : seg.x1;
    const nw: number = x1 - x0;
    if (nw <= 0) {
      return bin;
    }
    const out: Bitmap = new Bitmap(nw, bin.height);
    for (let y = 0; y < bin.height; y++) {
      for (let x = 0; x < nw; x++) {
        out.set(x, y, bin.at(x0 + x, y));
      }
    }
    return out;
  }

  /**
   * 1px 膨胀（加粗笔画）。
   *
   * **默认不启用**：原型实测会把相邻字符粘连（`r`+`3` 连成一体、`9` 字腔被填死），
   * 属于「看起来增强、实际有害」。保留实现只为在细笔画样本上做对照实验。
   */
  static dilate1(bin: Bitmap): Bitmap {
    const w: number = bin.width;
    const h: number = bin.height;
    const out: Bitmap = new Bitmap(w, h);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        if (bin.at(x, y) === 0) {
          continue;
        }
        for (let dy = -1; dy <= 1; dy++) {
          for (let dx = -1; dx <= 1; dx++) {
            out.set(x + dx, y + dy, 1);
          }
        }
      }
    }
    return out;
  }
}
