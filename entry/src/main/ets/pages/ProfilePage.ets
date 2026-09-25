/*
 * 个人信息页：学籍卡片（分组展示）
 *
 * ===== 缓存（对齐 Flutter 端）=====
 * 走 PageCache 三层缓存（内存 → 磁盘 → 网络），TTL 见 Constants 的 TTL_PROFILE。
 * 两个行为要点：
 *   1. 首帧用 peek() 拿缓存直接渲染，**不铺整屏加载态** —— 切页回来不会闪；
 *   2. 刷新失败**保留已有内容**，只在顶部给一条内联提示。
 *      早先失败会把整页换成 ErrorView，用户正看着的信息就没了。
 *
 * ===== 加载器为什么搬到了 ProfileService =====
 * 姓名显示在**外壳**上（侧栏标题下、内容页顶栏右侧），而早先只有本页会
 * 往 AppStorage 里写它 —— 于是不点进「我的」就一直是空的（用户反馈的 bug）。
 * 现在外壳侧与本页共用 ProfileService 的同一个加载器（同一份缓存 key 与 TTL），
 * 不会再出现两边各写一套、改了一边忘了另一边。
 */
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { promptAction } from '@kit.ArkUI';
import { AppState } from '../data/AppState';
import { StudentProfile, ProfileSection, ProfileField } from '../model/Models';
import { AppError } from '../common/Result';
import { ReAuthService } from '../data/ReAuthService';
import { PageDataLoader, PageLoadResult } from '../data/PageCache';
import { ProfileService } from '../data/ProfileService';
import { AvatarStore } from '../data/AvatarStore';
import { Theme } from '../theme/Theme';
import { LoadingView, EmptyView, ErrorView } from '../components/StateViews';
import { AppIcon } from '../components/AppIcon';
import { Logger } from '../common/Logger';
import { AS_STUDENT_NAME, AS_STUDENT_ID } from '../data/AppState';

@Component
export struct ProfilePage {
  @State loading: boolean = true;
  /**
   * 下拉刷新状态（`$$` 双向绑定给 Refresh）。
   * 刷新结束必须置回 false，否则指示器会一直转 —— 见 load 的 finally。
   */
  @State refreshing: boolean = false;
  @State errorText: string = '';
  @State profile: StudentProfile = new StudentProfile();
  /**
   * 自定义头像的 URI（空串 = 用姓名末字的占位）。
   *
   * 必须放进 @State：保存/清除后要让界面重画，而 AvatarStore 是普通静态类，
   * 它的变化不会触发任何刷新。
   */
  @State avatarUri: string = '';

  aboutToAppear(): void {
    this.avatarUri = AvatarStore.uri();
    // 先用内存缓存填首帧，再交给 load 决定要不要联网。
    // 这样切页回来（缓存还在内存里）不会闪一下加载态。
    const cached: StudentProfile | null = this.loader().peek();
    if (cached !== null) {
      this.applyProfile(cached);
      this.loading = false;
    }
    this.load();
  }

  /** 加载器统一由 ProfileService 提供（外壳侧预取用的是同一个） */
  private loader(): PageDataLoader<StudentProfile> {
    return ProfileService.loader();
  }

  private applyProfile(p: StudentProfile): void {
    AppState.profile = p;
    this.profile = p;
    ProfileService.publish(p);
  }

  private async load(interactive: boolean = false,
    force: boolean = false): Promise<void> {
    // 已有内容时不铺整屏加载态：切页回来该立刻看到旧资料
    this.errorText = '';
    if (this.profile.name.length === 0 && this.profile.sections.length === 0) {
      this.loading = true;
    }
    try {
      const r: PageLoadResult<StudentProfile> = await this.loader().load(force);
      this.applyProfile(r.data);
    } catch (e) {
      // 会话失效：先试静默续期（已保存账号密码 + OCR 自动登录）。
      // 成功就直接重载，用户完全无感；失败时**自动加载不弹窗**、
      // 只给一句内联提示，等用户主动点重试才升级为弹窗。
      const renewed: boolean = await ReAuthService.recoverIfExpired(e, interactive);
      if (renewed) {
        await this.load(interactive);
        return;
      }
      const msg: string = AppError.describe(e);
      // 失败只置内联提示，**不清空 profile** —— 用户继续看到旧资料
      this.errorText = AppError.isAuthExpired(e)
        ? '登录状态已过期，重新加载即可自动登录' : msg;
    } finally {
      this.loading = false;
      // 复位下拉指示器（`$$` 双向绑定，不置回会一直转）
      this.refreshing = false;
    }
  }

  /** 头像占位：取姓名末字 */
  private avatarText(): string {
    const n: string = this.profile.name;
    return n.length > 0 ? n.substring(n.length - 1) : '生';
  }

