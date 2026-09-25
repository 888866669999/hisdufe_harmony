/*
 * 应用根页面：响应式外壳
 *
 * - 未登录：登录页
 * - 已登录：
 *     sm（手机，<600vp）：底部标签栏 + 单页内容
 *     md/lg（平板、折叠屏展开，>=600vp）：左侧导航 + 右侧内容的主从分栏
 *   断点变化（折叠屏展开/折叠）时实时切换布局。
 */
import { window, KeyboardAvoidMode } from '@kit.ArkUI';
import { AppState } from '../data/AppState';
import { WeekService } from '../data/WeekService';
import { ContextHolder } from '../common/ContextHolder';
import { WindowService, Bp } from '../common/WindowService';
import { Theme } from '../theme/Theme';
import { GlassKit } from '../theme/GlassKit';
import { LoginPage } from './LoginPage';
import { SchedulePage } from './SchedulePage';
import { ScorePage } from './ScorePage';
import { PlanPage } from './PlanPage';
import { ElectivePage } from './ElectivePage';
import { ClassroomPage } from './ClassroomPage';
import { ProfilePage } from './ProfilePage';
import { SettingsPage } from './SettingsPage';
import { ReAuthDialog } from '../components/ReAuthDialog';
import { GlassOverlay } from '../components/GlassOverlay';
import { ReAuthService } from '../data/ReAuthService';
import { ProfileService } from '../data/ProfileService';
import { AppIcon } from '../components/AppIcon';
import { Logger } from '../common/Logger';
import { AS_LOGGED_IN, AS_STUDENT_NAME, AS_STUDENT_ID } from '../data/AppState';
import { AS_REAUTH_PENDING, AS_WINDOW_WIDTH, AS_WINDOW_HEIGHT, AS_BOTTOM_INSET } from '../common/Constants';
import { StudentProfile } from '../model/Models';
import { AppleUI } from 'com.hm.appleui.hw';

/**
 * 底部 dock 的高度（vp）。
 *
 * 三处必须用同一个值，否则会出现「玻璃和图标不一样高」「最后一行被遮住」：
 *   1. AppleUI 的玻璃透镜高度
 *   2. 图标/文字所在交互层的高度
 *   3. 内容区底部让位的 padding
 */
const DOCK_HEIGHT: number = 56;

/**
 * 宽屏侧边栏宽度（vp）。
 *
 * 必须是常量而不是 '100%'：AppleUI 的 Width/Height 是 number，
 * 且要据此计算画布与截帧区域。取值与布局宽度一致，玻璃才刚好贴合侧栏。
 */
const SIDEBAR_W: number = 200;

/** 侧栏玻璃四周必须留出的最小空隙（vp）。与 DOCK_PAD 同因，见其说明。 */
const SIDEBAR_PAD: number = 30;

/**
 * dock 四周必须留出的**最小**空隙（vp）。
 *
 * 为什么是 30 而不是随手一个好看的值：AppleUI 的折射/色散/模糊采样点会落到
 * 透镜形状之外，因此它把画布向四周各外扩 30vp（源码里的 `padVp`），
 * 并按「画布」而非「透镜」去截取下层背景。如果玻璃离父层边缘不足 30vp，
 * 这块外扩区就会超出父层边界，截帧请求被判为越界
 * （真机日志：`Snapshot reigon out of range` → `snapshot fail 401`），
 * 玻璃**完全不渲染**，只剩一层透明 —— 看起来像没生效，其实是被静默跳过了。
 * 所以左右边距与底部留白都必须 >= 30。
 */
const DOCK_PAD: number = 30;
/** 左右边距：在 DOCK_PAD 基础上再多一点，让胶囊不贴边、更像浮层 */
const DOCK_MARGIN: number = DOCK_PAD + 4;
/** 底部留白：同样取 DOCK_PAD 以上，保证画布外扩区落在窗口内 */
const DOCK_BOTTOM: number = DOCK_PAD + 6;

/** 导航项 */
class NavItem {
  key: string;
  label: string;
  icon: string;

  constructor(key: string, label: string, icon: string) {
    this.key = key;
    this.label = label;
    this.icon = icon;
  }
}

