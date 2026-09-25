/*
 * PlanPage：培养方案明细
 *
 * 内容分三块：
 *   1. 培养目标 / 详细说明（文本段落）
 *   2. 课程设置总表：按「课程体系」分组展示，含学分与学时
 *   3. 培养方案 PDF：**交给系统里其它应用打开**（本页不做任何预览）
 *
 * ===== 为什么删掉了内嵌预览 =====
 * 早先这一页用 @kit.PDFKit 的 PdfView 把 PDF 逐页渲染成位图嵌在页面里
 * （可滚动、可翻页、可全屏）。这条路的代价与收益不成比例：
 *   · 依赖 `SystemCapability.OfficeService.PDFService.Core`，部分设备
 *     （模拟器、非华为设备）根本没有，界面上表现为「一片空白」；
 *   · 为了自绘预览写了近 600 行组件（页位图缓存、缩放矩阵、手势分发），
 *     而这套东西系统 PDF 阅读器本来就做好了，且做得更好（搜索、跳页、批注）；
 *   · 位图要驻留内存，几百页的方案在低内存设备上会被系统直接杀掉。
 * 现在只保留「下载 → 用其它应用打开」这一条路：应用负责把文件取到沙箱，
 * 阅读交给用户自己选的阅读器（系统会给「打开方式」选择器）。
 * 这与 Flutter 端同一决策（那边也移除了 pdfrx 内嵌预览）。
 */
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { common, Want, wantConstant } from '@kit.AbilityKit';
import { AppState } from '../data/AppState';
import { PdfStore } from '../data/PdfStore';
import { ReAuthService } from '../data/ReAuthService';
import { PageCache, PageDataLoader, PageLoadResult } from '../data/PageCache';
import { PlanParser } from '../parser/PlanParser';
import { CACHE_PLAN, TTL_PLAN } from '../common/Constants';
import { PlanDetail, PlanGroup, PlanCourse } from '../model/Models';
import { AppError } from '../common/Result';
import { Logger } from '../common/Logger';
import { promptAction } from '@kit.ArkUI';
import { ContextHolder } from '../common/ContextHolder';
import { Theme } from '../theme/Theme';
import { LoadingView, EmptyView, ErrorView } from '../components/StateViews';
import { AppIcon } from '../components/AppIcon';

@Component
export struct PlanPage {
  @State loading: boolean = true;
  /**
   * 下拉刷新状态（`$$` 双向绑定给 Refresh）。
   * 刷新结束必须置回 false，否则指示器会一直转 —— 见 load 的 finally。
   */
  @State refreshing: boolean = false;
  @State errorText: string = '';
  @State plan: PlanDetail = new PlanDetail();
  /**
   * 展开的课程体系分组（本数组里的项是**收起**状态）。
   *
   * 默认全部收起（用户要求）：培养方案的分组很多，全展开会把 PDF 与
   * 其余内容一路推到很远的地方，进来第一眼看到的是一屏课程名。
   * 现在只列分组标题与学分合计，想细看哪一组再点开。
   */
  @State collapsed: string[] = [];
  /** PDF：正在下载 / 参数就绪（下载完成后为 true，供「打开」「保存」使用） */
  @State pdfBusy: boolean = false;
  @State pdfReady: boolean = false;
  /** 本地 PDF 路径（下载完成后才有值，用于外部打开与另存） */
  @State pdfLocalPath: string = '';
  /** 提示文案（下载失败、没有可打开的应用等） */
  @State pdfHint: string = '';

  aboutToAppear(): void {
    // 先用内存缓存填首帧（切页回来不闪加载态），再决定要不要联网
    const cached: PlanDetail | null = this.loader().peek();
    if (cached !== null) {
      this.applyPlan(cached);
      this.loading = false;
    }
    this.load();
  }

  private loader(): PageDataLoader<PlanDetail> {
    return new PageDataLoader<PlanDetail>(
      PageCache.keyOf(AppState.account, CACHE_PLAN),
      () => AppState.apiInstance().getPlanHtml(),
      (body: string) => PlanParser.parse(body),
      TTL_PLAN);
  }

