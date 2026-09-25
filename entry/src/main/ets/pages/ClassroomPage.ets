/*
 * ClassroomPage：空教室查询
 *
 * 数据源：教务系统「全校性教室课表」(/jsxsd/kbcx/kbxx_classroom)。
 * 选择「校区 + 教学楼 + 节次 + 周次 + 星期」，列出该时段的空闲教室。
 *
 * ===== 一个重要实现决策（已实测）=====
 * 查询**不把周次交给服务端**。服务端的 zc1/zc2 有两个问题：
 *   1. 「被借用」类记录完全无视周次，第 2 周的借用在任何一周都会出现；
 *   2. 按周筛选后，该周没有任何占用记录的教室会被整行丢弃
 *      （实测章丘：不筛 231 间，筛第 4 周只剩 196 间）。
 * 第 2 点对「找空教室」是致命的——真正全周空闲的教室恰好就是被丢掉的那批。
 *
 * 因此改为：一次取回该教学楼该节次的**全学期**占用文本，
 * 再在客户端按周次逐格判断是否空闲（逻辑在 ClassroomModels，有单测覆盖）。
 *
 * ===== 交互设计 =====
 *   - **全部自动查询**：进页面即查一次；改动学期/校区/教学楼/节次/周次，
 *     以及点任意星期（含重复点同一天）都会立即重新请求，不再需要「查询」按钮。
 *   - 重新请求的目的不只是换条件，也是**刷新数据**：教室占用是实时变化的
 *     （借用记录随时被编辑），所以每动一下就重新取一次。
 *   - **周次的过滤仍在客户端做**（原因见上：服务端 zc1/zc2 不可靠），
 *     即「请求拿全量 → 客户端按周筛」，两者并不矛盾。
 *   - 星期行同时承担「本周空闲速览」：每天空闲几间直接标在当天下面，
 *     点哪天就切到哪天（早先这两者分成两行，看起来是重复的 UI，已合并）。
 *   - 并发请求用序号丢弃过期响应，避免慢的旧响应覆盖新结果。
 *   - 默认落在「当前教学周 + 今天」。
 */
import { AppState } from '../data/AppState';
import { GlassKit } from '../theme/GlassKit';
import { WeekService } from '../data/WeekService';
import { AppError } from '../common/Result';
import { ReAuthService } from '../data/ReAuthService';
import { PageCache, PageDataLoader, PageLoadResult } from '../data/PageCache';
import { QzApi } from '../network/QzApi';
import { ClassroomParser } from '../parser/ClassroomParser';
import { CACHE_CLASSROOM_OPTIONS, CACHE_CLASSROOM_BUILDINGS, CACHE_CLASSROOM_USAGE,
  TTL_CLASSROOM_OPTIONS, TTL_CLASSROOM_BUILDINGS, TTL_CLASSROOM_USAGE } from '../common/Constants';
import { Logger } from '../common/Logger';
import { Theme } from '../theme/Theme';
import { SECTIONS, SectionDef, MAX_WEEKS } from '../common/Constants';
import { ClassroomResult, ClassroomFinder, RoomSlot, RoomBooking, DayFreeStat } from '../model/ClassroomModels';
import { ClassroomOptions } from '../network/QzApi';
import { ChoiceItem } from '../model/Models';
import { EmptyView, ErrorView, LoadingView } from '../components/StateViews';

@Component
export struct ClassroomPage {
  @State loading: boolean = false;
  @State errorText: string = '';
  /**
   * 下拉刷新状态（`$$` 双向绑定给 Refresh）。
   * 刷新结束必须置回 false，否则指示器会一直转 —— 见 search 的 finally。
   */
  @State refreshing: boolean = false;
  /** 选项 */
  @State campuses: string[] = [];
  @State semesters: string[] = [];
  @State buildings: ChoiceItem[] = [];
  /** 当前选择 */
  @State campusIdx: number = 0;
  @State semesterIdx: number = 0;
  @State buildingIdx: number = 0;
  @State sectionRow: number = 0;
  @State week: number = 1;
  @State day: number = 0;
  /** 结果 */
  @State result: ClassroomResult = new ClassroomResult();
  @State loaded: boolean = false;
  /** 是否正在加载教学楼列表（切校区时） */
  @State loadingBuildings: boolean = false;
  /** 提示文本（如“已按官方校历定位到第 4 周”） */
  @State hint: string = '';
  /** 空闲列表/周统计的记忆化缓存（见 freeRooms / weekStats 的说明） */
  private freeCache: string[] | null = null;
  private freeCacheWeek: number = -1;
  private freeCacheDay: number = -1;
  private freeCacheResult: ClassroomResult | null = null;
  private statsCache: DayFreeStat[] | null = null;
  private statsCacheWeek: number = -1;
  private statsCacheResult: ClassroomResult | null = null;
  /** 查询序号，用于丢弃过期响应（见 search） */
  private searchSeq: number = 0;