@Entry
@Component
struct Index {
  @StorageProp('breakpoint') @Watch('publishBottomInset') bp: number = Bp.SM;
  @StorageProp(AS_LOGGED_IN) @Watch('publishBottomInset') loggedIn: boolean = false;
  @StorageProp(AS_STUDENT_NAME) studentName: string = '';
  /**
   * 窗口宽度（vp）。AppleUI 的 Width/Height 是 number（vp），
   * 不能用 '100%'，因此玻璃胶囊宽度必须由这里实算。
   */
  @StorageProp(AS_WINDOW_WIDTH) winWidth: number = 360;
  /**
   * 窗口高度（vp）。AppleUI 的 Height 是 number（vp），
   * 侧栏玻璃要占满高度，因此必须知道实际高度。
   */
  @StorageProp(AS_WINDOW_HEIGHT) winHeight: number = 800;
  /**
   * 侧栏实测尺寸（vp），由 onAreaChange 写入。
   *
   * 玻璃透镜必须按**实测**尺寸算：AppleUI 的画布会向四周外扩 30vp，
   * 尺寸取大一点就会截帧越界、玻璃完全不画（不报错，只是不显示）。
   */
  @State sidebarW: number = 0;
  @State sidebarH: number = 0;
  /** 会话失效且已保存凭据时置位，界面弹出「重新验证」弹窗 */
  @StorageProp(AS_REAUTH_PENDING) reauthPending: boolean = false;
  @State active: string = 'schedule';
  @State restoring: boolean = true;

  // 图标用 media/ 下的 Material svg 资源（与 Flutter 版 Icons.*_outlined 同源）。
  // 原先用 emoji：无法着色、跟不了主题与选中态，不同设备字形也不一致。
  //
  // 导航项与 Flutter 端 `kNavItems` 逐项对齐（课表/成绩/培养/通选/我的）。
  // 「空教室」不在其中：Flutter 也没有把它放在 dock 上，而是挂在课表页顶栏
  // —— 看课表时最常接着问的就是「哪儿有空教室」。放在 dock 既多占一格，
  // 又与「查自己的教务数据」这几个主入口不同类。
  private navItems: NavItem[] = [
    new NavItem('schedule', '课表', 'calendar_month'),
    new NavItem('score', '成绩', 'bar_chart'),
    new NavItem('plan', '培养', 'menu_book'),
    new NavItem('elective', '通选', 'extension'),
    new NavItem('profile', '我的', 'person')
  ];

  aboutToAppear(): void {
    // 键盘弹出时压缩可视区域（RESIZE），而不是整体上移（OFFSET），
    // 否则手机端登录表单的输入框会被顶出屏幕无法操作。
    try {
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    } catch (e) {
      // 忽略：不支持时用系统默认
    }
    this.bindWindow();
    this.restore();
    // 冷启动时 bp/loggedIn 不会再触发 @Watch，这里主动发布一次
    this.publishBottomInset();
  }

  /**
   * 按当前断点发布「底部让位高度」。
   *
   * 窄屏（手机）有浮层 dock，滚动内容需要留出它的高度；宽屏（平板/折叠屏展开）
   * 是左侧导航，底部没有东西，让位为 0（否则白白空掉一条）。
   * 由 bp / loggedIn 的 @Watch 驱动，折叠屏展开/折叠时自动跟随。
   */
  private publishBottomInset(): void {
    const inset: number = (this.loggedIn && this.bp === Bp.SM)
      ? DOCK_HEIGHT + DOCK_BOTTOM
      : 0;
    if (AppStorage.get<number>(AS_BOTTOM_INSET) !== inset) {
      AppStorage.setOrCreate(AS_BOTTOM_INSET, inset);
    }
  }

  private bindWindow(): void {
    const ctx = ContextHolder.get();
    if (ctx === null) {
      return;
    }
    try {
      window.getLastWindow(ctx).then((win: window.Window) => {
        WindowService.bind(win);
      }).catch(() => {
        // 忽略：无法获取窗口时用默认断点
      });
    } catch (e) {
      // 忽略
    }
  }

