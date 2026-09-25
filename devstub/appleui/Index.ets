/*
 * AppleUI 的**模拟器占位实现**（仅用于 x86_64 模拟器的布局/dpi 验证）
 *
 * ===== 为什么需要它 =====
 * 正式的 `com.hm.appleui.hw` 只随包提供 **arm64-v8a** 的原生库
 * （libliquidglass.so）与 libc++_shared.so，且 HAR 内不含 cpp 源码
 * （只有 CMakeLists 的引用与 .d.ts 声明），因此无法为 x86_64 重新编译。
 * 结果：任何依赖它的 HAP 都装不上 x86_64 模拟器 ——
 * hdc 报 `install parse native so failed` / ABI 不匹配。
 *
 * 而「手机端一屏装下整周课表」「不同 dpi 下的布局响应」这两件事**只与
 * 布局有关**，与玻璃的折射着色器无关。因此做这个占位版本：API 与正式包
 * **完全一致**（同样的 `AppleUI({ Width, Height, Circle, Blur, NeoStrength,
 * ProUI, Click, Vibrate })` 与尾随闭包），内部用一个半透明背景 + 圆角来
 * 代表玻璃，保证布局尺寸、圆角、内容叠放与正式版一模一样。
 *
 * 这样就能在模拟器上真实验证布局与 dpi，而真机（arm64）仍然用正式包。
 *
 * ===== 切换方式 =====
 * 见 tools/switch_appleui.sh：把 oh-package.json5 的依赖在
 * 正式包与本地占位之间切换，然后 ohpm install。
 */
@Component
export struct AppleUI {
  /** 玻璃透镜宽度（vp） */
  @Prop Width: number = 210;
  /** 玻璃透镜高度（vp） */
  @Prop Height: number = 210;
  /** 圆角（半径占短边的百分比字符串，如 '100%' / '50%'） */
  @Prop Circle: string = '100%';
  /** 背景模糊度（占位版忽略） */
  @Prop Blur: number = 0;
  /** 边缘折射强度（占位版忽略） */
  @Prop NeoStrength: number = 0.20;
  /** 弹性交互（占位版忽略） */
  @Prop ProUI: boolean = false;
  /** 点击回调 */
  Click: () => void = () => {};
  /** 触感反馈（占位版忽略） */
  @Prop Vibrate: boolean = false;

  /** 尾随闭包：叠在玻璃之上的媒体内容 */
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent() {}

  /**
   * 把 '50%' 这类百分比换算成 vp 圆角。
   *
   * 与正式包语义一致：半径 = 短边 × 百分比 / 2。
   * （'100%' 即短边一半 = 全圆；'50%' = 短边 1/4。）
   * 布局上圆角不影响尺寸，但影响观感，因此这里也照做。
   */
  private radiusVp(): number {
    let pct: number = 100;
    try {
      const raw: string = this.Circle.replace('%', '');
      const v: number = Number.parseFloat(raw);
      if (!Number.isNaN(v)) {
        pct = v;
      }
    } catch (e) {
      pct = 100;
    }
    const shortSide: number = Math.min(this.Width, this.Height);
    return shortSide * pct / 2 / 100;
  }

  build() {
    Stack() {
      // 占位玻璃：半透明底 + 圆角（尺寸与正式版完全一致）
      Column()
        .width(this.Width)
        .height(this.Height)
        .borderRadius(this.radiusVp())
        .backgroundColor('#33FFFFFF')
        .border({ width: 0.5, color: '#40FFFFFF' })

      // 媒体内容叠在玻璃之上，且与之同尺寸
      Column() {
        this.content()
      }
      .width(this.Width)
      .height(this.Height)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width(this.Width)
    .height(this.Height)
    .onClick(() => {
      this.Click();
    })
  }
}
