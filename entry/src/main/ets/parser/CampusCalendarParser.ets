/*
 * CampusCalendarParser：解析学校官网的校历页（**纯逻辑，无 @kit 依赖**）
 *
 * 为什么和 CampusCalendarService 分开：
 *   抓取与缓存要碰 @kit（NetworkKit / CoreFileKit），无法在 Node 里跑测试；
 *   而解析逻辑恰恰是最容易「学校改版后悄悄失效」的部分，必须能单测。
 *   因此把解析全部放这里（可被 testdata/run-tests.mjs 直接编译运行），
 *   CampusCalendarService 只负责取字节、落盘、读缓存。
 *
 * 页面结构（实测 https://www.sdufe.edu.cn/xyfw/zxxl.htm）：
 *   - 正文有一张 `<table>`，表头是「节次 | 起止时间」，
 *     行形如「第一、二节 | 8:30-10:00」「课间休息 | 10:00-10:20」；
 *   - 两张校历图是 `<img src="/virtual_attach_file.vsb?...e=.jpg">`，
 *     另有 `orisrc="..."` 指向压缩更轻的原图；
 *   - 表格下方有「更新时间：2026年7月」。
 */

/** 课表的 5 行（与 Constants.SECTIONS 一致；这里独立一份以免解析层依赖 UI 常量） */
const GRID_ROWS: number = 5;

export class CampusCalendarParser {
  /**
   * 取「日常教学时刻表」。
   *
   * 返回形如 `['第一、二节  08:30 - 10:00', '课间休息  10:00 - 10:20', ...]`。
   * 注意官网把节次**逐个**列出（前 4 行各含两节，另有「第九、十节」与
   * 「第十一节」两行），因此这里会有 6 个上课行 —— 与课表的 5 行并不同构，
   * 归并交给 mapToGridRows。
   */
  static sectionLines(html: string): string[] {
    const rows: string[][] = CampusCalendarParser.sectionRows(html);
    const out: string[] = [];
    for (let i = 0; i < rows.length; i++) {
      const r: string[] = rows[i];
      if (r.length < 2) {
        continue;
      }
      const label: string = r[0];
      const range: string = CampusCalendarParser.normalizeRange(r[1]);
      if (label.length === 0 || range.length === 0) {
        continue;
      }
      out.push(label + '  ' + range);
    }
    return out;
  }

  /** 作息表原始行（[节次, 起止时间]），表头行被剔除 */
  static sectionRows(html: string): string[][] {
    const table: string | null = CampusCalendarParser.findTable(html, '起止时间');
    if (table === null) {
      return [];
    }
    const rows: string[][] = [];
    const rowRe: RegExp = /<tr[^>]*>([\s\S]*?)<\/tr>/gi;
    let rm: RegExpExecArray | null = rowRe.exec(table);
    while (rm !== null) {
      const rowHtml: string = rm[1];
      const cells: string[] = [];
      const cellRe: RegExp = /<t[dh][^>]*>([\s\S]*?)<\/t[dh]>/gi;
      let cm: RegExpExecArray | null = cellRe.exec(rowHtml);
      while (cm !== null) {
        cells.push(CampusCalendarParser.text(cm[1]));
        cm = cellRe.exec(rowHtml);
      }
      if (cells.length >= 2) {
        rows.push(cells);
      }
      rm = rowRe.exec(table);
    }
    const out: string[][] = [];
    for (let i = 0; i < rows.length; i++) {
      const r: string[] = rows[i];
      if (r[0].indexOf('节次') >= 0 || r[1].indexOf('起止时间') >= 0) {
        continue;
      }
      out.push(r);
    }
    return out;
  }