  private async restore(): Promise<void> {
    // 先把「是否已保存凭据」同步到 AppStorage：QzApi 判断会话失效后
    // 该弹重新验证弹窗、还是彻底退出时，需要同步读取这个标志。
    await ReAuthService.refreshCredentialFlag();
    // 冷启动时清掉上次遗留的「等待验证」标记，避免一进来就弹窗
    ReAuthService.clearPending();

    const ok: boolean = await AppState.restoreSession();
    if (ok) {
      // 乐观恢复：先进入主界面，账号信息从本地解析（不请求服务器），
      // 个人信息等数据由各页面按需加载；会话有效性已在后台静默校验。
      await AppState.resolveAccount();
      // 姓名显示在**外壳**上（侧栏标题下、内容页顶栏右侧），而它原先只有
      // 「我的」页会往 AppStorage 里写 —— 冷启动后不点进那一页就一直是空的
      // （用户反馈的 bug）。这里在恢复会话后立刻补一次：缓存优先，零请求。
      await ProfileService.ensureIdentity(false);
    }
    // 会话恢复完成后对齐一次周次（AppStorage 中已有值，无 6h 内不重算）
    try {
      await WeekService.align(false);
    } catch (e) {
      // 忽略
    }
    this.restoring = false;

    // 进入界面后，在后台尝试一次「无感续期」：
    // 若会话已失效且设备支持 OCR，就自动识别验证码静默登录，用户完全察觉不到。
    //
    // 注意这里**只做静默尝试，绝不弹窗**：按需求，用户若只是看课表
    // （数据来自本地缓存、不需要联网），无论会话是否失效都不应被打扰；
    // 只有当他真正用到需要联网的功能、请求被打回登录页时，
    // 才由 QzApi.ensureAuthed 置位并弹出重新验证弹窗。
    if (ok) {
      this.trySilentRenewal();
      // 姓名预取：缓存里没有时联网一次（等价于进「我的」页那次请求）。
      // 放在静默续期之后 —— 续期会重建会话，先续期能少一次失败请求。
      ProfileService.prefetchOnce();
    }
  }

  /**
   * 后台静默续期。刻意不设置任何 UI 状态：
   * 成功就顺手刷新当前页，失败就什么都不做 —— 真正的兜底是
   * 「用户点开需要联网的功能 → 请求失败 → 弹出验证码弹窗」。
   */
  private async trySilentRenewal(): Promise<void> {
    try {
      const alive: boolean = await AppState.apiInstance().isSessionAlive();
      if (alive) {
        return;
      }
      if (!ReAuthService.ocrAvailable()) {
        Logger.info('silent renewal skipped: no OCR capability');
        return;
      }
      Logger.info('silent renewal attempt with OCR');
      const out = await ReAuthService.tryAutoLogin();
      if (out.ok) {
        Logger.info('silent renewal succeeded');
        this.reloadCurrentPage();
      } else {
        Logger.info('silent renewal failed: ' + out.reason);
      }
    } catch (e) {
      Logger.warn('silent renewal error');
    }
  }

  private titleOf(): string {
    if (this.active === 'settings') {
      return '设置';
    }
    for (let i = 0; i < this.navItems.length; i++) {
      if (this.navItems[i].key === this.active) {
        return this.navItems[i].label;
      }
    }
    return 'hi山财';
  }

  @Builder
  content() {
    if (this.active === 'schedule') {
      SchedulePage({
        // 顶栏的空教室入口由外壳提供导航（页面自己不知道导航结构）
        onOpenClassroom: () => {
          this.active = 'classroom';
        }
      })
    } else if (this.active === 'score') {
      ScorePage()
    } else if (this.active === 'plan') {
      PlanPage()
    } else if (this.active === 'elective') {
      ElectivePage()
    } else if (this.active === 'classroom') {
      ClassroomPage()
    } else if (this.active === 'profile') {
      ProfilePage()
    } else {
      SettingsPage()
    }
  }