  aboutToAppear(): void {
    this.initFromContext();
    this.loadOptions();
  }

  /** 用当前教学周与今天作为默认值 */
  private initFromContext(): void {
    const w: number = WeekService.cachedWeek();
    this.week = w > 0 ? w : 1;
    const dow: number = new Date().getDay();
    // JS: 0=周日；课表列 0=周一
    this.day = dow === 0 ? 6 : dow - 1;
  }

  /** 校区/学期选项的加载器（几乎不变的元数据，TTL 6 小时） */
  private optionsLoader(): PageDataLoader<ClassroomOptions> {
    return new PageDataLoader<ClassroomOptions>(
      PageCache.keyOf(AppState.account, CACHE_CLASSROOM_OPTIONS),
      () => AppState.apiInstance().getClassroomOptionsHtml(),
      (body: string) => QzApi.parseClassroomOptions(body),
      TTL_CLASSROOM_OPTIONS);
  }

  /** 某校区教学楼的加载器（key 带校区作变体） */
  private buildingsLoader(campusId: string): PageDataLoader<ChoiceItem[]> {
    return new PageDataLoader<ChoiceItem[]>(
      PageCache.keyOf(AppState.account, CACHE_CLASSROOM_BUILDINGS, [campusId]),
      () => AppState.apiInstance().getBuildingsHtml(campusId),
      (body: string) => QzApi.parseBuildings(body),
      TTL_CLASSROOM_BUILDINGS);
  }

  /**
   * 占用情况的加载器。
   *
   * key 带**全部查询条件**（含节次）：不同条件返回不同表格，混用会让用户
   * 看到别的条件的教室。星期与周次**不进 key** —— 服务端返回的本来就是
   * 整个学期的全周占用，那两项只是客户端读哪一列的选择。
   */
  private usageLoader(): PageDataLoader<ClassroomResult> {
    const sectionRow: number = this.sectionRow;
    return new PageDataLoader<ClassroomResult>(
      PageCache.keyOf(AppState.account, CACHE_CLASSROOM_USAGE,
        [this.semester(), this.campusId(), this.buildingId(), sectionRow.toString()]),
      () => AppState.apiInstance().getClassroomUsageHtml(
        this.semester(), this.campusId(), this.buildingId(), sectionRow),
      (body: string) => ClassroomParser.parseResult(body, sectionRow),
      TTL_CLASSROOM_USAGE);
  }

  /** 拉取校区与学期选项，并默认选中第一个校区 */
  private async loadOptions(interactive: boolean = false): Promise<void> {
    // 已有选项时不铺整屏加载态（切页回来直接命中缓存）
    this.errorText = '';
    if (this.campuses.length === 0) {
      this.loading = true;
    }
    try {
      const opt: ClassroomOptions = (await this.optionsLoader().load(false)).data;
      this.campuses = opt.campuses;
      this.semesters = opt.semesters;
      // 学期默认选中与当前课表学期一致的那个
      const tt = AppState.timetable;
      if (tt !== null && tt.semester.length > 0) {
        const idx: number = this.semesters.indexOf(tt.semester);
        if (idx >= 0) {
          this.semesterIdx = idx;
        }
      }
      // 校区默认选「章丘」——本校主校区，找不到则退回第一个
      const zhangqiu: number = this.campusIndexByName('章丘');
      this.campusIdx = zhangqiu >= 0 ? zhangqiu : 0;
      await this.reloadBuildings();
      // 选项就绪后自动做首次查询，用户进页面即可看到结果（无需点按钮）
      await this.search(interactive);
    } catch (e) {
      // 会话失效：先试静默续期，成功就重跑初始化；失败时自动加载只给内联提示
      const renewed: boolean = await ReAuthService.recoverIfExpired(e, interactive);
      if (renewed) {
        await this.loadOptions(interactive);
        return;
      }
      const msg: string = AppError.describe(e);
      this.errorText = AppError.isAuthExpired(e)
        ? '登录状态已过期，重新加载即可自动登录' : msg;
    } finally {
      this.loading = false;
    }
  }

