/*
 * AppIcon：统一的矢量图标组件
 *
 * 用法：`AppIcon({ res: 'calendar_month', iconSize: 22, color: ... })`
 *
 * ===== 为什么用 SVG 资源 + fillColor（走过的弯路记在这里）=====
 * 最初把 Material 图标的 path 数据内联成字符串、用 `Path().commands(...)` 画。
 * 这条路在**尺寸与对齐**上连踩三坑（都经真机 / 模拟器截图确认）：
 *
 *   坑一 `Path().width(24).height(24).scale(iconSize/24)`
 *       `Path` 的 width/height 是组件尺寸，不缩放 path 坐标 → 图形被裁剪成碎片。
 *
 *   坑二 `Shape(){Path()}.viewPort({0,0,24,24}).width(22).height(22)`
 *       以为 viewPort 等价 SVG 的 viewBox，实测**它不缩放 Path 坐标** ——
 *       图标永远约 24px 大，却画在 22vp(≈66px) 框的左上角。
 *       多列并排的底部 dock 上，就表现为「图标相对文字系统性偏移」。
 *
 *   坑三 自己按尺寸重写 path 的坐标数值
 *       看似可行，但 path 里相邻数值会写成 `-1.99.9` 这种形式，
 *       数值扫描稍有疏忽就会把两个数粘成一个（实测确实粘了），
 *       属于容易写出**静默错误**的做法，不值得。
 *
 * 现在的做法（ArkUI 官方推荐、也是唯一稳妥的）：把图标作为 **svg 资源**
 * 放进 `resources/base/media/`，用 `Image($r('app.media.x'))` 渲染并
 * `.fillColor()` 着色：
 *   - 缩放交给 Image（固定 width/height + Contain），没有坐标系换算；
 *   - `fillColor` 仍能着色，所以照样跟随主题与选中态；
 *   - svg 是矢量，任意尺寸都清晰。
 *
 * 图标文件由 `tools/fetch_icons.sh` 从 @material-design-icons/svg 的
 * outlined 目录取来 —— 与 Flutter 版 `Icons.*_outlined` 同源，两端一致。
 */
@Component
export struct AppIcon {
  /// media 目录下的 svg 资源名（不含扩展名），如 'calendar_month'
  @Prop res: string = '';
  /// 期望显示尺寸（vp）
  @Prop iconSize: number = 24;
  /// 填充色（svg 会被整体着色）
  @Prop color: ResourceColor = Color.Black;
  /// 不透明度（次要图标可降低）
  @Prop alpha: number = 1;

  build() {
    Image($r(`app.media.${this.res}`))
      .width(this.iconSize)
      .height(this.iconSize)
      // Contain：等比铺满给定尺寸。
      // 不加这句会按 svg 自己声明的 24px 原始尺寸渲染，小图标会缩在左上角
      // （与前两个坑表现相同）。
      .objectFit(ImageFit.Contain)
      // 整体着色
      .fillColor(this.color)
      .opacity(this.alpha)
  }
}