  /**
   * 手机：底部标签栏（AppleUI 液态玻璃胶囊）
   *
   * ===== 为什么换成 AppleUI =====
   * 之前用 `backgroundEffect`（模糊 + 提饱和 + 灰度噪声）模拟玻璃。那是
   * 「磨砂」而非「液态玻璃」：它只是把下层内容糊掉，没有边缘折射、没有色散，
   * 也看不到清晰的背景 —— 与 Flutter 端 `liquid_glass_widgets` 的观感差很远。
   *
   * `com.hm.appleui.hw` 走 XComponent + 原生 EGL/OpenGL ES 3.0，实时截取
   * **紧邻下层**的背景做透镜折射：中心保持透明可看穿，只在边缘做折射/色散/扭曲。
   * 与本机 API 24 也能用（该库 compatibleSdkVersion 为 20），
   * 因此不必等 API 26 的 uiMaterial。
   *
   * ===== 层次结构（顺序很关键）=====
   * 标签通过 AppleUI 的**尾随闭包**（媒体插槽）叠在玻璃上：这样标签的尺寸
   * 天然等于玻璃尺寸，不会出现「玻璃一层宽、图标另一层宽」而对不齐。
   * 媒体层自身不参与命中测试，但其子节点默认参与，所以标签仍能正常点击。
   *
   * AppleUI 必须与内容层同处一个 Stack、并作为它的**后序兄弟**：它靠
   * 「向前找最近一个与自身可见区域重叠的兄弟层」定位截帧目标，中间多夹一层
   * 容器会让截帧区域越界（真机日志 `Snapshot reigon out of range`，玻璃不渲染）。
   *
   * 玻璃的宽高必须是具体数值（vp），不能用 '100%'：AppleUI 的 Width/Height
   * 是 number 类型，且要据此计算画布与截帧区域。
   */
  @Builder
  dockGlass() {
    AppleUI({
      Width: Math.max(1, this.winWidth - DOCK_MARGIN * 2),
      Height: DOCK_HEIGHT,
      // '50%' = 半径取短边 1/4，得到规整的圆角矩形（'100%' 会是全圆药丸）
      Circle: '50%',
      // 不做背景模糊：中心看穿才是「液态玻璃」的关键特征
      Blur: 0,
      // 边缘折射强度：略高于默认 0.20，让厚度感与彩色镶边更明确
      NeoStrength: 0.28
    })
      .margin({ bottom: DOCK_BOTTOM })
  }

  /** dock 的标签行：图标 + 文字，叠在玻璃层之上负责响应点击 */
  @Builder
  dockTabs() {
    Row() {
      ForEach(this.navItems, (item: NavItem) => {
        Column({ space: 2 }) {
          AppIcon({
            res: item.icon,
            iconSize: 22,
            color: this.active === item.key
              ? $r('app.color.brand') : $r('app.color.text_secondary')
          })
          Text(item.label)
            .fontSize(Theme.FS_TINY)
            .fontColor(this.active === item.key ? $r('app.color.brand') : $r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        // 显式声明水平居中：图标与文字都以此为基准对齐。
        // 之前依赖默认值，加上 AppIcon 自身尺寸不一致，
        // 结果每个图标相对文字系统性左偏（实测约 12–17px）。
        .alignItems(HorizontalAlign.Center)
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.active = item.key;
        })
      }, (item: NavItem) => item.key)

      Column({ space: 2 }) {
        AppIcon({
          res: 'settings',
          iconSize: 22,
          color: this.active === 'settings'
            ? $r('app.color.brand') : $r('app.color.text_secondary')
        })
        Text('设置')
          .fontSize(Theme.FS_TINY)
          .fontColor(this.active === 'settings' ? $r('app.color.brand') : $r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.active = 'settings';
      })
    }
    .width('100%')
    .height(DOCK_HEIGHT)
    // 与玻璃用**同一组**边距常量，两层的宽度因此天然一致，不会错位
    .padding({ left: DOCK_MARGIN, right: DOCK_MARGIN })
    .margin({ bottom: DOCK_BOTTOM })
  }