  /**
   * 取校历图片地址（绝对化），按出现顺序、去重。
   *
   * 每张图有两个地址：`src`（站内展示版，实测 800px / 约 380KB）
   * 与 `orisrc`（原图，像素相同但压缩更轻，约 1.4MB）。
   * 优先取原图 —— 日历图用户会放大看，少一层 JPEG 压缩明显更清楚，
   * 而且只缓存在本机、不进安装包。属性名在 CMS 里拼作 `orisrc`（少一个 g），
   * 两种拼法都认。
   */
  static imageUrls(html: string, pageUrl: string): string[] {
    const out: string[] = [];
    const imgRe: RegExp = /<img[^>]*>/gi;
    let m: RegExpExecArray | null = imgRe.exec(html);
    while (m !== null) {
      const tag: string = m[0];
      if (tag.indexOf('virtual_attach_file') >= 0) {
        // 属性名匹配必须带边界：标签里 "orisrc=" 的结尾恰好是 "src="，
        // 朴素的子串匹配会在属性顺序变化时取错值。
        let pick: string = CampusCalendarParser.attr(tag, 'origsrc');
        if (pick.length === 0) {
          pick = CampusCalendarParser.attr(tag, 'orisrc');
        }
        if (pick.length === 0) {
          pick = CampusCalendarParser.attr(tag, 'src');
        }
        if (pick.length > 0) {
          // `&amp;` 是 HTML 转义，URL 里必须是 `&`
          const abs: string = CampusCalendarParser.absolute(
            pick.replace(/&amp;/g, '&'), pageUrl);
          if (out.indexOf(abs) < 0) {
            out.push(abs);
          }
        }
      }
      m = imgRe.exec(html);
    }
    return out;
  }

  /** 取官网标注的更新时间，如 `2026年7月`；取不到返回空串 */
  static updated(html: string): string {
    const t: string = CampusCalendarParser.text(html);
    const m: RegExpMatchArray | null =
      t.match(/更新时间[:：]\s*([0-9]{4}\s*年\s*[0-9]{1,2}\s*月)/);
    if (m === null || m.length < 2) {
      return '';
    }
    return m[1].replace(/\s+/g, '');
  }

  /**
   * 把官网作息行归并成课表的 5 行，返回 `[start, end]` 列表。
   *
   *   - 先剔除「课间休息」行，只留上课节次；
   *   - 上课行数 **恰好 5** → 一一对应；
   *   - **多于 5** → 前 4 行一一对应，多出来的并进第 5 行
   *     （取首行起点、末行终点）；
   *   - **少于 5** → 官网改版成别的结构，不做映射（返回空数组），
   *     宁可继续用本地值，也不要按错位的时间算上课提醒。
   */
  static mapToGridRows(sectionLines: string[]): string[][] {
    const teach: string[][] = [];
    for (let i = 0; i < sectionLines.length; i++) {
      const line: string = sectionLines[i];
      if (line.indexOf('课间') >= 0) {
        continue;
      }
      const m: RegExpMatchArray | null =
        line.match(/^(\S+)\s+(\d{2}:\d{2})\s*-\s*(\d{2}:\d{2})$/);
      if (m !== null && m.length >= 4) {
        teach.push([m[2], m[3]]);
      }
    }
    if (teach.length < GRID_ROWS) {
      return [];
    }
    if (teach.length === GRID_ROWS) {
      return teach;
    }
    const out: string[][] = [];
    for (let i = 0; i < GRID_ROWS - 1; i++) {
      out.push(teach[i]);
    }
    out.push([teach[GRID_ROWS - 1][0], teach[teach.length - 1][1]]);
    return out;
  }

  // ---------- HTML 小工具 ----------

  /** 找到含 headerText 的那张表，返回从 `<table` 到配平的 `</table>` */
  private static findTable(html: string, headerText: string): string | null {
    const openRe: RegExp = /<table[^>]*>/gi;
    let m: RegExpExecArray | null = openRe.exec(html);
    while (m !== null) {
      const t: string | null = CampusCalendarParser.balance(html, m.index);
      if (t !== null && t.indexOf(headerText) >= 0) {
        return t;
      }
      m = openRe.exec(html);
    }
    return null;
  }

