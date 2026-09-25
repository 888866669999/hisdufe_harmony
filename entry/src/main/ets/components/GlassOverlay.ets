/*
 * GlassOverlay：页面内浮层外壳（默认液态玻璃，可切系统默认材质）
 *
 * 两种材质由 [PanelMaterial] 选择：玻璃 = AppleUI 透镜 + 挖空遮罩 +
 * 磨砂面板；系统 = 整屏遮罩 + 不透明面板。选型的依据是**内容的密度**
 * （密集文字在透镜上会糊，见 PanelMaterial 的说明）。
 * 下面描述的是玻璃路径（默认）的层级。
 *
 * ===== 为什么单独做一个组件 =====
 * 应用里有 5 个「页面内浮层」（课程编辑、校历与作息表、节次作息编辑、
 * 提前提醒、重新验证）。它们原先都是「半透明遮罩 + 不透明面板」，
 * 观感与 dock 的液态玻璃割裂。逐个改会有 5 份几乎一样的布局代码，
 * 以后调参要改 5 遍 —— 因此收口到这一个组件。
 *
 * ===== 层级顺序（关键，决定了玻璃能不能渲染）=====
 * ```
 * Stack（页面根）
 *   ├─ 页面内容（Scroll/Column…）      ← 兄弟 1：被折射的对象
 *   └─ GlassOverlay                   ← 兄弟 2：浮层容器
 *        └─ Stack
 *             ├─ AppleUI（透镜）        ← 第一个子节点：本层无前序兄弟，
 *             │                            于是上溯一层取到「页面内容」
 *             ├─ 遮罩四条（挖空面板）
 *             └─ 面板内容（输入框/按钮）
 * ```
 * 两个约束不能违反：
 *   1. **透镜必须是浮层容器的第一个子节点**。若遮罩排在它前面，透镜截到的
 *      就是那块纯色遮罩，玻璃退化成一块死板深色矩形（折射/色散全无）。
 *   2. **浮层容器必须是页面内容的后序兄弟**（即页面根 Stack 的第二个子节点）。
 *      这样上溯一层能找到内容；若把透镜塞进页面内容内部，它取到的会是
 *      更靠前的兄弟（可能是背景色块），同样失去折射。
 *
 * ===== 遮罩为什么要「挖空」=====
 * 见 [GlassKit.scrimRects] 的说明：整块遮罩会挡在透镜与内容之间，
 * 使玻璃失效。拆成四条 = 视觉上整屏压暗、中间留洞，而透镜取到的是
 * **未压暗**的真实内容 —— 比 Flutter 端（玻璃叠在全屏遮罩之上）更通透。
 *
 * ===== 为什么面板要用 Blur =====
 * AppleUI 的 Blur=0 时中心完全看穿，dock 那样只放图标的导航没问题；
 * 但浮层里有大量文字与输入框，中心若透明会与底下内容叠字、不可读。
 * 因此浮层用 Blur≈14 做成「磨砂玻璃」：中心可读，边缘仍有折射与色散。
 */
import { AppleUI } from 'com.hm.appleui.hw';
import { GlassKit, PanelMaterial, ScrimRect } from '../theme/GlassKit';
import { Theme } from '../theme/Theme';

@Component
export struct GlassOverlay {
  /** 面板内容。由调用方通过尾随闭包传入。 */
  @BuilderParam content: () => void;

  /** 面板宽度占可用宽度的比例（会再受 maxPanelWidth 与边缘余量约束） */
  panelWidthRatio: number = 0.92;
  /** 面板高度占可用高度的比例 */
  panelHeightRatio: number = 0.72;

  /**
   * 面板的**精确高度**（vp）。>0 时优先于 [panelHeightRatio]。
   *
   * ===== 为什么需要它（比例不够用）=====
   * 比例是按「可用高度」算的，而浮层内容的高度往往是**固定 vp**（若干行按钮、
   * 固定高度的输入框）。两者不匹配时：内容比面板高就被裁掉（实测「提前提醒」
   * 的选择列表只露出 3 项、后两项被切），比面板矮则面板里空一大截。
   * 内容高度已知的浮层直接给 vp，跨设备都准。
   */
  panelHeightVp: number = 0;