  /**
   * 选一张图片作为头像。
   *
   * 用系统的**图片选择器**而不是自绘九宫格：相册权限、多选、裁剪入口都由
   * 系统组件负责，且它返回的是带临时读权限的 URI（拿到后立刻复制进应用目录，
   * 见 AvatarStore 的说明）。
   */
  private async pickAvatar(): Promise<void> {
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const opts: photoAccessHelper.PhotoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      // 单选：头像是单个当前值，多选没有意义
      opts.maxSelectNumber = 1;
      const res: photoAccessHelper.PhotoSelectResult = await picker.select(opts);
      if (res.photoUris.length === 0) {
        return;
      }
      const saved: string = await AvatarStore.saveFrom(res.photoUris[0]);
      if (saved.length === 0) {
        promptAction.showToast({ message: '头像保存失败，请重试' });
        return;
      }
      // 路径变了（文件名带时间戳）→ @State 一变就重画，解码缓存不会命中旧图
      this.avatarUri = AvatarStore.uri();
    } catch (e) {
      // 用户在系统选择器里取消不算错误，这里只记日志、不打扰用户
      Logger.warn('avatar pick cancelled or failed');
    }
  }

  /** 长按头像 → 提供「清除自定义头像」的入口（没有头像时不弹） */
  private async confirmClearAvatar(): Promise<void> {
    if (!AvatarStore.has()) {
      return;
    }
    try {
      const res: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
        title: '头像',
        message: '清除自定义头像，改用姓名末字？',
        buttons: [
          { text: '取消', color: '#5A6070' },
          { text: '清除', color: '#D92D20' }
        ]
      });
      // showDialog 的返回值里 index 0 = 第一个按钮（取消）
      if (res.index !== 1) {
        return;
      }
    } catch (e) {
      return;
    }
    await AvatarStore.clear();
    this.avatarUri = AvatarStore.uri();
  }

  /** 圆形头像：有自定义图就用图，否则退回姓名末字 */
  @Builder
  avatar() {
    Stack() {
      if (this.avatarUri.length > 0) {
        Image(this.avatarUri)
          .width(56)
          .height(56)
          .borderRadius(28)
          .objectFit(ImageFit.Cover)
          // 裁剪成圆形：Cover 只保证铺满，方形图仍会是圆角矩形
          .clip(true)
      } else {
        Text(this.avatarText())
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.on_brand'))
          .width(56)
          .height(56)
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.brand'))
          .borderRadius(28)
      }
      // 右下角的小相机角标：没有它用户不知道头像是可以点的
      Column() {
        AppIcon({ res: 'photo_camera', iconSize: 12, color: $r('app.color.on_brand') })
      }
      .width(20)
      .height(20)
      .borderRadius(10)
      .backgroundColor($r('app.color.brand'))
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .border({ width: 1.5, color: $r('app.color.surface') })
      .position({ x: 38, y: 38 })
    }
    .width(56)
    .height(56)
    .onClick(() => {
      this.pickAvatar();
    })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          this.confirmClearAvatar();
        })
    )
  }

  @Builder
  header() {
    Row({ space: Theme.GAP }) {
      this.avatar()
      Column({ space: 4 }) {
        Text(this.profile.name.length > 0 ? this.profile.name : '未获取到姓名')
          .fontSize(Theme.FS_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(this.profile.studentId.length > 0 ? ('学号 ' + this.profile.studentId) : '')
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(Theme.GAP_L)
    .backgroundColor($r('app.color.surface'))
    // 圆角 + 裁剪：早先这块是**直角**的白色矩形，在一堆圆角卡片里格外突兀
    // （用户要求改成圆角）。与 sectionBlock 用同一档圆角，整页语言一致。
    .borderRadius(Theme.RADIUS_SM)
    .clip(true)
  }

  @Builder
  sectionBlock(sec: ProfileSection) {
    Column({ space: 0 }) {
      Text(sec.title)
        .fontSize(Theme.FS_SMALL)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ left: Theme.GAP, right: Theme.GAP, top: Theme.GAP, bottom: Theme.GAP_S })
      ForEach(sec.fields, (f: ProfileField, idx: number) => {
        Row() {
          Text(f.label)
            .fontSize(Theme.FS_SMALL)
            .fontColor($r('app.color.text_tertiary'))
            .width(96)
          Text(f.value)
            .fontSize(Theme.FS_BODY)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .padding({ left: Theme.GAP, right: Theme.GAP, top: 10, bottom: 10 })
        .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
      }, (f: ProfileField) => sec.title + '-' + f.label)
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_SM)
    .clip(true)
  }

  build() {
    // 下拉刷新：以 force 调用，绕过 TTL 强制联网（对齐 Flutter 端）。
    // 本页顶部没有固定筛选栏，整页可滚，所以整体包在 Refresh 里。
    Refresh({ refreshing: $$this.refreshing }) {
    Column() {
      if (this.loading) {
        LoadingView({ message: '正在获取个人信息…' })
      } else if (this.errorText.length > 0 && this.profile.sections.length === 0) {
        // 没有任何内容可显示时才整屏报错（首次进入且失败）
        ErrorView({
          message: this.errorText,
          onRetry: () => {
            this.load(true);
          }
        })
      } else if (this.profile.sections.length === 0) {
        EmptyView({ title: '暂无个人信息' })
      } else {
        Scroll() {
          Column({ space: Theme.GAP }) {
            // 刷新失败的提示：**只加一条横幅，不换掉页面**。
            // 用户已经看到的资料比「这次刷新成功与否」重要得多。
            if (this.errorText.length > 0) {
              Text(this.errorText)
                .fontSize(Theme.FS_TINY)
                .fontColor($r('app.color.warning'))
                .width('100%')
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .borderRadius(Theme.RADIUS_SM)
                .backgroundColor($r('app.color.warning'))
                .opacity(0.92)
            }
            this.header()
            ForEach(this.profile.sections, (sec: ProfileSection) => {
              this.sectionBlock(sec)
            }, (sec: ProfileSection) => sec.title + sec.fields.length.toString())
          }
          .width('100%')
          // 底部多留出浮层 dock 的高度，否则最后一项资料会被玻璃压住
          .padding({ left: Theme.GAP, right: Theme.GAP, top: Theme.GAP,
            bottom: Theme.GAP + Theme.bottomInset() })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
    }
    .onRefreshing(() => {
      this.load(false, true);
    })
    .layoutWeight(1)
    .width('100%')
  }
}
