/*
 * 登录页：三步渐进式输入
 *
 *   第 1 步：账号          -> 点「下一步」
 *   第 2 步：密码          -> 点「下一步」
 *   第 3 步：验证码        -> 点「登 录」
 *
 * 设计要点：
 *   - 输入框统一为「长圆角胶囊」样式，不带前置图标
 *   - 验证码那一行 = 输入框 + 图片，两者总宽与上方密码框完全一致
 *   - 点击验证码图片自动刷新
 *   - 「记住账号密码」复选框在验证码下方，默认不勾选；勾选后存入系统密钥库
 */
import { AppState } from '../data/AppState';
import { GlassKit } from '../theme/GlassKit';
import { CredentialStore, Credential } from '../data/CredentialStore';
import { LoginResult } from '../network/QzApi';
import { AppError, ErrKind } from '../common/Result';
import { Logger } from '../common/Logger';
import { ContextHolder } from '../common/ContextHolder';
import { ReAuthService, CaptchaSolve } from '../data/ReAuthService';
import { ProfileService } from '../data/ProfileService';
import { Theme } from '../theme/Theme';
import { BASE_ORIGIN } from '../common/Constants';

@Component
export struct LoginPage {
  /** 由外部注入：登录成功回调 */
  onSuccess?: () => void;

  /** 当前步骤：1 账号 / 2 密码与验证码（同框） */
  @State step: number = 1;
  @State account: string = '';
  @State password: string = '';
  @State captcha: string = '';
  /** 记住账号密码，默认不勾选 */
  @State remember: boolean = false;
  @State busy: boolean = false;
  @State errorText: string = '';
  @State captchaData: string = '';
  /** 已保存凭据，用于回填后允许直接进入下一步 */
  @State hasSaved: boolean = false;
  /** 正在识别验证码 */
  @State solving: boolean = false;
  /** 验证码识别状态提示 */
  @State captchaHint: string = '';

  /** 输入框统一高度与圆角（胶囊） */
  private static readonly FIELD_H: number = 52;
  private static readonly FIELD_RADIUS: number = 26;
  /** 验证码图片宽度；输入框占剩余部分，两者之和等于整行宽度 */
  private static readonly CAPTCHA_W: number = 120;

  aboutToAppear(): void {
    this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    // 读取已保存的凭据，用于回填
    const saved: Credential | null = await CredentialStore.load();
    if (saved !== null && saved.account.length > 0) {
      this.account = saved.account;
      if (saved.password.length > 0) {
        this.password = saved.password;
        this.remember = true;
        this.hasSaved = true;
      }
    }
    await this.refreshCaptcha();
  }

  /**
   * 取一张新验证码并**自动识别填入**。
   *
   * 这是本页所有「需要验证码」时刻的统一入口：进入第二步、点图刷新、
   * 登录失败后换图，都走它。
   */
  private async refreshCaptcha(): Promise<void> {
    if (this.solving) {
      return;
    }
    this.solving = true;
    this.captchaHint = '正在识别验证码…';
    try {
      const ctx = ContextHolder.get();
      if (ctx === null) {
        this.errorText = '无法获取应用上下文';
        return;
      }
      const solved: CaptchaSolve | null = await ReAuthService.solveCaptcha(ctx);
      if (solved === null || solved.image === null) {
        this.captchaData = '';
        this.captchaHint = '';
        this.errorText = '验证码获取失败，请点击图片重试';
        return;
      }
      // 图与文本必须是同一张（见 CaptchaSolve 的说明）
      this.captchaData = solved.image.dataUri;
      if (solved.ocrOk) {
        this.captcha = solved.text;
        this.captchaHint = '已自动识别，如有误请直接修改';
      } else {
        // 识别失败不清空已有输入（用户可能已手输一部分）
        this.captchaHint = '未能自动识别，请手动输入';
      }
      this.errorText = '';
    } catch (e) {
      this.errorText = '无法连接教务系统，请检查网络';
      Logger.warn('refresh captcha failed');
    } finally {
      this.solving = false;
    }
  }

  /** 第 1 步 -> 第 2 步（同时取图并识别） */
  private nextFromAccount(): void {
    if (this.account.trim().length === 0) {
      this.errorText = '请输入账号';
      return;
    }
    this.errorText = '';
    this.step = 2;
    // 进入第二步才取图：验证码与会话绑定，早取会因会话轮换而失效
    this.refreshCaptcha();
  }

