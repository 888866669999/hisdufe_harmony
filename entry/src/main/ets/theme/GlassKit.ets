/*
 * GlassKit：全应用统一的「液态玻璃」工具集
 *
 * ===== 为什么要有它 =====
 * 之前玻璃效果散落在各页（dock 用 AppleUI、弹窗/侧栏用 backgroundEffect），
 * 参数各写各的，观感不一致；换一处要全仓库找。现在收口到这里。
 *
 * ===== 两类玻璃、何时用哪一种（实测结论，务必遵守）=====
 *
 * 1. **AppleUI 透镜**（真·液态玻璃，边缘折射 + 色散 + 中心看穿）——
 *    只适合「与页面内容同处一个 Stack、且能取到内容作为前序兄弟」的浮层：
 *      · 底部 dock（前序兄弟 = 整页滚动内容）✓
 *      · 页面内浮层（课程编辑 / 校历 / 作息编辑 / 提醒提前量 / 重新验证）✓
 *        —— 条件是浮层容器**本身**必须是页面内容层的后序兄弟，
 *           这样透镜上溯一层就能取到内容（见 [GlassKit] 类注释末尾的层级图）
 *    不适合「贴边、背后无内容」的容器（侧栏、顶栏、系统弹窗框架自建的弹窗）——
 *    AppleUI 靠「向前找最近一个重叠兄弟层」定位截帧目标，背后没内容就
 *    无东西可截，真机表现为连续 `snapshot fail 401`、玻璃整格不画
 *    （Index.sideBar 里记录了这次实测）。
 *
 * 2. **backgroundEffect 磨砂**（模糊 + 提饱和）——用于侧栏、顶栏、
 *    以及系统弹窗框架（CustomDialogController）自建的弹窗 ——
 *    后者没有可用的前序兄弟，玻璃一挂上去就是黑的。
 */
import { AppleUI } from 'com.hm.appleui.hw';
import { Theme } from './Theme';

/**
 * 浮层面板的材质。
 *
 * 两种都要有，因为内容性质不同（用户明确要求校历用系统默认）：
 *
 * 1. GLASS（默认）——AppleUI 透镜 + 磨砂背板。适合内容**稀疏**的浮层
 *    （几个按钮、一个滚轮、几个输入框）：中心可读、边缘有折射与色散。
 *
 * 2. SYSTEM——不透明面板（surface + 圆角 + 投影）+ 整屏压暗遮罩。
 *    适合内容**密集**的浮层（校历的月历网格、几十行的列表）：
 *    AppleUI 的模糊是 16 点 Vogel 盘采样，密集小字会被复制成 16 份鬼影
 *    ——实测（14vp / 48vp 两档）都无法让这种内容变清楚，反而更花。
 *    含大量文字的浮层用系统面板，是与系统弹窗一致的、也是唯一清楚的选择。
 */
export enum PanelMaterial {
  /** 液态玻璃：AppleUI 折射 + 磨砂背板 */
  GLASS = 0,
  /** 系统默认：不透明表面 + 圆角 + 投影，不渲染透镜 */
  SYSTEM = 1
}

export class GlassKit {
  // ---------- AppleUI 透镜（背后有内容的悬浮玻璃） ----------

  /**
   * 底部 dock / 悬浮按钮条的透镜参数。
   *
   * NeoStrength 0.28：略高于默认 0.20，让厚度感与彩色镶边更明确
   * （dock 最初就是这套值，观感已验证）；Blur 0：中心看穿。
   */
  static readonly DOCK_NEO: number = 0.28;
  static readonly DOCK_BLUR: number = 0;
  static readonly DOCK_CIRCLE: string = '50%';

  /** 浮层面板：圆角比 dock 更方（矩形面板而非胶囊） */
  static readonly PANEL_NEO: number = 0.26;
  static readonly PANEL_BLUR: number = 0;
  static readonly PANEL_CIRCLE: string = '14%';

  /** 小控件（药丸按钮、悬浮小圆钮）的透镜参数 */
  static readonly PILL_NEO: number = 0.24;
  static readonly PILL_BLUR: number = 0;
  static readonly PILL_CIRCLE: string = '100%';

  // ---------- backgroundEffect 磨砂（贴边容器） ----------

  /**
   * 弹窗面板 / 卡片容器。
   *
   * radius 24：与 flutter 端 GlassQuality.standard 的观感对齐；
   * color 带 ~30% 白：磨砂面板需要一点底色才能与背景分层（纯模糊会「散」）。
   */
  static panelEffect(): BackgroundEffectOptions {
    return {
      radius: 24,
      saturation: 1.35,
      brightness: 1.02,
      color: '#4DFFFFFF',
      adaptiveColor: AdaptiveColor.AVERAGE,
      blurOptions: { grayscale: [15, 45] }
    };
  }

