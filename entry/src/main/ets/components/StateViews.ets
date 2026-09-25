/*
 * 通用状态组件：加载中 / 空态 / 错误
 */
import { Theme } from '../theme/Theme';

@Component
export struct LoadingView {
  message: string = '正在加载…';

  build() {
    Column({ space: Theme.GAP }) {
      LoadingProgress()
        .width(48)
        .height(48)
        .color($r('app.color.brand'))
      Text(this.message)
        .fontSize(Theme.FS_BODY)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}

@Component
export struct EmptyView {
  title: string = '暂无数据';
  hint: string = '';

  build() {
    Column({ space: Theme.GAP_S }) {
      Text('—')
        .fontSize(40)
        .fontColor($r('app.color.text_tertiary'))
      Text(this.title)
        .fontSize(Theme.FS_SECTION)
        .fontColor($r('app.color.text_secondary'))
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(Theme.PAGE_PAD)
  }
}

@Component
export struct ErrorView {
  message: string = '出错了';
  detail: string = '';
  onRetry?: () => void;

  build() {
    Column({ space: Theme.GAP }) {
      Text('!')
        .fontSize(36)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.danger'))
      Text(this.message)
        .fontSize(Theme.FS_BODY)
        .fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.Center)
      if (this.detail.length > 0) {
        Text(this.detail)
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
      }
      if (this.onRetry !== undefined) {
        Button('重试')
          .fontSize(Theme.FS_BODY)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.on_brand'))
          .onClick(() => {
            if (this.onRetry !== undefined) {
              this.onRetry();
            }
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(Theme.PAGE_PAD)
  }
}

/** 卡片容器 */
@Component
export struct CardBox {
  @BuilderParam content: () => void;

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS)
    .padding(Theme.GAP_L)
  }
}
