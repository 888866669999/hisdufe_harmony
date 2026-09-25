/*
 * ReAuthDialog：会话失效时的「重新验证」弹窗
 *
 * ===== 为什么是弹窗而不是跳登录页 =====
 * 会话过期时跳回登录页会丢失用户的浏览位置；而课表数据在本地缓存里，
 * 用户往往只是想看看课表。因此改为：**请求真的失败时才弹这个居中弹窗**，
 * 页面与位置保持不变，补完验证即继续。
 * 用户若只浏览课表（不发请求），则永远不会看到它。
 *
 * ===== 两种形态 =====
 *   1. **有已保存账号密码**（密钥库里有一份）：只需补验证码。
 *      打开时先尝试自动登录（OCR 识别 → 静默提交），成功即无感续期；
 *      不可用/失败则降级为手动输入验证码。
 *   2. **没有保存账号密码**：弹出完整的账号密码 + 验证码表单，
 *      并提供「记住账号密码」，勾选后下次即可走无感路径。
 *
 * 两种形态都不清会话、不跳页，验证成功后由父组件刷新当前页数据。
 */
import { Theme } from '../theme/Theme';
import { GlassKit } from '../theme/GlassKit';
import { Logger } from '../common/Logger';
import { ContextHolder } from '../common/ContextHolder';
import { CredentialStore, Credential } from '../data/CredentialStore';
import { ReAuthService, AutoLoginOutcome, CaptchaImage, CaptchaSolve, MAX_LOGIN_ATTEMPTS } from '../data/ReAuthService';

@Component
export struct ReAuthDialog {
  /** 验证成功（父组件据此刷新当前页面数据） */
  onDone?: () => void;
  /** 放弃：彻底退出到登录页 */
  onGiveUp?: () => void;

  @State busy: boolean = false;
  @State hint: string = '';
  @State errorText: string = '';
  /** 是否有已保存的账号密码 */
  @State hasCred: boolean = false;
  /** 是否已进入手动输入（自动登录失败后置位） */
  @State manual: boolean = false;
  /** 是否需要展示完整的账号密码表单（无凭据时） */
  @State fullForm: boolean = false;
  /** 表单字段 */
  @State account: string = '';
  @State password: string = '';
  @State captcha: string = '';
  @State remember: boolean = false;
  @State captchaData: string = '';
  /** 输入步骤：无凭据时沿用「账号 → 密码 → 验证码」三步，避免信息过载 */
  @State step: number = 1;
  /** 正在识别验证码 */
  @State solving: boolean = false;

  private static readonly CAPTCHA_W: number = 110;
  private static readonly FIELD_H: number = 48;
  private static readonly FIELD_RADIUS: number = 24;

  aboutToAppear(): void {
    this.start();
  }

  private async start(): Promise<void> {
    const cred: Credential | null = await CredentialStore.load();
    if (cred !== null && cred.account.length > 0) {
      this.account = cred.account;
      this.remember = true;
    }
    this.hasCred = cred !== null && cred.password.length > 0;
    if (this.hasCred && cred !== null) {
      // 关键：必须把密码也恢复出来。早先漏了这一行，导致提交时密码为空，
      // 服务端直接回「用户名或密码为空!」，表现为「验证码怎么输都登不上」。
      this.password = cred.password;
    }
    await ReAuthService.refreshCredentialFlag();

    if (!this.hasCred) {
      // 没有保存密码 → 完整登录表单（含「记住账号密码」）
      this.fullForm = true;
      this.manual = true;
      this.hint = '登录状态已过期，请重新登录。可用「记住账号密码」下次自动续期。';
      await this.loadCaptcha();
      return;
    }

    // 有凭据 → 先尝试无感自动登录（交互路径，允许换图重试若干次）
    this.busy = true;
    this.hint = ReAuthService.ocrAvailable() ? '正在自动识别验证码…' : '正在准备…';
    const out: AutoLoginOutcome = await ReAuthService.autoLoginWithRetry(MAX_LOGIN_ATTEMPTS);
    this.busy = false;
    if (out.ok) {
      Logger.info('reauth dialog: auto login ok');
      if (this.onDone !== undefined) {
        this.onDone();
      }
      return;
    }
    this.manual = true;
    this.hint = out.reason;
    // 关键：用 OCR 时的那张图，而不是另取一张。
    // 早先这里是「预填 OCR 文本 + loadCaptcha() 取新图」，
    // 预填内容与所见图必然不一致，用户直接提交必然失败 ——
    // 会被误当成「OCR 识别不行」。现在图文一致，用户只需改错的那一位。
    if (out.captchaImage.length > 0) {
      this.captchaData = out.captchaImage;
      this.errorText = '';
      if (out.triedCaptcha.length > 0) {
        this.captcha = out.triedCaptcha;
      }
    } else {
      await this.loadCaptcha();
    }
  }