  private campusIndexByName(keyword: string): number {
    for (let i = 0; i < this.campuses.length; i++) {
      if (this.campuses[i].indexOf(keyword) >= 0) {
        return i;
      }
    }
    return -1;
  }

  /** 校区 value 部分 */
  private campusId(): string {
    if (this.campusIdx < 0 || this.campusIdx >= this.campuses.length) {
      return '';
    }
    const raw: string = this.campuses[this.campusIdx];
    const at: number = raw.indexOf('|');
    return at > 0 ? raw.substring(0, at) : raw;
  }

  private campusLabel(): string {
    if (this.campusIdx < 0 || this.campusIdx >= this.campuses.length) {
      return '';
    }
    const raw: string = this.campuses[this.campusIdx];
    const at: number = raw.indexOf('|');
    return at > 0 ? raw.substring(at + 1) : raw;
  }

  private semester(): string {
    return (this.semesterIdx >= 0 && this.semesterIdx < this.semesters.length)
      ? this.semesters[this.semesterIdx] : '';
  }

  private buildingId(): string {
    return (this.buildingIdx >= 0 && this.buildingIdx < this.buildings.length)
      ? this.buildings[this.buildingIdx].value : '';
  }

  private buildingLabel(): string {
    return (this.buildingIdx >= 0 && this.buildingIdx < this.buildings.length)
      ? this.buildings[this.buildingIdx].label : '全部教学楼';
  }

  /** 切校区后重新拉教学楼 */
  private async reloadBuildings(): Promise<void> {
    this.loadingBuildings = true;
    try {
      const list: ChoiceItem[] =
          (await this.buildingsLoader(this.campusId()).load(false)).data;
      this.buildings = list;
      this.buildingIdx = 0;
    } catch (e) {
      // 教学楼列表是主加载的后继步骤：同样先试静默续期，不递归重拉
      // （续期成功后主加载路径会自动重跑一次，避免两边竞争）
      await ReAuthService.recoverIfExpired(e, false);
      const msg: string = AppError.describe(e);
      this.errorText = AppError.isAuthExpired(e)
        ? '登录状态已过期，重新加载即可自动登录' : msg;
      this.buildings = [];
    } finally {
      this.loadingBuildings = false;
    }
  }

  /**
   * 执行查询。
   *
   * 用递增的序号丢弃过期响应：自动查询会在用户连续改动筛选条件时
   * 并发发出多个请求，慢的那个可能后回来，若不丢弃就会把新结果覆盖成旧结果。
   */
  private async search(interactive: boolean = false,
    force: boolean = false): Promise<void> {
    if (this.semester().length === 0) {
      this.errorText = '请先选择学期';
      return;
    }
    this.searchSeq = this.searchSeq + 1;
    const seq: number = this.searchSeq;
    this.loading = true;
    this.errorText = '';
    try {
      const r: ClassroomResult = (await this.usageLoader().load(force)).data;
      if (seq !== this.searchSeq) {
        // 已被更晚的请求取代，结果作废
        return;
      }
      this.result = r;
      this.loaded = true;
      this.hint = '共 ' + r.rooms.length.toString() + ' 间教室，'
        + this.sectionLabel() + '，第 ' + this.week.toString() + ' 周';
      Logger.info('classroom search done: rooms=' + r.rooms.length);
    } catch (e) {
      if (seq !== this.searchSeq) {
        return;
      }
      // 查询多由用户点按钮/切下拉触发，因此这里多半是主动路径
      const renewed: boolean = await ReAuthService.recoverIfExpired(e, interactive);
      if (renewed) {
        await this.search(interactive);
        return;
      }
      const msg: string = AppError.describe(e);
      this.errorText = AppError.isAuthExpired(e)
        ? '登录状态已过期，重新加载即可自动登录' : msg;
      // **不清 loaded/result**：用户已经看到的教室列表比「这次查询成败」重要，
      // 清掉会让页面突然变空。保留旧结果 + 顶部一条提示。
      this.loaded = true;
    } finally {
      if (seq === this.searchSeq) {
        this.loading = false;
      }
      // 复位下拉指示器：`$$` 双向绑定，不置回会一直转
      this.refreshing = false;
    }
  }

