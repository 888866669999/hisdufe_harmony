/*
 * 响应式：跟踪窗口宽度，映射到 sm/md/lg 断点
 *
 * 宽度写入 AppStorage，页面用 @StorageProp 订阅，折叠屏展开/折叠时可实时切换布局。
 */
import { window } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { Logger } from '../common/Logger';
import { BP_MEDIUM, BP_LARGE, AS_WINDOW_WIDTH, AS_WINDOW_HEIGHT, AS_BREAKPOINT } from './Constants';

/** AppStorage 键统一在 Constants 中定义，这里转出以保持既有引用可用 */
export { AS_WINDOW_WIDTH, AS_WINDOW_HEIGHT, AS_BREAKPOINT } from './Constants';

/** 断点枚举 */
export enum Bp {
  SM = 0,
  MD = 1,
  LG = 2
}

export class WindowService {
  private static win: window.Window | null = null;

  /** 绑定窗口并开始监听尺寸变化 */
  static bind(win: window.Window): void {
    WindowService.win = win;
    // 关键：宽高都取**窗口**尺寸，不取屏幕尺寸。
    //
    // 平板/折叠屏上应用常跑在悬浮窗或分屏里，窗口比屏幕小得多。
    // 早先用 display 的宽高，导致 AppleUI 的玻璃尺寸远大于父容器，
    // 截帧越界后玻璃完全不渲染（真机实测 807 条 snapshot fail 401）。
    const Rect: window.Rect = WindowService.windowRect(win);
    WindowService.publish(WindowService.pxToVp(Rect.width));
    AppStorage.setOrCreate(AS_WINDOW_HEIGHT, WindowService.pxToVp(Rect.height));
    try {
      win.on('windowSizeChange', (size: window.Size) => {
        // 高度同样要按 vp 发布（AppleUI 的 Height 是 number/vp）
        AppStorage.setOrCreate(AS_WINDOW_HEIGHT, WindowService.pxToVp(size.height));
        // 关键：`windowSizeChange` 回调给出的是 **px**，而布局用的是 vp。
        // 早期直接把 px 写进 AppStorage，等于在 2x 屏上把宽度报成两倍 ——
        // 于是 `fitsOneScreen()` 误判「一屏放得下 7 列」，
        // 把 7 列硬塞进一个窄窗口，文字被挤到溢出（平板实测到的问题）。
        WindowService.publish(WindowService.pxToVp(size.width));
      });
    } catch (e) {
      Logger.warn('windowSizeChange listen failed');
    }
  }

  /**
   * px → vp。
   *
   * 全局只此一处换算，避免「有的地方用 px、有的地方用 vp」这种
   * 最容易被忽略的尺寸 bug（本次平板溢出就是这么来的）。
   */
  static pxToVp(px: number): number {
    const density: number = WindowService.density();
    return density > 0 ? px / density : px;
  }

  /** 当前显示密度（160dpi 为 1.0） */
  private static density(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      return d.densityDPI > 0 ? d.densityDPI / 160 : 1;
    } catch (e) {
      return 1;
    }
  }

  /** 窗口矩形（px）。取不到时退回屏幕尺寸。 */
  private static windowRect(win: window.Window): window.Rect {
    try {
      const props: window.WindowProperties = win.getWindowProperties();
      const r: window.Rect = props.windowRect;
      if (r !== undefined && r.width > 0 && r.height > 0) {
        return r;
      }
    } catch (e) {
      // 忽略：退回屏幕尺寸
    }
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      return { left: 0, top: 0, width: d.width, height: d.height };
    } catch (e) {
      return { left: 0, top: 0, width: 1080, height: 1920 };
    }
  }

  /**
   * 读一次当前宽度，**单位 vp**（与布局单位一致）。
   *
   * 已绑定窗口时以**窗口**为准（见 windowRect 的说明：悬浮窗/分屏下
   * 窗口远小于屏幕）；未绑定时退回屏幕宽度，供早期阶段有个可用值。
   */
  static currentWidth(): number {
    try {
      if (WindowService.win !== null) {
        return WindowService.pxToVp(
          WindowService.windowRect(WindowService.win).width);
      }
    } catch (e) {
      // 忽略：退回屏幕宽度
    }
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      return WindowService.pxToVp(d.width);
    } catch (e) {
      return 360;
    }
  }

  /** 写入 AppStorage */
  private static publish(width: number): void {
    AppStorage.setOrCreate(AS_WINDOW_WIDTH, width);
    AppStorage.setOrCreate(AS_BREAKPOINT, WindowService.classify(width));
  }

  /** 宽度 -> 断点 */
  static classify(width: number): number {
    if (width >= BP_LARGE) {
      return Bp.LG;
    }
    if (width >= BP_MEDIUM) {
      return Bp.MD;
    }
    return Bp.SM;
  }
}
