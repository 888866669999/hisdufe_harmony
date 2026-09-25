/*
 * 成绩页：按学期筛选，展示课程成绩与绩点，并给出客户端计算的学分/加权绩点汇总
 */
import { AppState } from '../data/AppState';
import { PrefStore } from '../data/PrefStore';
import { ScoreRecord, ScoreSummary, ChoiceItem } from '../model/Models';
import { ScoreParser } from '../parser/ScoreParser';
import { AppError } from '../common/Result';
import { ReAuthService } from '../data/ReAuthService';
import { PageCache, PageDataLoader, PageLoadResult } from '../data/PageCache';
import { Logger } from '../common/Logger';
import { Theme } from '../theme/Theme';
import { GlassKit } from '../theme/GlassKit';
import { KEY_LAST_SCORE_SEMESTER, CACHE_SCORE_LIST, CACHE_SCORE_SEMESTERS,
  TTL_SCORE_LIST, TTL_SCORE_SEMESTERS } from '../common/Constants';
import { LoadingView, EmptyView, ErrorView } from '../components/StateViews';
import { SemesterPickerContent, SemesterOption, semesterPanelWidth, semesterPanelHeight } from '../components/SemesterPickerDialog';
import { AppIcon } from '../components/AppIcon';
import { GlassOverlay } from '../components/GlassOverlay';

@Component
export struct ScorePage {
  @State loading: boolean = true;
  @State errorText: string = '';
  @State records: ScoreRecord[] = [];
  @State summary: ScoreSummary = new ScoreSummary();
  @State semesters: ChoiceItem[] = [];
  @State semester: string = '';
  /** 只显示及格/不及格筛选用的开关不做，这里提供关键词搜索 */
  @State keyword: string = '';
  /** 学期选择浮层是否打开（关闭就是把它置回 false，不依赖框架注入） */
  @State semesterPickerOpen: boolean = false;
  /**
   * 下拉刷新状态。用 `$$` 双向绑定给 Refresh 组件。
   *
   * 必须由页面持有并**在刷新结束时置回 false**：否则下拉指示器会一直转。
   */
  @State refreshing: boolean = false;

  aboutToAppear(): void {
    this.restoreAndLoad();
  }

  /** 恢复上次选择的学期，再加载（下拉选择需要持久化） */
  private async restoreAndLoad(): Promise<void> {
    const saved: string = await PrefStore.getText(KEY_LAST_SCORE_SEMESTER);
    // 先用内存缓存填首帧：成绩列表按学期缓存，切页回来直接命中
    const cached: ScoreRecord[] | null = this.listLoader(saved).peek();
    if (cached !== null && cached.length > 0) {
      this.records = cached;
      this.summary = ScoreParser.summarize(cached);
      this.loading = false;
    }
    const cachedSems: ChoiceItem[] | null = this.semesterLoader().peek();
    if (cachedSems !== null && cachedSems.length > 0) {
      this.semesters = cachedSems;
    }
    await this.load(saved);
  }

  /** 成绩列表的加载器。key 带**学期**作变体：各学期独立缓存，切回看过的学期直接出结果 */
  private listLoader(semester: string): PageDataLoader<ScoreRecord[]> {
    return new PageDataLoader<ScoreRecord[]>(
      PageCache.keyOf(AppState.account, CACHE_SCORE_LIST, [semester]),
      () => AppState.apiInstance().getScoresHtml(semester),
      (body: string) => ScoreParser.parse(body),
      TTL_SCORE_LIST);
  }

  /** 学期下拉的加载器（不带变体：它本身就是「所有学期」） */
  private semesterLoader(): PageDataLoader<ChoiceItem[]> {
    return new PageDataLoader<ChoiceItem[]>(
      PageCache.keyOf(AppState.account, CACHE_SCORE_SEMESTERS),
      () => AppState.apiInstance().getScoreSemestersHtml(),
      (body: string) => ScoreParser.readSemesters(body),
      TTL_SCORE_SEMESTERS);
  }