  /** 从 `<table` 处按嵌套深度配平取出整张表 */
  private static balance(html: string, start: number): string | null {
    const rest: string = html.substring(start);
    const tagRe: RegExp = /<(\/?)table[^>]*>/gi;
    let depth: number = 0;
    let m: RegExpExecArray | null = tagRe.exec(rest);
    while (m !== null) {
      if (m[1].length > 0) {
        depth--;
        if (depth === 0) {
          return rest.substring(0, m.index + m[0].length);
        }
      } else {
        depth++;
      }
      m = tagRe.exec(rest);
    }
    return null;
  }

  /** 去标签 + 解实体 + 压空白 */
  private static text(html: string): string {
    return html
      .replace(/<[^>]*>/g, ' ')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/\s+/g, ' ')
      .trim();
  }

  /**
   * 取属性值（支持 `name="v"` 与 `name='v'`）。
   *
   * 用「前一字符不是标识符字符」保证 `src` **不会**匹配到 `orisrc=` 的尾部，
   * 也不匹配 `data-src` 这类带前缀的属性 —— 学校 CMS 的属性顺序不保证。
   */
  private static attr(tag: string, name: string): string {
    const re: RegExp = new RegExp(
      '(^|[^A-Za-z0-9_-])' + name + '\\s*=\\s*("([^"]*)"|\'([^\']*)\')', 'i');
    const m: RegExpMatchArray | null = tag.match(re);
    if (m === null || m.length < 5) {
      return '';
    }
    const dq: string = m[3];
    const sq: string = m[4];
    if (dq !== undefined && dq !== null) {
      return dq;
    }
    if (sq !== undefined && sq !== null) {
      return sq;
    }
    return '';
  }

  /** 相对地址 → 绝对地址 */
  private static absolute(url: string, pageUrl: string): string {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }
    const m: RegExpMatchArray | null = pageUrl.match(/^(https?:\/\/[^\/]+)/);
    if (m === null || m.length < 2) {
      return url;
    }
    const origin: string = m[1];
    return url.startsWith('/') ? origin + url : origin + '/' + url;
  }

  /**
   * `8:30-10:00` → `08:30 - 10:00`（补齐前导零，统一展示形态）。
   *
   * 兼容全角冒号/连字符/波浪线与全角数字 —— 这类字符在富文本编辑器里
   * 很容易被误输入，一旦出现就会让整行解析为空，
   * 表现为「作息表突然少了几行」而没有任何报错。
   */
  private static normalizeRange(raw: string): string {
    const s: string = CampusCalendarParser.normalizeWidth(raw);
    const m: RegExpMatchArray | null =
      s.match(/(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})/);
    if (m === null || m.length < 5) {
      return '';
    }
    const two = (v: string): string => v.length === 1 ? '0' + v : v;
    return two(m[1]) + ':' + m[2] + ' - ' + two(m[3]) + ':' + m[4];
  }

  /** 全角 → 半角，并把各种「横线」统一成 `-` */
  private static normalizeWidth(raw: string): string {
    let out: string = '';
    for (let i = 0; i < raw.length; i++) {
      const c: number = raw.charCodeAt(i);
      if (c === 0xFF1A) {
        out = out + ':';                                      // 全角冒号
      } else if (c >= 0xFF10 && c <= 0xFF19) {
        out = out + String.fromCharCode(c - 0xFF10 + 0x30);   // 全角数字
      } else if (c === 0x3000) {
        out = out + ' ';                                      // 全角空格
      } else if (c === 0xFF0D || c === 0x2013 || c === 0x2014 || c === 0x2015 ||
        c === 0xFF5E || c === 0x301C || c === 0x2212 || c === 0x7E ||
        c === 0x223C) {
        out = out + '-';                   // 各种横线/波浪线统一成连字符
      } else {
        out = out + raw.charAt(i);
      }
    }
    return out;
  }
}