  /**
   * 改**查询条件**（学期 / 校区 / 教学楼 / 节次）后重新查询。
   *
   * 这几个条件变了就是换数据：key 变了，缓存也会正常联网。
   * 数据的实时性由 TTL 保证（2 分钟，见 TTL_CLASSROOM_USAGE）——
   * 超过 2 分钟再改任何条件都会真的联网。
   */
  private onFilterChanged(): void {
    // 用户改筛选条件 → 主动查询，失败时可以直接弹重新验证
    this.search(true);
  }

  /**
   * 换星期 / 换周次：**不需要联网**。
   *
   * 服务端返回的本来就是整个学期的全周占用，换天周只是换客户端读哪一列
   * （星期与周次不进缓存 key，见 usageLoader 的说明）。
   * 早先这里也调 onFilterChanged，于是点一下星期就重发一次请求、
   * 拿回一模一样的文本再解析一遍 —— 而现在会直接命中缓存。
   */
  private onViewChanged(): void {
    // 只触发重绘：freeRooms / weekStats 的记忆化键含 day/week，会自行重算
    this.searchSeq = this.searchSeq + 1;
  }

  private sectionLabel(): string {
    return (this.sectionRow >= 0 && this.sectionRow < SECTIONS.length)
      ? SECTIONS[this.sectionRow].label : '';
  }

  /**
   * 当前选择下的空闲教室。
   *
   * 带记忆化：结果依赖 (week, day, result)，在 build 里会被调用 4 次
   * （数量文本、空态判断、分组、总计），每次都要遍历并按教室号排序 200+ 条，
   * 不缓存会做 4 遍同样的活。只在输入变化时重算。
   */
  private freeRooms(): string[] {
    if (this.freeCache !== null && this.freeCacheWeek === this.week
      && this.freeCacheDay === this.day && this.freeCacheResult === this.result) {
      return this.freeCache;
    }
    const v: string[] = ClassroomFinder.freeRooms(this.result, this.week, this.day, '');
    this.freeCache = v;
    this.freeCacheWeek = this.week;
    this.freeCacheDay = this.day;
    this.freeCacheResult = this.result;
    return v;
  }

  /** 一周空闲统计（用于速览条） */
  private weekStats(): DayFreeStat[] {
    if (this.statsCache !== null && this.statsCacheWeek === this.week
      && this.statsCacheResult === this.result) {
      return this.statsCache;
    }
    const v: DayFreeStat[] = ClassroomFinder.weekStats(this.result, this.week);
    this.statsCache = v;
    this.statsCacheWeek = this.week;
    this.statsCacheResult = this.result;
    return v;
  }

  /** 某天第一间空闲教室的占用详情（供排查/展示） */
  private busyCount(): number {
    return ClassroomFinder.busyRooms(this.result, this.week, this.day).length;
  }

  private isToday(day: number): boolean {
    const dow: number = new Date().getDay();
    const todayCol: number = dow === 0 ? 6 : dow - 1;
    return day === todayCol && this.isCurrentWeek();
  }

  private isCurrentWeek(): boolean {
    return WeekService.cachedWeek() === this.week;
  }

  // ==================== 视图 ====================

  /**
   * 下拉行一律**内联**在 filterBar 里，不抽成带参数的 @Builder。
   *
   * 原因：ArkUI 里 @Builder 的参数按值传递，只在首次构建时求值。
   * 学期/校区这两个下拉的选项是异步加载的，首帧还是空数组，
   * 若把 value/options 当参数传给 Builder，之后就会永远显示空白
   * （选中项不回显）。直接写在 build 里读 this.* 才能随 @State 更新。
   */