  private async load(semester: string, interactive: boolean = false,
    force: boolean = false): Promise<void> {
    // 已有内容时不铺整屏加载态：切页回来该立刻看到旧成绩
    this.errorText = '';
    if (this.records.length === 0) {
      this.loading = true;
    }
    try {
      // 学期下拉失败不致命：成绩列表才是这一页的主体，
      // 拿不到学期列表顶多是筛选器少几个选项、切不了学期。
      try {
        const sm: PageLoadResult<ChoiceItem[]> = await this.semesterLoader().load(force);
        this.semesters = sm.data;
      } catch (e) {
        Logger.warn('score semesters failed: ' + e);
      }
      const r: PageLoadResult<ScoreRecord[]> = await this.listLoader(semester).load(force);
      const recs: ScoreRecord[] = r.data;
      // 本地已有数据时，网络返回空结果**不覆盖**：
      // 这多半是服务端那次查询异常（而不是「成绩被删了」），
      // 清空会让用户以为数据丢了。
      if (recs.length > 0 || this.records.length === 0) {
        AppState.scores = recs;
        this.records = recs;
        this.summary = ScoreParser.summarize(recs);
      }
      this.semester = semester;
      // 记住本次选择，下次进入沿用
      await PrefStore.putText(KEY_LAST_SCORE_SEMESTER, semester);
    } catch (e) {
      // 会话失效：先试静默续期，成功就重载（用户完全无感）；
      // 失败时自动加载只给内联提示，用户主动重试/切学期才弹窗。
      const renewed: boolean = await ReAuthService.recoverIfExpired(e, interactive);
      if (renewed) {
        await this.load(semester, interactive);
        return;
      }
      const msg: string = AppError.describe(e);
      this.errorText = AppError.isAuthExpired(e)
        ? '登录状态已过期，重新加载即可自动登录' : msg;
    } finally {
      this.loading = false;
      // 复位下拉指示器：**必须**。Refresh 组件的 refreshing 由 `$$` 双向绑定，
      // 页面不置回 false 的话指示器会一直转下去。
      this.refreshing = false;
    }
  }