  /** 面板的**精确宽度**（vp）。>0 时优先于 [panelWidthRatio]。 */
  panelWidthVp: number = 0;
  /** 面板最大宽度（vp）：平板上避免拉成一整条 */
  maxPanelWidth: number = 560;
  /** 面板最大高度（vp） */
  maxPanelHeight: number = 900;
  /**
   * 透镜模糊度：浮层用磨砂（中心可读），见类注释。
   *
   * 与下方的磨砂背板配合使用。单独调大它**没有**用：AppleUI 的模糊是
   * **16 点 Vogel 盘**采样（不是高斯），半径再大也只是把下层文字复制成
   * 16 份「鬼影」——实测 14vp 与 48vp 都不能让密集文字变得可读，
   * 反而更花。真正承担可读性的是 [frostedBacking]。
   * 属性名刻意不叫 `blur` —— 那个名字与 ArkUI 基类 `CustomComponent` 的
   * 通用属性同名，会导致「Property 'blur' is not assignable to the same
   * property in base type」的编译错误。
   */
  lensBlur: number = 20;

  /** 关闭回调（点遮罩区域触发） */
  onDismiss: () => void = () => {};

  /**
   * 面板材质（见 [PanelMaterial]）。
   *
   * SYSTEM 时**不渲染透镜**，改为不透明面板 + 整屏遮罩。校历那样密集的
   * 月历网格与说明文字在磨砂玻璃上是糊的（AppleUI 的模糊是 16 点 Vogel
   * 盘采样，密集小字会被复制成 16 份鬼影，实测 14vp/48vp 两档都不清楚），
   * 系统面板下才清楚 —— 这是用户对校历的明确要求。
   */
  material: PanelMaterial = PanelMaterial.GLASS;

  /**
   * 是否为本层预留底部 dock 的让位。
   *
   * 默认 true：浮层铺满整个页面区域，底部确实与 dock 重合。
   * 但**嵌套**在另一个已避开 dock 的面板里的浮层（校历里再弹学期滚轮）
   * 必须置 false —— 它所在的区域本来就在 dock 之上，再扣一次会让滚轮
   * 无谓地上移与压扁。
   */
  avoidDock: boolean = true;

  /** 浮层可用区域的实测尺寸（vp） */
  @State areaW: number = 0;
  @State areaH: number = 0;

  /**
   * 边缘余量（vp）。
   *
   * AppleUI 的画布会向四周外扩 30vp：透镜离父容器边缘不足这个距离时，
   * 截帧区域越界、玻璃**静默不渲染**（真机日志 `Snapshot reigon out of range`）。
   * 因此面板无论如何都要留出 ≥30vp，这里取 34（与 dock 的 DOCK_MARGIN 同值）。
   */
  private static readonly EDGE_PAD: number = 34;

  /**
   * 面板与底部 dock 之间额外留出的空隙（vp）。
   * 贴在一起会让面板看着像 dock 的一部分，留一条缝才像两块独立的浮层。
   */
  private static readonly DOCK_GAP: number = 12;

  /** 极矮窗口下面板的最小高度（vp）：可用区被挤光时不再继续压扁面板 */
  private static readonly MIN_PANEL_H: number = 240;

  /** 面板宽度（vp）：精确值优先，其次比例，最后受上限与边缘余量约束 */
  private panelW(): number {
    const avail: number = Math.max(1, this.areaW - GlassOverlay.EDGE_PAD * 2);
    const want: number = this.panelWidthVp > 0
      ? this.panelWidthVp
      : Math.min(this.areaW * this.panelWidthRatio, this.maxPanelWidth);
    return Math.max(1, Math.min(want, avail));
  }

  /** 可用区的上边界（vp）：给透镜画布留出外扩余量 */
  private safeTop(): number {
    return GlassOverlay.EDGE_PAD;
  }

