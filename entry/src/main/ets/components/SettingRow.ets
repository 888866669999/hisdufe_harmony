/*
 * SettingRow：设置页的一行（可点 / 只读两种形态）
 *
 * ===== 为什么是一个组件，而不是设置页里的 @Builder =====
 * 原先这些行是 SettingsPage 内的 `@Builder settingRow(label, subtitle, value, action)`。
 * `@Builder` 的参数是**按值传递**的：父组件重新构建时，参数被重新求值一次，
 * 但该行已有的子节点不随之更新。于是凡是「值来自异步加载的 @State」的行，
 * 都会永远停在首次构建时的默认值上。
 *
 * 实测到的现象：设置页「提前提醒」显示「课前 15 分钟」（初始默认值），
 * 而点开后浮层里勾选的是「课前 20 分钟」—— 浮层是打开时才新建的，
 * 读到的是真实值，两处就此矛盾。存储、浮层、重排提醒用的都是 20，只有那一行在骗人。
 *
 * 为什么以前没被发现：其它行的值来自 `@StorageProp`（开学日期、当前教学周），
 * 在首次构建前就已就位，看不出问题；而「节次作息」「学号」这类同样来自异步
 * @State 的行有同样的隐患，只是默认值与真实值恰好相同、或恰好非空而未暴露。
 *
 * 换成真正的 @Component 后，`@Prop` 是父 → 子单向同步：父组件重渲染时子组件的
 * 属性会被更新并触发自身刷新，与状态来源（同步或异步）无关。
 */
import { Theme } from '../theme/Theme';

@Component
export struct SettingRow {
  /** 左侧主文案 */
  @Prop label: string = '';
  /** 左侧副标题（可空，空则不占位） */
  @Prop subtitle: string = '';
  /** 右侧值（可空） */
  @Prop value: string = '';
  /**
   * 右侧值用品牌色。
   *
   * 用于「当前教学周」这类需要强调的值 —— 颜色取决于值本身是否有效，
   * 而那个判断属于调用方的语义，因此用布尔传进来而不是在这里猜。
   */
  @Prop brandValue: boolean = false;
  /** 主文案用危险色（退出登录） */
  @Prop danger: boolean = false;
  /** 是否显示右箭头。同时决定整行是否响应点击（与既有的 settingRow 一致） */
  @Prop chevron: boolean = false;

  /** 点击回调；仅在 chevron 为真时生效 */
  onTap: () => void = () => {};

  build() {
    Row({ space: Theme.GAP_S }) {
      Column({ space: 2 }) {
        Text(this.label)
          .fontSize(Theme.FS_BODY)
          .fontColor(this.danger ? $r('app.color.danger') : $r('app.color.text_primary'))
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.value.length > 0) {
        Text(this.value)
          .fontSize(Theme.FS_SMALL)
          .fontColor(this.brandValue
            ? $r('app.color.brand') : $r('app.color.text_tertiary'))
      }
      if (this.chevron) {
        Text('›')
          .fontSize(Theme.FS_SECTION)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ left: 6 })
      }
    }
    .width('100%')
    .padding({ left: Theme.GAP, right: Theme.GAP, top: 14, bottom: 14 })
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
    .onClick(() => {
      if (this.chevron) {
        this.onTap();
      }
    })
  }
}