  /** 落数据 + 首次进入时把分组全部收起 */
  private applyPlan(p: PlanDetail): void {
    this.plan = p;
    // 分组默认全部收起：拿到数据后把分组名都放进 collapsed。
    // 只在该次加载前是空数组（首次进入）时做，否则会把用户这次
    // 手动展开的分组又收回去。
    if (this.collapsed.length === 0 && p.groups.length > 0) {
      const names: string[] = [];
      for (let i = 0; i < p.groups.length; i++) {
        names.push(p.groups[i].system);
      }
      this.collapsed = names;
    }
    // PDF 不随页面加载自动下载：它是若干 MB 的附件，而多数用户只看课程表，
    // 不该被动承担这份流量。改由用户点「用其它应用打开 / 保存到文件」时
    // 按需下载（见 ensurePdfReady）。
  }

  private async load(interactive: boolean = false,
    force: boolean = false): Promise<void> {
    // 已有内容时不铺整屏加载态
    this.errorText = '';
    if (this.plan.groups.length === 0 && this.plan.introParagraphs.length === 0) {
      this.loading = true;
    }
    try {
      const r: PageLoadResult<PlanDetail> = await this.loader().load(force);
      this.applyPlan(r.data);
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
      this.errorText = AppError.isAuthExpired(e)
        ? '登录状态已过期，重新加载即可自动登录' : msg;
    } finally {
      this.loading = false;
      // 复位下拉指示器（`$$` 双向绑定，不置回会一直转）
      this.refreshing = false;
    }
  }

  /**
   * 确保 PDF 已下载到沙箱；已缓存时直接返回 true（不会重复下载）。
   *
   * 下载是几百 KB 到数 MB 的网络请求，因此只在用户真的要用它时才触发
   * （点「用其它应用打开」或「保存到文件」），进页面不自动下载。
   */
  private async ensurePdfReady(): Promise<boolean> {
    if (this.pdfReady && this.pdfLocalPath.length > 0) {
      return true;
    }
    if (this.plan.pdfPath.length === 0) {
      this.pdfHint = '本方案未附带 PDF 附件';
      return false;
    }
    const account: string = await AppState.resolveAccount();
    this.pdfBusy = true;
    this.pdfHint = '';
    try {
      const local: string = await PdfStore.download(AppState.cookieJar(), account, this.plan.pdfPath);
      this.pdfLocalPath = local;
      this.pdfReady = true;
      return true;
    } catch (e) {
      // PDF 下载是同一轮加载的后继步骤，同样先试静默续期。
      // 这里不递归重下（避免与主加载的续期竞争），续期成功后让用户
      // 点一下重试即可 —— 主加载路径已经把会话接上了。
      await ReAuthService.recoverIfExpired(e, false);
      const msg: string = AppError.describe(e);
      this.pdfHint = AppError.isAuthExpired(e)
        ? '登录状态已过期，重新加载即可自动登录' : msg;
      return false;
    } finally {
      this.pdfBusy = false;
    }
  }

  /** PDF 卡片的状态文案 */
  private pdfStatusText(): string {
    if (this.plan.pdfPath.length === 0) {
      return '本方案未附带 PDF 附件';
    }
    if (this.pdfBusy) {
      return '正在下载…';
    }
    if (this.pdfReady) {
      return '已下载，可交给其它应用打开';
    }
    return '点击后自动下载并打开';
  }

  /**
   * 用其它应用打开 PDF。
   *
   * 文件没下载就现下（用户点这一下就是要看文件，不该再要求他点第二次），
   * 下完转成**文件共享 URI** 再交给系统 —— 沙箱路径直接传出去，
   * 对方应用没有读取权限，会以「打不开」告终。
   */
  private async openExternally(): Promise<void> {
    const ctx: common.UIAbilityContext | null = ContextHolder.get();
    if (ctx === null) {
      this.pdfHint = '无法获取应用上下文';
      return;
    }
    if (!await this.ensurePdfReady()) {
      return;
    }
    try {
      const uri: string = fileUri.getUriFromPath(this.pdfLocalPath);
      await this.openWithSystem(ctx, uri);
      this.pdfHint = '';
    } catch (e) {
      // 真机上没有任何应用能处理 application/pdf 时会走到这里
      this.pdfHint = '没有可打开 PDF 的应用，可改用「保存到文件」';
      Logger.warn('open externally failed');
    }
  }