  /** 第 3 步：提交登录 */
  private async doLogin(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.captcha.trim().length === 0) {
      this.errorText = '请输入验证码';
      return;
    }
    this.busy = true;
    this.errorText = '';
    try {
      const res: LoginResult = await AppState.apiInstance().login(
        this.account.trim(), this.password, this.captcha.trim());
      if (res.success) {
        // 按勾选状态保存或清除凭据，并同步「是否有凭据」标志：
        // 它决定会话过期后是弹验证码弹窗续期，还是回登录页输全套。
        if (this.remember) {
          await CredentialStore.save(this.account.trim(), this.password);
          ReAuthService.setCredentialFlag(true);
        } else {
          await CredentialStore.clear();
          ReAuthService.setCredentialFlag(false);
        }
        await AppState.onLoggedIn(this.account.trim());
        this.password = '';
        this.captcha = '';
        // 姓名显示在外壳上（侧栏标题下 / 内容页顶栏右侧），登录后立刻补上：
        // 新账号的缓存还不存在，这一次会真的联网取一次个人信息
        // （与用户进「我的」页是同一个请求，只是提前了）。
        ProfileService.prefetchOnce();
        if (this.onSuccess !== undefined) {
          this.onSuccess();
        }
      } else {
        this.errorText = res.message;
        // 验证码是一次性的，失败后必须换一张；新图会重新自动识别
        this.captcha = '';
        await this.refreshCaptcha();
      }
    } catch (e) {
      this.errorText = e instanceof AppError && (e as AppError).kind === ErrKind.NETWORK
        ? (e as AppError).toUserText() : '登录失败，请重试';
      await this.refreshCaptcha();
    } finally {
      this.busy = false;
    }
  }

  /** 返回上一步 */
  private back(): void {
    if (this.step === 2) {
      this.errorText = '';
      this.captchaHint = '';
      this.step = 1;
    }
  }

  /** 统一的胶囊输入框样式（含液态玻璃底衬） */
  @Styles
  pillField() {
    .width('100%')
    .height(LoginPage.FIELD_H)
    .backgroundColor($r('app.color.surface_variant'))
    // 液态玻璃底衬。这里是**磨砂**而不是 AppleUI 透镜：登录页是整页、
    // 不是浮层，背后是纯色背景 —— 透镜无内容可截，只会得到一块死板深色
    // （见 GlassKit 文件头的两类玻璃说明）。
    // 保留 backgroundColor：磨砂需要一点底色才能与背景分层，纯模糊会「散」。
    .backgroundEffect(GlassKit.fieldEffect())
    .borderRadius(LoginPage.FIELD_RADIUS)
    .padding({ left: 20, right: 20 })
  }

  /** 步骤指示 */
  @Builder
  stepDots() {
    Row({ space: 6 }) {
      ForEach([1, 2], (n: number) => {
        Row()
          .width(this.step >= n ? 22 : 8)
          .height(4)
          .backgroundColor(this.step >= n ? $r('app.color.brand') : $r('app.color.divider'))
          .borderRadius(2)
      }, (n: number) => n.toString())
    }
  }

  /** 主按钮 */
  @Builder
  primaryButton(label: string, action: () => void) {
    Button(this.busy ? '请稍候…' : label)
      .width('100%')
      .height(LoginPage.FIELD_H)
      .fontSize(Theme.FS_SECTION)
      .fontWeight(FontWeight.Medium)
      .backgroundColor($r('app.color.brand'))
      .fontColor($r('app.color.on_brand'))
      .borderRadius(LoginPage.FIELD_RADIUS)
      .enabled(!this.busy)
      .onClick(() => {
        action();
      })
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 0 }) {
          // 品牌区
          Column({ space: 6 }) {
            Text('hi山财')
              .fontSize(30)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
            Text('山东财经大学 · 教务系统')
              .fontSize(Theme.FS_SMALL)
              .fontColor($r('app.color.text_secondary'))
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .margin({ bottom: 36 })

          this.stepDots()

          // 步骤标题
          Text(this.step === 1 ? '请输入账号' : '请输入密码与验证码')
            .fontSize(Theme.FS_SECTION)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .margin({ top: 18, bottom: 10 })

          // ===== 第 1 步：账号 =====
          if (this.step === 1) {
            TextInput({ placeholder: '学号', text: this.account })
              .pillField()
              .type(InputType.Number)
              .fontSize(16)
              .maxLength(20)
              .onChange((v: string) => {
                this.account = v;
                this.errorText = '';
              })
              .onSubmit(() => {
                this.nextFromAccount();
              })
            Blank().height(20)
            this.primaryButton('下一步', () => {
              this.nextFromAccount();
            })
          }

          // ===== 第 2 步：密码与验证码同框 =====
          if (this.step === 2) {
            // 一个容器装两行：上密码、下验证码。两行共用背景与边框，
            // 视觉上是「一个登录框」而不是两个独立输入项。
            Column() {
              // 第一行：密码
              Row({ space: 10 }) {
                Text('🔒')
                  .fontSize(15)
                TextInput({ placeholder: '密码', text: this.password })
                  .layoutWeight(1)
                  .height(LoginPage.FIELD_H)
                  .backgroundColor(Color.Transparent)
                  .padding(0)
                  .fontSize(16)
                  .type(InputType.Password)
                  .onChange((v: string) => {
                    this.password = v;
                    this.errorText = '';
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16 })

              Divider()
                .strokeWidth(0.5)
                .color($r('app.color.divider'))

              // 第二行：验证码 + 图片
              Row({ space: 10 }) {
                Text('✅')
                  .fontSize(15)
                TextInput({ placeholder: '验证码', text: this.captcha })
                  .layoutWeight(1)
                  .height(LoginPage.FIELD_H)
                  .backgroundColor(Color.Transparent)
                  .padding(0)
                  .fontSize(16)
                  .maxLength(6)
                  .onChange((v: string) => {
                    this.captcha = v;
                    this.errorText = '';
                  })
                  .onSubmit(() => {
                    this.doLogin();
                  })

                // 点击图片刷新验证码（新图会重新自动识别）
                Stack() {
                  if (this.captchaData.length > 0) {
                    Image(this.captchaData)
                      .objectFit(ImageFit.Contain)
                      .width('100%')
                      .height('100%')
                      .borderRadius(6)
                  } else {
                    Text(this.solving ? '识别中' : '点击刷新')
                      .fontSize(Theme.FS_TINY)
                      .fontColor($r('app.color.text_tertiary'))
                  }
                }
                .width(96)
                .height(38)
                .backgroundColor($r('app.color.surface'))
                .borderRadius(6)
                .clip(true)
                .onClick(() => {
                  this.captcha = '';
                  this.refreshCaptcha();
                })
              }
              .width('100%')
              .padding({ left: 16, right: 16 })
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .backgroundColor($r('app.color.surface_variant'))
            .borderRadius(Theme.RADIUS)
            .clip(true)

            // 识别状态提示
            if (this.captchaHint.length > 0) {
              Row({ space: 6 }) {
                if (this.solving) {
                  LoadingProgress()
                    .width(14)
                    .height(14)
                    .color($r('app.color.text_tertiary'))
                }
                Text(this.captchaHint)
                  .fontSize(Theme.FS_TINY)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .margin({ top: 8 })
            }

            // 记住账号密码（默认不勾选）
            Row({ space: 6 }) {
              Checkbox()
                .select(this.remember)
                .selectedColor($r('app.color.brand'))
                .onChange((v: boolean) => {
                  this.remember = v;
                })
              Text('记住账号密码')
                .fontSize(Theme.FS_SMALL)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .margin({ top: 14 })

            Blank().height(20)
            this.primaryButton('登 录', () => {
              this.doLogin();
            })
          }

          // 错误提示
          if (this.errorText.length > 0) {
            Text(this.errorText)
              .fontSize(Theme.FS_SMALL)
              .fontColor($r('app.color.danger'))
              .width('100%')
              .margin({ top: 12 })
          }

          // 返回上一步
          if (this.step > 1) {
            Text('返回上一步')
              .fontSize(Theme.FS_SMALL)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 18 })
              .onClick(() => {
                this.back();
              })
          }

          // 底部说明
          Column({ space: 4 }) {
            Text('仅用于本人账号的正当学习用途')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.Center)
            Text(BASE_ORIGIN)
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .margin({ top: 40 })
        }
        .width('100%')
        .constraintSize({ maxWidth: 420 })
        .padding({ left: Theme.GAP_L, right: Theme.GAP_L, top: 40, bottom: 40 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Center)
      .scrollBar(BarState.Off)
      // 键盘弹出时压缩可视区而不是整体上移，避免输入框被顶出屏幕
      .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }
}