  private filtered(): ScoreRecord[] {
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      return this.records;
    }
    const out: ScoreRecord[] = [];
    for (let i = 0; i < this.records.length; i++) {
      const r: ScoreRecord = this.records[i];
      if (r.courseName.indexOf(kw) >= 0 || r.courseCode.indexOf(kw) >= 0) {
        out.push(r);
      }
    }
    return out;
  }

  /** 成绩颜色：不及格红色 */
  private scoreColor(score: string): Resource {
    const n: number = parseFloat(score);
    if (!isNaN(n) && n < 60) {
      return $r('app.color.danger');
    }
    return $r('app.color.text_primary');
  }

  @Builder
  summaryBar() {
    Row({ space: Theme.GAP }) {
      Column({ space: 2 }) {
        Text(this.summary.count.toString())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('门课程')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(1)

      Column({ space: 2 }) {
        Text(this.summary.totalCredit.toString())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text('总学分')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(1)

      Column({ space: 2 }) {
        Text(this.summary.weightedGpa.toString())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.brand'))
        Text('加权绩点')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(1)
    }
    .width('100%')
    .padding(Theme.GAP)
    // 与页面底色统一（原来是白色，与页背景拼出两种色块）——
    // 与 Flutter 端 `_summaryBar` 的 `schedBgColor` 同一处理。
    .backgroundColor($r('app.color.sched_bg'))
  }

  /**
   * 学期选择的可选项：**「全部学期」固定放第一位**。
   *
   * 为什么不能只列服务器返回的学期：那一项在页面里的 value 是空串，
   * 而解析器会过滤掉空值 option（占位项），于是「不筛选、看全部成绩」
   * 这个入口在界面上根本不存在 —— 用户想查总账时找不到地方。
   * 这里显式补回来，value 用空串与后端语义一致。
   */
  /**
   * 列表末尾垫片的高度（vp）：让最后一条成绩能被拉到 dock 上方。
   *
   * 高度构成（缺一不可）：
   *   · `bottomInset` —— dock 胶囊本体 + 它的下边距，由 Index 按断点发布
   *     （窄屏有值，宽屏是左侧导航故为 0）；
   *   · `GAP` —— 再抬一个间距，否则最后一条会紧贴 dock 上沿；
   *   · 底部安全区 —— 系统手势条本身还会再压掉一截。
   *
   * 宽屏（无 dock）时只有安全区与间距，垫片自然变小。
   */
  private tailSpace(): number {
    return Theme.bottomInset() + Theme.GAP + 24;
  }

  private semesterOptions(): SemesterOption[] {
    const out: SemesterOption[] = [new SemesterOption('全部学期', '')];
    for (let i = 0; i < this.semesters.length; i++) {
      const s: ChoiceItem = this.semesters[i];
      out.push(new SemesterOption(s.label.length > 0 ? s.label : s.value, s.value));
    }
    return out;
  }

  /** 当前学期的显示文案（用于筛选栏上的按钮） */
  private semesterLabel(): string {
    if (this.semester.length === 0) {
      return '全部学期';
    }
    for (let i = 0; i < this.semesters.length; i++) {
      if (this.semesters[i].value === this.semester) {
        return this.semesters[i].label;
      }
    }
    return this.semester;
  }

  /**
   * 打开学期滚轮。
   *
   * ===== 为什么换掉 ArkUI 的 Select =====
   * 真机实测（MatePad 11.5 S）上 Select 展开的列表**被窗口底边截断且不能滚动**：
   * 教务返回 46 个学期，只画到第 9 项，更早的学期既看不到也点不到
   * —— 用户报的「没有全部学期」就是这个，不是数据缺失而是够不着。
   * 换成本应用统一的居中玻璃滚轮（与周次选择、Flutter 端一致）后，
   * 任意多项都能滚到，观感也与其余页面成套。
   */
  private openSemesterPicker(): void {
    this.semesterPickerOpen = true;
  }

  @Builder
  filterRow() {
    Row({ space: Theme.GAP_S }) {
      // 学期选择：点开居中玻璃滚轮。
      // 数据未到位时也**保持可点**（进滚轮只是显示「全部学期」一项），
      // 避免加载失败时整条筛选栏失效、用户没有切回来的入口。
      Row({ space: 4 }) {
        Text(this.semesterLabel())
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        AppIcon({ res: 'unfold_more', iconSize: 16, color: $r('app.color.text_tertiary') })
      }
      .layoutWeight(1)
      .height(36)
      .padding({ left: 10, right: 10 })
      .borderRadius(18)
      .backgroundColor($r('app.color.surface_variant'))
      .onClick(() => {
        this.openSemesterPicker();
      })

      TextInput({ placeholder: '搜索课程名/编号', text: this.keyword })
        .fontSize(Theme.FS_SMALL)
        .layoutWeight(1)
        .height(36)
        .borderRadius(18)
        .backgroundColor($r('app.color.surface_variant'))
        .backgroundEffect(GlassKit.fieldEffect())
        .onChange((v: string) => {
          this.keyword = v;
        })
    }
    .width('100%')
    .padding({ left: Theme.GAP, right: Theme.GAP, bottom: Theme.GAP })
    // 同上：筛选栏也用页面底色，整页只有一个基调。
    .backgroundColor($r('app.color.sched_bg'))
  }

  @Builder
  scoreRow(rec: ScoreRecord) {
    Row() {
      Column({ space: 4 }) {
        Text(rec.courseName)
          .fontSize(Theme.FS_BODY)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: Theme.GAP_S }) {
          Text(rec.semester)
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
          if (rec.courseNature.length > 0) {
            Text(rec.courseNature)
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor($r('app.color.surface_variant'))
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(4)
          }
          if (rec.credit.length > 0) {
            Text(rec.credit + ' 学分')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
          }
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 2 }) {
        Text(rec.score)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.scoreColor(rec.score))
        if (rec.gpa.length > 0) {
          Text(rec.gpa + ' 绩点')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding(Theme.GAP)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_SM)
  }

  build() {
    Stack() {
      Column() {
      // 筛选栏必须始终可用：否则当某个学期没有成绩时，
      // 用户会失去切换回其它学期的入口，整页看起来就是空白。
      if (!this.loading && this.errorText.length === 0) {
        if (this.records.length > 0) {
          this.summaryBar()
        }
        this.filterRow()
      }

      if (this.loading) {
        LoadingView({ message: '正在获取成绩…' })
      } else if (this.errorText.length > 0 && this.records.length === 0) {
        // 没有任何内容可显示时才整屏报错（首次进入且失败）；
        // 有缓存成绩时错误降级为列表上方横幅（见下方），
        // 免得把用户正看着的成绩单整个换掉。
        ErrorView({
          message: this.errorText,
          onRetry: () => {
            this.load(this.semester, true);
          }
        })
      } else if (this.records.length === 0) {
        EmptyView({ title: '暂无成绩数据', hint: '可切换学期查看' })
      } else if (this.filtered().length === 0) {
        EmptyView({ title: '没有匹配的课程' })
      } else {
        // 下拉刷新：以 force 调用，**绕过 TTL 强制联网**（对齐 Flutter 端
        // 每页的 onRefresh: () => _load(force: true)）。
        // 没有它的话，成绩 TTL 是 2 分钟 —— 学校刚出分时下拉也只会重读缓存，
        // 用户会以为「刷新了但分数没变」。
        Refresh({ refreshing: $$this.refreshing }) {
          Column() {
            // 刷新失败的提示：只加一条横幅，不换掉成绩单。
            // 用户已经看到的成绩比「这次刷新成功与否」重要得多。
            if (this.errorText.length > 0) {
              Text(this.errorText)
                .fontSize(Theme.FS_TINY)
                .fontColor($r('app.color.warning'))
                .width('100%')
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .borderRadius(Theme.RADIUS_SM)
                .backgroundColor($r('app.color.warning'))
                .opacity(0.92)
                .margin({ left: Theme.GAP, right: Theme.GAP, bottom: Theme.GAP_S })
            }
            List({ space: Theme.GAP_S }) {
              ForEach(this.filtered(), (rec: ScoreRecord) => {
                ListItem() {
                  this.scoreRow(rec)
                }
              }, (rec: ScoreRecord) => rec.semester + '-' + rec.courseCode + '-' + rec.courseName)
              // ===== 末尾垫片：让最后一条成绩能被拉上来 =====
              //
              // 注意它必须是**列表内的一个条目**，不能写成 List 的 bottom padding。
              // 两者看着像一回事，实际差在视口上：
              //   · `.padding({ bottom })` 缩短的是**视口** → 内容永远到不了
              //     dock 那一带，滚动时玻璃背后是空的 —— 观感上就是一块板子
              //     （这正是用户先前反馈过的问题）；
              //   · 末尾放一个空条目 → 视口仍是整屏，滚动时成绩卡照常从玻璃
              //     下面穿过（透明观感保住），只有**拉到最底**时最后一条才会
              //     被这个垫片顶到 dock 上方，完整可读。
              // 高度 = dock 让位 + 一个间距，避免最后一条紧贴 dock 上沿。
              ListItem() {
                Column()
                  .width('100%')
                  .height(this.tailSpace())
              }
            }
            .layoutWeight(1)
            .width('100%')
            // 左右留边即可；**底部不留**（原因见上面末尾垫片）
            .padding({ left: Theme.GAP, right: Theme.GAP })
          }
          .layoutWeight(1)
          .width('100%')
        }
        .onRefreshing(() => {
          this.load(this.semester, false, true);
        })
        .layoutWeight(1)
        .width('100%')
      }
      }
      .width('100%')
      .height('100%')
      // 刻意**不铺底色**：底色由外壳（Index 根容器）统一提供。
      // 这里再铺一层同色只会：
      //   1. 让成绩列表下方的空白区变成一块实心色 —— 在浮窗/分屏下
      //      会挡住背后的内容（用户反馈「成绩页底部要透明」）；
      //   2. 与课表页（没有自己的底色）观感不一致。
      // 卡片、统计栏、筛选栏各自有自己的底色，去掉这层不影响它们的可读性。

      // 学期选择浮层。宽度/高度用精确 vp：按比例算在平板上会拉得很宽。
      if (this.semesterPickerOpen) {
        GlassOverlay({
          panelWidthVp: semesterPanelWidth(),
          panelHeightVp: semesterPanelHeight(),
          onDismiss: () => {
            this.semesterPickerOpen = false;
          }
        }) {
          SemesterPickerContent({
            options: this.semesterOptions(),
            current: this.semester,
            onPicked: (v: string) => {
              this.semesterPickerOpen = false;
              if (v !== this.semester) {
                // 切学期是用户主动操作：失败时可以直接弹重新验证
                this.load(v, true);
              }
            },
            onCancel: () => {
              this.semesterPickerOpen = false;
            }
          })
        }
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
