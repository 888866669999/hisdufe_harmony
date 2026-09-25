/*
 * 主题与设计令牌：颜色走资源（自动适配深浅色），尺寸用常量
 */
import { AS_BOTTOM_INSET } from '../common/Constants';

export class Theme {
  /** 圆角 */
  static readonly RADIUS: number = 14;
  static readonly RADIUS_SM: number = 10;

  /** 间距 */
  static readonly GAP_S: number = 6;
  static readonly GAP: number = 12;
  static readonly GAP_L: number = 20;

  /** 页面内边距 */
  static readonly PAGE_PAD: number = 16;

  /** 字号 */
  static readonly FS_TITLE: number = 22;
  static readonly FS_SECTION: number = 16;
  static readonly FS_BODY: number = 14;
  static readonly FS_SMALL: number = 12;
  static readonly FS_TINY: number = 11;

  /** 课表格尺寸 */
  static readonly GRID_HEADER_H: number = 40;
  static readonly GRID_SECTION_W: number = 64;
  static readonly GRID_CELL_MIN_H: number = 92;

  /** 课程配色（按课程名散列取色，保证同一课程颜色稳定） */
  private static readonly COURSE_COLORS: string[] = [
    '#2957C9', '#12805C', '#B54708', '#7A3FBF', '#0E7490', '#B42318', '#3B6E1F', '#8E4F1D'
  ];

  static courseColor(seed: string): string {
    let h: number = 0;
    for (let i = 0; i < seed.length; i++) {
      h = (h * 31 + seed.charCodeAt(i)) % 100000;
    }
    return Theme.COURSE_COLORS[h % Theme.COURSE_COLORS.length];
  }

  /** 课程色的浅底（同色相的低透明度） */
  static courseBg(seed: string): string {
    return Theme.courseColor(seed) + '1A';
  }

  /**
   * 滚动内容需要留出的底部空白（vp）。
   *
   * 手机端底部 dock 是**浮在内容之上**的玻璃胶囊，内容会从玻璃下面滚过 ——
   * 这样才能透过透明的玻璃中心看到被遮挡的信息。代价是滚动到底时最后一行
   * 会压在 dock 下面，所以要按这个值补一段底部空白。
   *
   * 值由 Index 按当前布局写入（宽屏/平板没有底部 dock，为 0）。
   *
   * 用法：`bottom: Theme.GAP + Theme.bottomInset()`
   */
  static bottomInset(): number {
    try {
      const v: number | undefined = AppStorage.get<number>(AS_BOTTOM_INSET);
      return v === undefined ? 0 : v;
    } catch (e) {
      return 0;
    }
  }
}