  /** 大屏：侧边导航 */
  @Builder
  sideBar() {
    // 侧栏也铺一层 AppleUI 液态玻璃。
    //
    // 与底部 dock 同一套做法：整体是一个 Stack，AppleUI 在下层画透镜、
    // 上层 Column 承载导航项。宽屏（平板/折叠屏展开）时它就是主导航，
    // 之前只有一层不透明 surface 底色，与手机端的玻璃 dock 观感割裂。
    //
    // 尺寸用具体数值（AppleUI 的 Width/Height 是 number）：
    // 侧栏固定 200vp 宽、占满高度，高度由布局给定（见下方 height('100%')）。
    Stack() {
      // 侧栏的玻璃底：用 backgroundEffect（模糊 + 提饱和）而不是 AppleUI。
      //
      // ===== 为什么侧栏不能用 AppleUI（实测结论）=====
      // AppleUI 靠「向前找最近一个与自身可见区域重叠的兄弟层」来决定截帧
      // 目标。侧栏是 Row 的第一个子节点，背后没有任何内容，因此它没有可
      // 折射的对象。补一层取样层也救不回来：真机日志显示它算出的截帧区域
      // 宽 424 而已知侧栏是 200vp，量纲对不上，SDK 直接判越界 ——
      // 连续 900+ 条 `snapshot fail 401`，玻璃一格都不画。
      //
      // 底部 dock 之所以能用 AppleUI，是因为它前面就是整页内容，天然有
      // 可折射的兄弟层。侧栏这种「贴边、背后无内容」的容器不适合它。
      // 因此这里退回 backgroundEffect —— 观感是磨砂玻璃（模糊 + 提饱和），
      // 与弹窗、周次选择器同一手法，稳定且不挑容器。
      Column()
        .width('100%')
        .height('100%')
        .backgroundEffect(GlassKit.panelEffect())

      Column({ space: Theme.GAP_S }) {
      Column({ space: 2 }) {
        Text('hi山财')
          .fontSize(Theme.FS_SECTION)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        if (this.studentName.length > 0) {
          Text(this.studentName)
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.GAP, top: Theme.GAP, bottom: Theme.GAP_L })

      ForEach(this.navItems, (item: NavItem) => {
        Row({ space: Theme.GAP_S }) {
          AppIcon({
            res: item.icon,
            iconSize: 18,
            color: this.active === item.key
              ? $r('app.color.brand') : $r('app.color.text_secondary')
          })
          Text(item.label)
            .fontSize(Theme.FS_BODY)
            .fontColor(this.active === item.key ? $r('app.color.brand') : $r('app.color.text_secondary'))
            .fontWeight(this.active === item.key ? FontWeight.Medium : FontWeight.Normal)
        }
        .width('100%')
        .height(44)
        .padding({ left: Theme.GAP })
        .borderRadius(Theme.RADIUS_SM)
        .backgroundColor(this.active === item.key ? $r('app.color.brand_soft') : Color.Transparent)
        .onClick(() => {
          this.active = item.key;
        })
      }, (item: NavItem) => item.key)

      Blank()

      Row({ space: Theme.GAP_S }) {
        AppIcon({
          res: 'settings',
          iconSize: 18,
          color: this.active === 'settings'
            ? $r('app.color.brand') : $r('app.color.text_secondary')
        })
        Text('设置')
          .fontSize(Theme.FS_BODY)
          .fontColor(this.active === 'settings' ? $r('app.color.brand') : $r('app.color.text_secondary'))
      }
      .width('100%')
      .height(44)
      .padding({ left: Theme.GAP })
      .borderRadius(Theme.RADIUS_SM)
      .backgroundColor(this.active === 'settings' ? $r('app.color.brand_soft') : Color.Transparent)
      .onClick(() => {
        this.active = 'settings';
      })
      }
      .width('100%')
      .height('100%')
      .padding({ left: Theme.GAP_S, right: Theme.GAP_S, bottom: Theme.GAP })
    }
    .width(SIDEBAR_W)
    .height('100%')
    // 实测本容器的真实尺寸，供上面决定玻璃透镜多大
    .onAreaChange((_old: Area, now: Area) => {
      const w: number = Number(now.width);
      const h: number = Number(now.height);
      if (w > 0 && h > 0 && (w !== this.sidebarW || h !== this.sidebarH)) {
        this.sidebarW = w;
        this.sidebarH = h;
      }
    })
    .border({ width: { right: 0.5 }, color: $r('app.color.divider') })
  }