  /**
   * 可用区的下边界（vp）：扣掉底部 dock 与一条空隙。
   *
   * 只有窄屏才有 dock（宽屏是左侧导航），因此扣减量取 `AS_BOTTOM_INSET` ——
   * 它与各页面滚动内容用的让位是**同一个值**（由 Index 按断点写入：
   * 窄屏 = dock 高 + 下边距，宽屏 = 0），不必再判断一次断点。
   */
  private safeBottom(): number {
    const inset: number = this.avoidDock ? Theme.bottomInset() : 0;
    return this.areaH - Math.max(inset + GlassOverlay.DOCK_GAP, GlassOverlay.EDGE_PAD);
  }

  /**
   * 面板高度（vp）：精确值优先，其次比例，最后夹进可用区。
   *
   * ===== 为什么必须夹进可用区（真机 bug）=====
   * 早先只把高度夹进「窗口高度 − 2×余量」，而位置在「扣掉 dock 之后」的
   * 区域里居中 —— 两者用的边界不一致。比例 0.88 的浮层（课程编辑）在手机上
   * 比扣完 dock 的可用区还高，于是走了「放不下就退回居中」的分支，
   * 面板下沿落进 dock 的高度范围内：底部的「保存 / 取消」正好被玻璃压住
   * （用户反馈「底部的按键不会给 dock 让位」）。现在高度与位置共用同一对
   * 边界，面板永远放得进可用区（只有极矮的自由多窗例外，见 room）。
   */
  private panelH(): number {
    const avail: number = Math.max(1, this.safeBottom() - this.safeTop());
    // 自由多窗拖到极矮时可用区会被挤成一条：这时允许面板占满窗口高度
    // （底部暂时压在 dock 下），也好过塌成一条看不见的缝
    const room: number = Math.max(avail, Math.min(GlassOverlay.MIN_PANEL_H, this.areaH));
    const want: number = this.panelHeightVp > 0
      ? this.panelHeightVp
      : Math.min(this.areaH * this.panelHeightRatio, this.maxPanelHeight);
    return Math.max(1, Math.min(want, room));
  }

  /**
   * 面板中心的目标 y（vp）。
   *
   * ===== 为什么不能简单居中（竖屏真机问题）=====
   * 底部 dock 是**外壳层**画的浮层，层级在页面之上；而本浮层活在页面里，
   * 于是面板底部会被 dock 压住 —— 校历浮层的「关闭」按钮正好在最下沿，
   * 竖屏时与 dock 重合，点不到（用户实测反馈）。
   *
   * 做法：在 safeTop…safeBottom 之间居中（下边界已扣掉 dock）。
   * 面板若比这段可用区还高（极矮窗口），则**贴着上边界**放、超出部分沉到
   * dock 下面 —— 宁可底部被压一点，也不能把面板顶出屏幕上沿（那会让标题
   * 与整行按钮一起消失）。
   */
  private safeCenterY(): number {
    const top: number = this.safeTop();
    const bottom: number = Math.max(this.safeBottom(), top + this.panelH());
    return (top + bottom) / 2;
  }

  /** 遮罩四条（挖空面板）：中心与面板一致，否则洞与面板错位 */
  private scrims(): ScrimRect[] {
    return GlassKit.scrimRects(
      this.areaW, this.areaH, this.panelW(), this.panelH(), this.safeCenterY());
  }

  /** 圆角半径（vp）：面板圆角与 Theme.RADIUS 一致，避免同页方圆混用 */
  private panelRadius(): number {
    return Theme.RADIUS;
  }

  /**
   * 系统材质面板的外壳：不透明表面 + 圆角 + 投影，内容叠在上面。
   *
   * 与玻璃路径的区别只有两点：不渲染 AppleUI 透镜、底色换成不透明的
   * `app.color.surface`（系统面板的观感就是「一块实底 + 一点投影」）。
   * 投影让它在压暗的遮罩上仍有浮起感，不至于像贴在屏幕上的纸片。
   */
  @Builder
  systemPanel() {
    Stack() {
      this.content()
    }
    .width(this.panelW())
    .height(this.panelH())
    .borderRadius(this.panelRadius())
    .backgroundColor($r('app.color.surface'))
    // 0.5vp 细边：纯色面板在白底页面上容易与背景糊在一起（暗色主题下更明显）
    .border({ width: 0.5, color: $r('app.color.divider') })
    .shadow({ radius: 24, color: '#33000000', offsetX: 0, offsetY: 6 })
    .clip(true)
    .offset({ y: this.safeCenterY() - this.areaH / 2 })
  }