  /**
   * 取一张新验证码并**自动识别填入**。
   *
   * 与登录页走同一个 `ReAuthService.solveCaptcha`，因此两处的
   * 识别优先级（模型优先、通用 OCR 兜底）与降级行为完全一致。
   */
  private async loadCaptcha(): Promise<void> {
    if (this.solving) {
      return;
    }
    this.solving = true;
    try {
      const ctx = ContextHolder.get();
      if (ctx === null) {
        this.errorText = '无法获取应用上下文';
        return;
      }
      const solved: CaptchaSolve | null = await ReAuthService.solveCaptcha(ctx);
      if (solved === null || solved.image === null) {
        this.captchaData = '';
        this.errorText = '验证码获取失败，请点击图片重试';
        return;
      }
      // 图与文本必须是同一张（见 CaptchaSolve 的说明）
      this.captchaData = solved.image.dataUri;
      if (solved.ocrOk) {
        this.captcha = solved.text;
        this.hint = '验证码已自动识别，如有误请直接修改';
      } else {
        this.hint = '未能自动识别，请手动输入验证码';
      }
      this.errorText = '';
    } catch (e) {
      this.errorText = '验证码获取失败，请点击图片重试';
    } finally {
      this.solving = false;
    }
  }

  /**
   * 表单推进：账号 → 密码与验证码（同框）。
   *
   * 密码与验证码合并成一步：两者都是登录凭据，分两步只多按一次按钮；
   * 而验证码要配图片，单独占一屏不如与密码并排紧凑。
   */
  private nextStep(): void {
    if (this.step === 1) {
      if (this.account.trim().length === 0) {
        this.errorText = '请输入账号';
        return;
      }
      this.errorText = '';
      this.step = 2;
      // 进入第二步才取图：验证码与会话绑定，早取会因会话轮换而失效
      this.loadCaptcha();
      return;
    }
    // 第二步：账号密码验证码齐了就直接提交
    this.submit();
  }

  /** 提交：有凭据走「凭据+验证码」，无凭据走完整表单 */
  private async submit(): Promise<void> {
    if (this.busy) {
      return;
    }
    // 前置校验：账号密码缺一不可。否则服务端只会回一句
    // 「用户名或密码为空!」，用户完全看不出是哪里缺了。
    if (this.account.trim().length === 0 || this.password.length === 0) {
      this.errorText = '账号或密码缺失，请重新登录';
      this.fullForm = true;
      this.manual = true;
      this.step = this.account.trim().length === 0 ? 1 : 2;
      return;
    }
    if (this.captcha.trim().length === 0) {
      this.errorText = '请输入验证码';
      return;
    }
    this.busy = true;
    this.errorText = '';
    const out: AutoLoginOutcome = await ReAuthService.loginWithSaved(
      this.account.trim(), this.password, this.captcha.trim());
    this.busy = false;
    if (out.ok) {
      // 无凭据形态下：按勾选决定是否记住，下次即可无感续期
      if (this.fullForm) {
        if (this.remember) {
          await CredentialStore.save(this.account.trim(), this.password);
          ReAuthService.setCredentialFlag(true);
        } else {
          await CredentialStore.clear();
          ReAuthService.setCredentialFlag(false);
        }
      }
      this.password = '';
      this.captcha = '';
      if (this.onDone !== undefined) {
        this.onDone();
      }
      return;
    }
    this.errorText = out.reason;
    // 验证码已被消费，换一张并清空输入
    this.captcha = '';
    await this.loadCaptcha();
  }