  /** 大屏下的内容页标题栏 */
  @Builder
  contentHeader() {
    Row() {
      Text(this.titleOf())
        .fontSize(Theme.FS_SECTION)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Blank()
      if (this.studentName.length > 0) {
        Text(this.studentName)
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.text_tertiary'))
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: Theme.GAP_L, right: Theme.GAP_L })
    // 磨砂而不是实色：内容会从它下面穿过，实色会把渐变模糊整个挡住，
    // 「越靠顶越糊」就看不出来了。这一条同时是 Flutter 端顶栏的做法。
    .backgroundEffect(GlassKit.barEffect())
    .border({ width: { bottom: 0.5 }, color: $r('app.color.divider') })
  }

  /** 宽屏布局：左导航 + 右内容（顶栏浮于内容之上，其他页顶部渐糊） */
  @Builder
  wideLayout() {
    Row() {
      this.sideBar()
      // ===== 顶栏浮在内容之上 =====
      //
      // 早先是 Column{ 顶栏; 内容 }：内容被顶栏挤在下面、永远到不了顶栏区域，
      // 于是「内容从顶栏下滚过 + 顶部渐糊」这个效果根本无从谈起（没东西可糊）。
      //
      // 现在改成 Stack：内容占满、从顶栏下穿过；顶栏浮在其上。
      // 顶栏本体用 barEffect 磨砂而不是实色，穿过的内容在它后面就是「透过」的。
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.content()
        }
        .width('100%')
        .height('100%')
        // 顶栏是浮层，内容必须自己让出它的高度 —— 否则各页顶部的筛选栏
        // （周次/学期/校历那一行）会被压在顶栏下面看不见。
        // 让位放在**内容容器**上而不是滚动内容里：这样它是一次性偏移，
        // 不必改动六个页面各自的滚动结构（每个页面内部都有自己的
        // 固定筛选栏 + 滚动区，逐个改风险与工作量都大得多）。
        .padding({ top: Index.HEADER_H })
        // 顶部渐糊（**课表页不做**，见 topBlurStops 的说明）。
        // 放在内容层上而不是「顶栏位置的一个空模糊层」—— 后者会被 AppleUI
        // 判为「空白截帧目标」并返回全黑图，把浮层玻璃一起弄黑
        // （见 AppleUI 的 REMIND.md 与 GlassKit 文件头）。
        .linearGradientBlur(this.topBlurRadius(), {
          fractionStops: this.topBlurStops(),
          direction: GradientDirection.Bottom
        })

        this.contentHeader()
      }
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  private static readonly HEADER_H: number = 52;

  /**
   * 课表页不做顶部模糊。
   *
   * 用户明确要求。原因也说得通：课表是**整屏网格**，顶部那几行本身就是
   * 要读的内容（节次/日期），糊掉等于降低可读性；而其余页面顶部是
   * 标题栏 + 可选中的列表，糊一层只是装饰。
   */
  private topBlurRadius(): number {
    return this.active === 'schedule' ? 0 : 14;
  }

  /**
   * 顶部模糊的渐变区间：**只覆盖顶栏那一段高度**。
   *
   * ===== 为什么必须按真实高度算，不能写死比例 =====
   * fractionStops 的位置是相对**组件高度**归一化的。早先写死 0.34，
   * 在 800vp 高的窗口上等于糊掉顶部 272vp —— 远超 52vp 的顶栏，
   * 于是「划到该区域的内容才模糊」变成了「上面一大片都是糊的」。
   * 现在按 HEADER_H / 窗口高度 算出真实比例，只有顶栏那一条受影响。
   *
   * 多个 stop 是为了近似 smoothstep：SDK 只在 stop 之间线性插值，
   * 点少了会看出折线感（Flutter 端实测「24 条模糊带仍有条纹」，
   * 这里用同样的思路：一次绘制、多点近似）。
   */
  private topBlurStops(): FractionStop[] {
    const h: number = this.winHeight > 0 ? this.winHeight : 800;
    // 模糊带比顶栏略高一点（1.35 倍）：顶栏下沿留一段过渡，
    // 否则内容滚到顶栏正下方时会「啪」地一下从清晰变糊，边界很硬。
    const end: number = Math.min(0.5, (Index.HEADER_H * 1.35) / h);
    return [
      [1, 0],
      [0.94, end * 0.18],
      [0.78, end * 0.38],
      [0.55, end * 0.59],
      [0.30, end * 0.76],
      [0.10, end * 0.91],
      [0, end]
    ];
  }