  /**
   * 筛选栏：四个条件排成 2×2，教学楼单独占一行。
   *
   * ===== 为什么改成这个布局 =====
   * 早先是「标签 + 选择器」一行一个，五个条件占五行 —— 而这一页的主角是
   * **下面那份空教室列表**。筛选栏越高，能同时看到的教室就越少。
   * 现在：
   *   ┌──────────┬──────────┐
   *   │ 学期      │ 节次      │
   *   ├──────────┼──────────┤
   *   │ 校区      │ 周次      │
   *   ├──────────┴──────────┤
   *   │ 教学楼（单独一行）      │
   *   └─────────────────────┘
   * 五行压到三行，省下的高度全给列表。
   *
   * 标签从「左侧一列」改成「控件上方的小字」：半宽格里再切出 46vp 给标签，
   * 选择器只剩一百来 vp，学期名那样长的选项会被截断成「2026-2027 学…」。
   * 标签上移后选择器拿到整个格宽。
   *
   * ===== 为什么每个都内联、不抽 @Builder =====
   * ArkUI 里 @Builder 的参数按值传递，只在首次构建时求值。学期/校区这两个
   * 的选项是异步加载的，首帧还是空数组 —— 若把 value/options 当参数传给
   * Builder，之后就会永远显示空白（选中项不回显）。直接写在 build 里读
   * this.* 才能随 @State 更新。
   */
  @Builder
  filterBar() {
    Column({ space: Theme.GAP_S }) {
      // ---- 第一行：左上学期，右上节次 ----
      Row({ space: Theme.GAP_S }) {
        Column({ space: 4 }) {
          Text('学期')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Select(this.semesters.map((v: string) => {
            const opt: SelectOption = { value: v };
            return opt;
          }))
            .selected(this.semesterIdx)
            .value(this.semester())
            .font({ size: Theme.FS_SMALL })
            .width('100%')
            .backgroundColor($r('app.color.surface_variant'))
            .backgroundEffect(GlassKit.fieldEffect())
            .borderRadius(Theme.RADIUS_SM)
            .onSelect((index: number) => {
              this.semesterIdx = index;
              this.onFilterChanged();
            })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 4 }) {
          Text('节次')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Select(this.sectionLabels().map((v: string) => {
            const opt: SelectOption = { value: v };
            return opt;
          }))
            .selected(this.sectionRow)
            .value(this.sectionLabel())
            .font({ size: Theme.FS_SMALL })
            .width('100%')
            .backgroundColor($r('app.color.surface_variant'))
            .backgroundEffect(GlassKit.fieldEffect())
            .borderRadius(Theme.RADIUS_SM)
            .onSelect((index: number) => {
              this.sectionRow = index;
              this.onFilterChanged();
            })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // ---- 第二行：左下校区，右下周次 ----
      Row({ space: Theme.GAP_S }) {
        Column({ space: 4 }) {
          Text('校区')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Select(this.campusLabels().map((v: string) => {
            const opt: SelectOption = { value: v };
            return opt;
          }))
            .selected(this.campusIdx)
            .value(this.campusLabel())
            .font({ size: Theme.FS_SMALL })
            .width('100%')
            .backgroundColor($r('app.color.surface_variant'))
            .backgroundEffect(GlassKit.fieldEffect())
            .borderRadius(Theme.RADIUS_SM)
            .onSelect((index: number) => {
              this.campusIdx = index;
              // 教学楼列表随校区变化，需先重新拉取再查询
              this.reloadBuildings().then(() => {
                this.onFilterChanged();
              });
            })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 4 }) {
          Text('周次')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
          Select(this.weekLabels().map((v: string) => {
            const opt: SelectOption = { value: v };
            return opt;
          }))
            .selected(this.week - 1)
            .value('第 ' + this.week.toString() + ' 周' + (this.isCurrentWeek() ? '（本周）' : ''))
            .font({ size: Theme.FS_SMALL })
            .width('100%')
            .backgroundColor($r('app.color.surface_variant'))
            .backgroundEffect(GlassKit.fieldEffect())
            .borderRadius(Theme.RADIUS_SM)
            .onSelect((index: number) => {
              this.week = index + 1;
              this.onViewChanged();
            })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // ---- 第三行：教学楼单独占一行 ----
      //
      // 它是唯一「切校区时还要重新拉列表」的条件，也是唯一选项文案可能很长
      // （「圣井校区 · 图书馆」之类）的，独占一行才不会截断。
      Column({ space: 4 }) {
        Text('教学楼')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        if (this.loadingBuildings) {
          Row() {
            Text('正在加载…')
              .fontSize(Theme.FS_SMALL)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .height(36)
          .padding({ left: 12, right: 12 })
          .alignItems(VerticalAlign.Center)
          .backgroundColor($r('app.color.surface_variant'))
          .backgroundEffect(GlassKit.fieldEffect())
          .borderRadius(Theme.RADIUS_SM)
        } else {
          Select(this.buildingLabels().map((v: string) => {
            const opt: SelectOption = { value: v };
            return opt;
          }))
            .selected(this.buildingIdx)
            .value(this.buildingLabel())
            .font({ size: Theme.FS_SMALL })
            .width('100%')
            .backgroundColor($r('app.color.surface_variant'))
            .backgroundEffect(GlassKit.fieldEffect())
            .borderRadius(Theme.RADIUS_SM)
            .onSelect((index: number) => {
              this.buildingIdx = index;
              this.onFilterChanged();
            })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      /**
       * 星期选择（同时也是「本周空闲速览」）。
       *
       * 这里**只保留一行**：早先另有一张「本周空闲速览」卡片也画了同样的周一到周日，
       * 两行内容重复、看起来像 bug。现在把「选星期」和「每天空闲几间」合并到同一行，
       * 点哪天就切到哪天，各天的空闲数直接标在当天下面。
       */
      Row({ space: Theme.GAP_S }) {
        ForEach(this.weekStats(), (st: DayFreeStat) => {
          Column({ space: 1 }) {
            Text(ClassroomFinder.dayLabel(st.day))
              .fontSize(Theme.FS_SMALL)
              .fontWeight(this.day === st.day || this.isToday(st.day)
                ? FontWeight.Medium : FontWeight.Normal)
              // 只有「选中」用品牌色文字；「今天」改用描边标记（见下方 border）。
              // 早先今天也用品牌色文字，导致切到别的星期后仍有两处蓝色，
              // 看起来像「周三还是被选中」。
              .fontColor(this.day === st.day
                ? $r('app.color.on_brand') : $r('app.color.text_primary'))
            // 空闲数在首次查询完成前不显示，避免先闪一排 0
            if (this.loaded) {
              Text(st.free.toString())
                .fontSize(Theme.FS_TINY)
                .fontColor(this.day === st.day
                  ? $r('app.color.on_brand') : $r('app.color.text_secondary'))
            } else if (this.isToday(st.day)) {
              Text('今天')
                .fontSize(9)
                .fontColor(this.day === st.day
                  ? $r('app.color.on_brand') : $r('app.color.text_tertiary'))
            }
          }
          .layoutWeight(1)
          .height(52)
          .justifyContent(FlexAlign.Center)
          .borderRadius(Theme.RADIUS_SM)
          .backgroundColor(this.day === st.day
            ? $r('app.color.brand') : $r('app.color.surface_variant'))
          // 今天：未选中时用一圈描边表示，与「选中」的实心蓝区分开
          .border({
            width: (this.isToday(st.day) && this.day !== st.day) ? 1 : 0,
            color: $r('app.color.brand')
          })
          .onClick(() => {
            // 星期切换也重新请求：教室占用是实时变化的（借用记录随时被编辑），
            // 重查一次能拿到最新数据；即使点的是同一天也照发请求。
            this.day = st.day;
            this.onViewChanged();
          })
        }, (st: DayFreeStat) => 'cd' + st.day.toString() + '-' + st.free.toString())
      }
      .width('100%')
    }
    .width('100%')
    .padding(Theme.GAP)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_SM)
  }

  private campusLabels(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.campuses.length; i++) {
      const raw: string = this.campuses[i];
      const at: number = raw.indexOf('|');
      out.push(at > 0 ? raw.substring(at + 1) : raw);
    }
    return out;
  }

  private buildingLabels(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.buildings.length; i++) {
      out.push(this.buildings[i].label);
    }
    return out;
  }

  private sectionLabels(): string[] {
    const out: string[] = [];
    for (let i = 0; i < SECTIONS.length; i++) {
      const s: SectionDef = SECTIONS[i];
      out.push(s.label + '  ' + s.start);
    }
    return out;
  }

  private weekLabels(): string[] {
    const out: string[] = [];
    for (let i = 1; i <= MAX_WEEKS; i++) {
      out.push('第 ' + i.toString() + ' 周');
    }
    return out;
  }

  /**
   * 一周速览已合并进 filterBar 的星期行（见那里的说明），
   * 这里不再单独渲染一张卡片，避免出现两行一模一样的「周一到周日」。
   */

  /** 空教室列表 */
  @Builder
  freeList() {
    Column({ space: Theme.GAP_S }) {
      Row() {
        Text(ClassroomFinder.dayLabel(this.day) + ' 空闲教室')
          .fontSize(Theme.FS_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(this.freeRooms().length.toString() + ' 间')
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.brand'))
      }
      .width('100%')

      if (this.freeRooms().length === 0) {
        Text('该时段没有空闲教室')
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 20, bottom: 20 })
      } else {
        // 按教学楼分组展示，便于按楼找教室
        ForEach(this.groupedFree(), (grp: RoomGroup) => {
          Column({ space: 4 }) {
            Text(grp.building + '（' + grp.rooms.length.toString() + '）')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(grp.rooms, (room: string) => {
                Text(this.shortName(room))
                  .fontSize(Theme.FS_SMALL)
                  .fontColor($r('app.color.text_primary'))
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .margin({ right: 6, bottom: 6 })
                  .backgroundColor($r('app.color.surface_variant'))
                  .borderRadius(Theme.RADIUS_SM)
              }, (room: string) => room)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }, (grp: RoomGroup) => 'g' + grp.building)
      }

      if (this.busyCount() > 0) {
        Text('该时段有 ' + this.busyCount().toString() + ' 间教室在上课或已被借用')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(Theme.GAP)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(Theme.RADIUS_SM)
    .alignItems(HorizontalAlign.Start)
  }

  /** 去掉教室名里的校区后缀，列表更紧凑 */
  private shortName(room: string): string {
    const at: number = room.indexOf('(');
    return at > 0 ? room.substring(0, at) : room;
  }

  /** 按教学楼分组 */
  private groupedFree(): RoomGroup[] {
    const rooms: string[] = this.freeRooms();
    const groups: RoomGroup[] = [];
    for (let i = 0; i < rooms.length; i++) {
      const head: string = rooms[i].indexOf('-') > 0
        ? rooms[i].substring(0, rooms[i].indexOf('-')) : rooms[i];
      let found: RoomGroup | null = null;
      for (let j = 0; j < groups.length; j++) {
        if (groups[j].building === head) {
          found = groups[j];
          break;
        }
      }
      if (found === null) {
        const g: RoomGroup = new RoomGroup(head);
        g.rooms.push(rooms[i]);
        groups.push(g);
      } else {
        found.rooms.push(rooms[i]);
      }
    }
    return groups;
  }

  build() {
    Column({ space: Theme.GAP }) {
      // 筛选栏固定在外：它是操作控件，让它跟着下拉一起位移会显得整页在动
      // （Flutter 端也是筛选栏固定、只有列表区可下拉）。
      this.filterBar()

      if (this.loading) {
        LoadingView({ message: '正在查询教室占用…' })
      } else if (this.errorText.length > 0 && !this.loaded) {
        // 没有任何结果可显示时才整屏报错；有结果时错误降级为列表上方横幅
        ErrorView({
          message: this.errorText,
          onRetry: () => {
            this.loadOptions(true);
          }
        })
      } else if (!this.loaded) {
        EmptyView({
          title: '正在准备教室数据…',
          hint: '进入页面会自动查询；调整校区、教学楼或节次后也会自动刷新'
        })
      } else if (this.result.rooms.length === 0) {
        EmptyView({
          title: '没有查到教室',
          hint: '该条件下没有教室数据，可换教学楼或节次再试'
        })
      } else {
        // 下拉刷新：force 重查，**绕过 2 分钟 TTL 强制联网**
        // （对齐 Flutter 端本页的 onRefresh: () => _search(force: true)）。
        //
        // Refresh 的子树**只放一个容器组件**（这里是 Scroll）：
        // ArkUI 对 Refresh 的子节点有这一条要求，塞进 if/else 链或多层容器
        // 会让属性链解析错位（实测报 「Property 'onRefreshing' does not exist
        // on type 'ColumnAttribute'」——编译器把 onRefreshing 挂到了内层 Column）。
        Refresh({ refreshing: $$this.refreshing }) {
          Scroll() {
            Column({ space: Theme.GAP }) {
              if (this.hint.length > 0) {
                Text(this.hint)
                  .fontSize(Theme.FS_TINY)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
              }
              this.freeList()
            }
            .width('100%')
            // 底部多留出浮层 dock 的高度，否则最后一间教室会被玻璃压住
            .padding({ bottom: Theme.bottomInset() })
          }
          .layoutWeight(1)
          .align(Alignment.Top)
        }
        .onRefreshing(() => {
          this.search(false, true);
        })
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .padding(Theme.GAP)
    .backgroundColor($r('app.color.bg'))
  }
}

/** 按教学楼分组的空闲教室 */
class RoomGroup {
  building: string = '';
  rooms: string[] = [];

  constructor(building: string) {
    this.building = building;
  }
}