  /** 输入框 / 选择器底衬：比面板薄一档（字段小，模糊过强会显得脏） */
  static fieldEffect(): BackgroundEffectOptions {
    return {
      radius: 16,
      saturation: 1.2,
      brightness: 1.02,
      color: '#40FFFFFF',
      adaptiveColor: AdaptiveColor.AVERAGE,
      blurOptions: { grayscale: [12, 40] }
    };
  }

  /** 顶栏 / 工具条：介于两者之间 */
  static barEffect(): BackgroundEffectOptions {
    return {
      radius: 20,
      saturation: 1.3,
      brightness: 1.02,
      color: '#47FFFFFF',
      adaptiveColor: AdaptiveColor.AVERAGE,
      blurOptions: { grayscale: [14, 42] }
    };
  }

  /**
   * 控件的高光细边（0.5vp 白，约 25%）。
   *
   * ===== 为什么要在不透明面板上补这一笔 =====
   * 玻璃控件放在**不透明**面板（系统材质浮层）上时，模糊背后是一块纯色 ——
   * 观感几乎等于没做玻璃。这条极细的白边是玻璃边缘「接光」的那一道，
   * 暗色主题下也能显出来（与已被删除的 PDF 内嵌视窗用的是同一手法）。
   * 与 fieldEffect 一起用，不要单独用。
   */
  static readonly FIELD_EDGE: string = '#40FFFFFF';

  // ---------- 浮层遮罩 ----------

  /**
   * 浮层压暗遮罩的四个矩形（中间挖空给玻璃面板）。
   *
   * ===== 为什么不能铺一整块遮罩 =====
   * AppleUI 取的是**紧邻自身的前序兄弟**作为截帧目标。若在透镜与页面内容之间
   * 铺一整块半透明遮罩，透镜截到的就是那块**纯色**，玻璃会退化成一整块死板的
   * 深色矩形 —— 「液态玻璃」的折射与色散全部消失（这是本文件开头规则二的同源问题）。
   *
   * 反过来把遮罩画在透镜**之上**也不行：它会连玻璃面板一起压暗。
   *
   * 因此这里把遮罩拆成「面板四周的四条」——视觉上等于「整屏压暗、中间挖一个
   * 面板大小的洞」，而透镜到内容之间没有任何遮挡，玻璃取到的是真实的页面内容。
   * 附带的好处：玻璃里折射的是**未压暗**的内容，比 Flutter 端（玻璃叠在
   * 全屏遮罩之上、折射的是已压暗的画面）更通透。
   *
   * @param screenW 屏幕宽（vp）
   * @param screenH 屏幕高（vp）
   * @param panelW  面板宽（vp）
   * @param panelH  面板高（vp）
   * @param centerY 面板中心的 y（vp）。不传或 ≤0 时按屏幕垂直居中。
   *                浮层需要躲开底部 dock 时由调用方传入上移后的中心值
   *                （见 GlassOverlay 的 safeCenterY）。
   * @returns 四条遮罩矩形，顺序为 上/下/左/右；宽高为 0 的条可跳过渲染
   */
  static scrimRects(
    screenW: number,
    screenH: number,
    panelW: number,
    panelH: number,
    centerY?: number
  ): ScrimRect[] {
    const left: number = Math.max(0, (screenW - panelW) / 2);
    // 遮罩与面板必须用**同一个**中心值，否则挖出的洞会和面板错位，
    // 表现为「面板边缘压着一块暗角」。
    const cy: number = (centerY === undefined || centerY <= 0)
      ? screenH / 2 : centerY;
    const top: number = Math.max(0, cy - panelH / 2);
    const right: number = Math.max(0, screenW - left - panelW);
    const bottom: number = Math.max(0, screenH - top - panelH);
    const out: ScrimRect[] = [];
    if (top > 0) {
      out.push(new ScrimRect(0, 0, screenW, top));
    }
    if (bottom > 0) {
      out.push(new ScrimRect(0, top + panelH, screenW, bottom));
    }
    if (left > 0) {
      // 左右两条只覆盖面板所在的那一段高度，避免与上下条重叠画出双层暗度
      out.push(new ScrimRect(0, top, left, panelH));
    }
    if (right > 0) {
      out.push(new ScrimRect(left + panelW, top, right, panelH));
    }
    return out;
  }

  /** 浮层遮罩的颜色：与既有实现一致（#66000000 = 40% 黑） */
  static readonly SCRIM_COLOR: string = '#66000000';

  /** 浮层面板的统一内边距 */
  static readonly PANEL_PAD: number = Theme.GAP_L;
}

/** 遮罩矩形（vp） */
export class ScrimRect {
  x: number = 0;
  y: number = 0;
  w: number = 0;
  h: number = 0;

  constructor(x: number, y: number, w: number, h: number) {
    this.x = x;
    this.y = y;
    this.w = w;
    this.h = h;
  }
}