  /** 重试一次自动识别（仅「有凭据」形态） */
  private async retryAuto(): Promise<void> {
    if (this.busy || !this.hasCred) {
      return;
    }
    this.manual = false;
    this.errorText = '';
    await this.start();
  }

  /**
   * 验证码行（输入框 + 图片，两者总宽等于整行）。
   *
   * 刻意用**无参** @Builder：ArkUI 里 @Builder 的参数按值传递、只在首次构建时求值，
   * 把 captcha/captchaData 当参数传进来会导致输入与刷新不生效。
   * 直接读 this.* 才能随 @State 更新。
   */
  @Builder
  captchaRow() {
    Row({ space: Theme.GAP_S }) {
      TextInput({ placeholder: '验证码', text: this.captcha })
        .layoutWeight(1)
        .height(ReAuthDialog.FIELD_H)
        .fontSize(Theme.FS_BODY)
        .backgroundColor($r('app.color.surface_variant'))
        .backgroundEffect(GlassKit.fieldEffect())
        .borderRadius(ReAuthDialog.FIELD_RADIUS)
        .padding({ left: 16, right: 16 })
        .onChange((v: string) => {
          this.captcha = v;
        })
      if (this.captchaData.length > 0) {
        Image(this.captchaData)
          .width(ReAuthDialog.CAPTCHA_W)
          .height(ReAuthDialog.FIELD_H)
          .objectFit(ImageFit.Contain)
          .borderRadius(Theme.RADIUS_SM)
          .backgroundColor($r('app.color.surface_variant'))
          .onClick(() => {
            this.captcha = '';
            this.loadCaptcha();
          })
      } else {
        Text('获取中…')
          .width(ReAuthDialog.CAPTCHA_W)
          .height(ReAuthDialog.FIELD_H)
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
          .backgroundColor($r('app.color.surface_variant'))
          .borderRadius(Theme.RADIUS_SM)
          .onClick(() => {
            this.loadCaptcha();
          })
      }
    }
    .width('100%')
  }