  build() {
    Stack() {
      if (this.areaW > 0 && this.areaH > 0) {
        if (this.material === PanelMaterial.SYSTEM) {
          // 系统默认材质：一整块遮罩 + 居中不透明面板（无透镜可截，也就不需要挖空）
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(GlassKit.SCRIM_COLOR)
            .onClick(() => {
              this.onDismiss();
            })
          this.systemPanel()
        } else {
          // 1) 透镜：必须是第一个子节点（见类注释的约束一）。
          //    offset 让它与面板一起上移，避开底部 dock（见 safeCenterY）。
          AppleUI({
            Width: this.panelW(),
            Height: this.panelH(),
            // Circle 是「半径占短边的百分比」：短边 300vp 时 14% → 半径 21vp，
            // 与 Theme.RADIUS(14) 观感接近而略圆，符合浮层面板的体量
            Circle: GlassKit.PANEL_CIRCLE,
            Blur: this.lensBlur,
            NeoStrength: GlassKit.PANEL_NEO,
            // 不做弹性交互：浮层面板被拉伸会很难看，且拖拽与内部滚动冲突
            ProUI: false
          })
            .offset({ y: this.safeCenterY() - this.areaH / 2 })

          // 2) 遮罩四条：只压暗面板之外，面板内由透镜负责
          ForEach(this.scrims(), (r: ScrimRect) => {
            Column()
              .width(r.w)
              .height(r.h)
              .backgroundColor(GlassKit.SCRIM_COLOR)
              .position({ x: r.x, y: r.y })
              .onClick(() => {
                this.onDismiss();
              })
          }, (r: ScrimRect) => 'scrim-' + r.x.toString() + '-' + r.y.toString()
            + '-' + r.w.toString() + '-' + r.h.toString())

          // 3) 面板内容：叠在透镜之上、遮罩之内。
          //    与透镜用**同一个** offset，两者始终重合。
          Column() {
            this.content()
          }
          .width(this.panelW())
          .height(this.panelH())
          .borderRadius(this.panelRadius())
          .clip(true)
          .offset({ y: this.safeCenterY() - this.areaH / 2 })
          // ===== 为什么面板还要叠一层磨砂（而不是只靠透镜）=====
          // AppleUI 是**透镜**而不是**面板**：它的设计目标是 dock 那样
          // 「中心看穿、边缘折射」的悬浮玻璃，模糊用的是 16 点 Vogel 盘采样。
          // 浮层里全是密集文字，那 16 份采样会把下层文字复制成「鬼影」——
          // 实测（14vp / 48vp 两档）都无法让文字变清楚，反而更花。
          //
          // 因此这里做**分层**：AppleUI 负责边缘的折射与色散（观感），
          // 这层磨砂负责把下层内容真正糊开并给一点底色（可读性）。
          // 两者叠加后，边缘仍能看到玻璃的彩边，中间则是可读的磨砂面 ——
          // 既保住了「液态玻璃」的语言，又不牺牲可读性。
          .backgroundEffect(GlassKit.panelEffect())
        }
      }
    }

    .width('100%')
    .height('100%')
    // 量出可用区域：面板尺寸、遮罩四条都要按它算
    .onAreaChange((_o: Area, now: Area) => {
      const w: number = Number(now.width);
      const h: number = Number(now.height);
      if (w > 0 && h > 0 && (Math.abs(w - this.areaW) > 0.5 || Math.abs(h - this.areaH) > 0.5)) {
        this.areaW = w;
        this.areaH = h;
      }
    })
  }
}