  /**
   * 窄屏布局：内容 + 浮在内容之上的玻璃 dock。
   *
   * 三层都是**同一个 Stack 的直接子节点**，这一点对 AppleUI 很关键：
   * 它靠「向前找最近一个与自身可见区域重叠的兄弟层」解析截帧目标，
   * 若玻璃被包在内层容器里，解析出的截帧区域会超出目标节点范围
   * （真机表现为 `Snapshot reigon out of range`，玻璃整块不渲染）。
   *
   * dock 是浮层而非把内容挤上去的一条栏：内容占满整屏并从玻璃下面滚过，
   * 玻璃中心透明，于是能看到被遮挡的内容。底部让位由各页面订阅
   * AS_BOTTOM_INSET 处理。
   */
  @Builder
  narrowLayout() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.content()
      }
      .width('100%')
      .height('100%')

      // 顺序很关键：玻璃在前（先绘制并解析到内容层做截帧目标），
      // 标签在后叠于其上接收点击。两者都是 Stack 的直接子节点。
      this.dockGlass()
      this.dockTabs()
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 外壳底色：**成绩页刻意不铺**，其余页面铺。
   *
   * 成绩页要的是「列表之外（尤其是底部）透出下层」—— 窗口背景已在
   * EntryAbility 里设为透明，所以不铺底色就能透出桌面/壁纸。
   *
   * 其余页面必须铺：它们的内容常常不满一屏（培养方案、通识、设置等），
   * 不铺的话会直接露出桌面，看起来像渲染坏了。
   * 课表页虽然也不铺自己的底色，但网格自带 sched_bg，所以这里照铺无妨。
   */
  private pageBackground(): ResourceColor {
    if (this.loggedIn && this.active === 'score') {
      return Color.Transparent;
    }
    return $r('app.color.bg');
  }

  build() {
    Stack() {
      Column() {
        if (this.restoring) {          Column({ space: Theme.GAP }) {
            LoadingProgress()
              .width(44)
              .height(44)
              .color($r('app.color.brand'))
            Text('hi山财')
              .fontSize(Theme.FS_SMALL)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.bg'))
        } else if (!this.loggedIn) {
          LoginPage({
            onSuccess: () => {
              this.active = 'schedule';
            }
          })
        } else if (this.bp === Bp.SM) {
          this.narrowLayout()
        } else {
          this.wideLayout()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.pageBackground())

      /**
       * 会话失效且已保存账号密码时，用居中弹窗覆盖在当前页面上补验证码，
       * 而不是把用户踢回登录页 —— 页面与浏览位置都保持不变。
       * 验证成功后刷新当前页数据，让刚才失败的请求重来一次。
       */
      if (this.loggedIn && this.reauthPending) {
        GlassOverlay({
          panelWidthRatio: 0.86,
          panelHeightRatio: 0.62,
          maxPanelWidth: 420,
          // 不加自动关闭：这是「必须处理」的浮层，点遮罩不该让它消失
          // （用户会以为已经登录成功）。只能通过内部的取消/提交离开。
          onDismiss: () => {}
        }) {
          ReAuthDialog({
            onDone: () => {
              this.reauthPending = false;
              this.reloadCurrentPage();
            },
            onGiveUp: () => {
              this.reauthPending = false;
              ReAuthService.giveUp();
            }
          })
        }
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }

  /**
   * 重新验证成功后刷新当前页。
   *
   * 做法是把 active 先清空再设回：ArkUI 会销毁并重建该页面组件，
   * 从而重新触发它的 aboutToAppear → 重新拉数据。
   * （这些页面都带会话内缓存，但会话失效时缓存已被判定无效，
   *   重建会重新请求；即使命中缓存也不会报错。）
   */
  private reloadCurrentPage(): void {
    const cur: string = this.active;
    this.active = '';
    this.active = cur;
  }
}