  build() {
    // 只输出面板内容：遮罩、玻璃底、圆角、居中全部由外层 GlassOverlay 负责
    // （它是页面级的浮层外壳，见 Index.ets 的挂载点）。
    Column({ space: Theme.GAP_S }) {
        Text('需要重新登录')
          .fontSize(Theme.FS_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')

        Text(this.hint)
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')

        // ---- 有凭据：只需验证码（或等待自动登录） ----
        if (this.hasCred && this.manual) {
          this.captchaRow()
          Text('账号密码已保存，验证码已自动识别；如有误可直接修改')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        } else if (this.hasCred && this.busy) {
          Row({ space: 8 }) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color($r('app.color.brand'))
            Text('正在自动登录…')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
        }

        // ---- 无凭据：完整账号/密码/验证码表单 ----
        // 加 !hasCred 限定：与上面「有凭据只需验证码」的两块互斥，
        // 避免两个表单同时渲染（原先两个独立 if 在同一层级）。
        if (this.fullForm && !this.hasCred) {
          if (this.step === 1) {
            Text('请输入账号')
              .fontSize(Theme.FS_SMALL)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            TextInput({ placeholder: '学号', text: this.account })
              .width('100%')
              .height(ReAuthDialog.FIELD_H)
              .fontSize(Theme.FS_BODY)
              .backgroundColor($r('app.color.surface_variant'))
              .backgroundEffect(GlassKit.fieldEffect())
              .borderRadius(ReAuthDialog.FIELD_RADIUS)
              .padding({ left: 16, right: 16 })
              .onChange((v: string) => {
                this.account = v;
              })
          } else {
            // 第 2 步：密码与验证码同框（两行共用一个容器）
            Text('请输入密码与验证码')
              .fontSize(Theme.FS_SMALL)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Column() {
              Row({ space: 10 }) {
                Text('🔒').fontSize(15)
                TextInput({ placeholder: '密码', text: this.password })
                  .layoutWeight(1)
                  .height(ReAuthDialog.FIELD_H)
                  .backgroundColor(Color.Transparent)
                  .padding(0)
                  .fontSize(Theme.FS_BODY)
                  .type(InputType.Password)
                  .onChange((v: string) => {
                    this.password = v;
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16 })

              Divider()
                .strokeWidth(0.5)
                .color($r('app.color.divider'))

              Row({ space: 10 }) {
                Text('✅').fontSize(15)
                TextInput({ placeholder: '验证码', text: this.captcha })
                  .layoutWeight(1)
                  .height(ReAuthDialog.FIELD_H)
                  .backgroundColor(Color.Transparent)
                  .padding(0)
                  .fontSize(Theme.FS_BODY)
                  .maxLength(6)
                  .onChange((v: string) => {
                    this.captcha = v;
                  })
                if (this.captchaData.length > 0) {
                  Image(this.captchaData)
                    .width(96)
                    .height(38)
                    .objectFit(ImageFit.Contain)
                    .borderRadius(6)
                    .backgroundColor($r('app.color.surface'))
                    .onClick(() => {
                      this.captcha = '';
                      this.loadCaptcha();
                    })
                } else {
                  Text(this.solving ? '识别中' : '点击刷新')
                    .width(96)
                    .height(38)
                    .fontSize(Theme.FS_TINY)
                    .fontColor($r('app.color.text_tertiary'))
                    .textAlign(TextAlign.Center)
                    .backgroundColor($r('app.color.surface'))
                    .borderRadius(6)
                    .onClick(() => {
                      this.loadCaptcha();
                    })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16 })
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .backgroundColor($r('app.color.surface_variant'))
            .borderRadius(Theme.RADIUS)
            .clip(true)

            Row({ space: 8 }) {
              Checkbox({ name: 'remember', group: 'reauth' })
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
          }
        }

        if (this.errorText.length > 0) {
          Text(this.errorText)
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.danger'))
            .width('100%')
        }

        // ---- 操作区 ----
        Row({ space: Theme.GAP_S }) {
          Button(this.fullForm ? '取消' : '退出登录')
            .layoutWeight(1)
            .height(44)
            .fontSize(Theme.FS_SMALL)
            .backgroundColor($r('app.color.surface_variant'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => {
              if (this.onGiveUp !== undefined) {
                this.onGiveUp();
              }
            })

          if (this.fullForm) {
            if (this.step < 2) {
              Button('下一步')
                .layoutWeight(1)
                .height(44)
                .fontSize(Theme.FS_SMALL)
                .backgroundColor($r('app.color.brand'))
                .fontColor($r('app.color.on_brand'))
                .onClick(() => {
                  this.nextStep();
                })
            } else {
              Button(this.busy ? '登录中…' : '登录')
                .layoutWeight(1)
                .height(44)
                .fontSize(Theme.FS_SMALL)
                .enabled(!this.busy)
                .backgroundColor($r('app.color.brand'))
                .fontColor($r('app.color.on_brand'))
                .onClick(() => {
                  this.submit();
                })
            }
          } else if (this.manual) {
            Button(this.busy ? '验证中…' : '继续')
              .layoutWeight(1)
              .height(44)
              .fontSize(Theme.FS_SMALL)
              .enabled(!this.busy)
              .backgroundColor($r('app.color.brand'))
              .fontColor($r('app.color.on_brand'))
              .onClick(() => {
                this.submit();
              })
          } else {
            Button('手动输入')
              .layoutWeight(1)
              .height(44)
              .fontSize(Theme.FS_SMALL)
              .backgroundColor($r('app.color.brand'))
              .fontColor($r('app.color.on_brand'))
              .onClick(() => {
                this.manual = true;
                this.hint = '请输入验证码继续';
                this.loadCaptcha();
              })
          }
        }
        .width('100%')
        .margin({ top: 2 })

        // 手动模式下仍允许再试一次自动识别
        if (this.hasCred && this.manual && ReAuthService.ocrAvailable()) {
          Text('重新尝试自动识别')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.brand'))
            .onClick(() => {
              this.retryAuto();
            })
        }
    }
    .width('100%')
    .height('100%')
    .padding(GlassKit.PANEL_PAD)
    .alignItems(HorizontalAlign.Start)
    // 刻意不设背景色：面板的底由外层 GlassOverlay 的磨砂玻璃提供
  }
}