  /**
   * 把 PDF 保存到用户选定的位置（系统的「保存到文件」）。
   *
   * 与「用其它应用打开」并列保留：有些设备装了阅读器但不注册
   * application/pdf，此时保存出来自己找地方看是唯一可行的路径。
   * 用 DocumentViewPicker 而不是写固定目录 —— 沙箱目录用户看不到，
   * 写进去等于没保存。
   */
  private async downloadPdf(): Promise<void> {
    if (!await this.ensurePdfReady()) {
      return;
    }
    try {
      const ctx: common.UIAbilityContext | null = ContextHolder.get();
      if (ctx === null) {
        this.pdfHint = '无法获取应用上下文';
        return;
      }
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opts.newFileNames = ['培养方案.pdf'];
      const savePicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      const uris: string[] = await savePicker.save(opts);
      if (uris.length === 0) {
        return; // 用户取消
      }
      // 把沙箱里的 PDF 复制到用户选定的位置
      const src: fileIo.File = fileIo.openSync(this.pdfLocalPath, fileIo.OpenMode.READ_ONLY);
      const dst: fileIo.File = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE);
      try {
        const size: number = fileIo.statSync(this.pdfLocalPath).size;
        const buf: ArrayBuffer = new ArrayBuffer(size);
        fileIo.readSync(src.fd, buf);
        fileIo.writeSync(dst.fd, buf);
      } finally {
        fileIo.closeSync(src);
        fileIo.closeSync(dst);
      }
      this.pdfHint = '';
      promptAction.showToast({ message: '已保存', duration: 2000 });
    } catch (e) {
      const err: Error = e as Error;
      this.pdfHint = '保存失败：' + ((err !== undefined && err.message !== undefined)
        ? err.message : String(e));
    }
  }

  /** 用系统应用打开（传入文件共享 URI） */
  private async openWithSystem(ctx: common.UIAbilityContext, shareUri: string): Promise<void> {
    const want: Want = {
      // 注意：ACTION_VIEW_DATA 只在旧的 @ohos.ability.wantConstant 中定义，
      // 新的 wantConstant 里没有该常量，因此这里直接用 action 字符串。
      action: 'ohos.want.action.viewData',
      uri: shareUri,
      type: 'application/pdf',
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    };
    await ctx.startAbility(want);
  }

  private isCollapsed(system: string): boolean {
    for (let i = 0; i < this.collapsed.length; i++) {
      if (this.collapsed[i] === system) {
        return true;
      }
    }
    return false;
  }

  private toggle(system: string): void {
    const next: string[] = [];
    let found: boolean = false;
    for (let i = 0; i < this.collapsed.length; i++) {
      if (this.collapsed[i] === system) {
        found = true;
      } else {
        next.push(this.collapsed[i]);
      }
    }
    if (!found) {
      next.push(system);
    }
    this.collapsed = next;
  }

  // ==================== 视图 ====================

  /**
   * 培养方案 PDF 附件卡片：只负责「把文件弄到手，再交给其它应用」。
   *
   * 上一版这里嵌着 PdfViewer（逐页位图渲染 + 缩放 + 全屏），已整体删除：
   * 阅读 PDF 是系统阅读器的本职，自绘一套既依赖特定设备能力，又占内存，
   * 效果还不如对方。现在这张卡片只有两行：说明 + 两个动作。
   */
  @Builder
  pdfCard() {
    Column({ space: Theme.GAP_S }) {
      Row({ space: Theme.GAP_S }) {
        AppIcon({ res: 'description', iconSize: 20, color: $r('app.color.text_tertiary') })
        Column({ space: 2 }) {
          Text('培养方案 PDF')
            .fontSize(Theme.FS_BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.pdfStatusText())
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.pdfBusy) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color($r('app.color.brand'))
        }
      }
      .width('100%')

      if (this.plan.pdfPath.length > 0 && !this.pdfBusy) {
        Row({ space: Theme.GAP_S }) {
          // 主操作：交给系统里用户自己选的阅读器
          Text('用其它应用打开')
            .fontSize(Theme.FS_SMALL)
            .fontColor($r('app.color.on_brand'))
            .textAlign(TextAlign.Center)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .borderRadius(18)
            .backgroundColor($r('app.color.brand'))
            .onClick(() => {
              this.openExternally();
            })
          // 次操作：有些设备没有能打开 PDF 的应用，那就存出来自己找地方看
          Text('保存到文件')
            .fontSize(Theme.FS_SMALL)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Center)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .borderRadius(18)
            .backgroundColor($r('app.color.surface_variant'))
            .onClick(() => {
              this.downloadPdf();
            })
        }
        .width('100%')
      }

      if (this.pdfHint.length > 0) {
        Text(this.pdfHint)
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(Theme.GAP)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_SM)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  courseRow(c: PlanCourse) {
    Row({ space: Theme.GAP_S }) {
      Column({ space: 2 }) {
        Text(c.courseName)
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: 8 }) {
          Text(c.courseCode)
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
          if (c.semester.length > 0) {
            Text('第' + c.semester + '学期')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
          }
          if (c.category.length > 0) {
            Text(c.category)
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.surface_variant'))
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(4)
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(c.credit + ' 学分')
        .fontSize(Theme.FS_SMALL)
        .fontColor($r('app.color.brand'))
    }
    .width('100%')
    .padding({ left: Theme.GAP, right: Theme.GAP, top: 10, bottom: 10 })
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
  }

  @Builder
  groupCard(g: PlanGroup) {
    Column() {
      // 分组头：点击折叠
      Row({ space: Theme.GAP_S }) {
        Text(g.system)
          .fontSize(Theme.FS_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(g.courses.length.toString() + ' 门 · ' + g.totalCredit.toString() + ' 学分')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
        Blank()
        Text(this.isCollapsed(g.system) ? '展开' : '收起')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.brand'))
      }
      .width('100%')
      .padding(Theme.GAP)
      .onClick(() => {
        this.toggle(g.system);
      })

      if (!this.isCollapsed(g.system)) {
        ForEach(g.courses, (c: PlanCourse) => {
          this.courseRow(c)
        }, (c: PlanCourse, i: number) => g.system + '-' + c.courseCode + '-' + i.toString())
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_SM)
    .clip(true)
  }

  build() {
    // 下拉刷新：以 force 调用，**绕过 TTL 强制联网**（对齐 Flutter 端
    // 每页的 onRefresh: () => _load(force: true)）。没有它的话，
    // TTL 内（本页 6 小时）即使学校刚改了数据，下拉也只会重读缓存。
    Refresh({ refreshing: $$this.refreshing }) {
      Column() {
        if (this.loading) {
          LoadingView({ message: '正在获取培养方案…' })
        } else if (this.errorText.length > 0 && this.plan.courses.length === 0) {
          // 没有任何内容可显示时才整屏报错（首次进入且失败）；
          // 有缓存内容时错误降级为页面内横幅（见下方），
          // 免得把用户正看着的培养方案整个换掉。
          ErrorView({
            message: this.errorText,
            onRetry: () => {
              this.load(true);
            }
          })
        } else if (this.plan.courses.length === 0) {
          EmptyView({ title: '暂无培养方案数据' })
        } else {
          Scroll() {
            Column({ space: Theme.GAP }) {
              // 刷新失败的提示：只加一条横幅，不换掉页面。
              // 用户已经看到的培养方案比「这次刷新成功与否」重要得多。
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
              // PDF 放最前（用户要求），且**不再在它上方堆「培养目标」大段文字**——
              // 那些段落是培养方案的正文说明，与「看附件」这件事无关，
              // 却把 PDF 推到屏幕外，每次都要先滚过一大段文字才能看到。
              this.pdfCard()

              // 课程设置总表汇总
              Row({ space: Theme.GAP }) {
                Column({ space: 2 }) {
                  Text(this.plan.courses.length.toString())
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.text_primary'))
                  Text('门课程')
                    .fontSize(Theme.FS_TINY)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .layoutWeight(1)
                Column({ space: 2 }) {
                  Text(this.plan.totalCredit.toString())
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.brand'))
                  Text('总学分')
                    .fontSize(Theme.FS_TINY)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .layoutWeight(1)
                Column({ space: 2 }) {
                  Text(this.plan.totalHours.toString())
                    .fontSize(20)
                    .fontWeight(FontWeight.Bold)
                    .fontColor($r('app.color.text_primary'))
                  Text('总学时')
                    .fontSize(Theme.FS_TINY)
                    .fontColor($r('app.color.text_tertiary'))
                }
                .layoutWeight(1)
              }
              .width('100%')
              .padding(Theme.GAP)
              .backgroundColor($r('app.color.surface'))
              .borderRadius(Theme.RADIUS_SM)

              Text('课程设置总表')
                .fontSize(Theme.FS_SECTION)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .width('100%')

              ForEach(this.plan.groups, (g: PlanGroup) => {
                this.groupCard(g)
              }, (g: PlanGroup) => g.system + g.courses.length.toString())
            }
            .width('100%')
            // 底部多留出浮层 dock 的高度，否则最后一组课程会被玻璃压住
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
