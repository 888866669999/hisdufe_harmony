/*
 * HtmlLite：面向教务系统服务端渲染页面的轻量容错 HTML 解析器
 *
 * ArkTS 没有 DOM，因此这里用带配对扫描的字符串解析：
 *   - 只做「取元素 / 取表格 / 取行 / 取单元格 / 取 select / 取 input」这些必要能力
 *   - 容忍未闭合标签、&nbsp;、<br>、嵌套 <font>
 */

/** 元素结构 */
export class HtmlElement {
  tag: string = '';
  id: string = '';
  cls: string = '';
  attributes: string = '';
  /** 元素的内部 HTML */
  inner: string = '';
  /** 元素的完整 HTML */
  outer: string = '';
}

/** 表格单元格 */
export class HtmlCell {
  tag: string = 'td';
  id: string = '';
  cls: string = '';
  colspan: number = 1;
  rowspan: number = 1;
  /**
   * 单元格**开标签**的完整原文（含属性）。
   *
   * 为什么需要保留：有些页面把关键信息放在单元格的属性里而不是文本里，
   * 例如教学周历 `<td title='2026年08月24'><B>24</B></td>` ——
   * 格子里只有「24」这个数字，**完整年月日只存在于 title 属性中**。
   * 只暴露 inner/text 就无法解析这种结构。
   */
  openTag: string = '';
  inner: string = '';
  text: string = '';

  /** 读该单元格开标签上的某个属性值；没有返回空串 */
  attr(name: string): string {
    return this.openTag.length > 0 ? HtmlLite.attr(this.openTag, name) : '';
  }
}

/** 表格行 */
export class HtmlRow {
  cells: HtmlCell[] = [];
  text: string = '';
}

/** 表格 */
export class HtmlTable {
  id: string = '';
  cls: string = '';
  rows: HtmlRow[] = [];

  /** 第一个非空行的文本，用于表头识别 */
  headerText(): string {
    for (let i = 0; i < this.rows.length; i++) {
      const t: string = this.rows[i].text;
      if (t.length > 0) {
        return t;
      }
    }
    return '';
  }
}

/** 解析结果条目（select 的 option） */
export class HtmlOption {
  label: string;
  value: string;
  selected: boolean;

  constructor(label: string, value: string, selected: boolean) {
    this.label = label;
    this.value = value;
    this.selected = selected;
  }
}

export class HtmlLite {
  /** 需要跳过内容的标签 */
  private static readonly VOID_TAGS: string[] = ['br', 'img', 'input', 'hr', 'meta', 'link', 'base', 'col', 'source', 'area'];

  /** 解码常见 HTML 实体 */
  static decode(s: string): string {
    let r: string = s;
    r = r.replace(/&nbsp;/gi, ' ');
    r = r.replace(/&lt;/gi, '<');
    r = r.replace(/&gt;/gi, '>');
    r = r.replace(/&quot;/gi, '"');
    r = r.replace(/&apos;/gi, "'");
    r = r.replace(/&#0?39;/g, "'");
    r = r.replace(/&amp;/gi, '&');
    return r;
  }

  /** 把 HTML 片段转成纯文本：<br> 变行、块级标签断行、去标签、解码实体 */
  static toText(frag: string): string {
    let r: string = frag;
    // 注释
    r = r.replace(/<!--[\s\S]*?-->/g, '');
    // <br> 变换行
    r = r.replace(/<br\s*\/?>/gi, '\n');
    // 块级结束标签断行
    r = r.replace(/<\/(div|p|tr|td|th|li|table|h1|h2|h3|h4|h5|h6|section)\s*>/gi, '\n');
    // 其余标签去掉
    r = r.replace(/<[^>]*>/g, '');
    // 实体
    r = r.replace(/&nbsp;/gi, ' ');
    r = r.replace(/&lt;/gi, '<');
    r = r.replace(/&gt;/gi, '>');
    r = r.replace(/&quot;/gi, '"');
    r = r.replace(/&apos;/gi, "'");
    r = r.replace(/&#0?39;/g, "'");
    r = r.replace(/&amp;/gi, '&');
    // 逐行规整
    const lines: string[] = r.split('\n');
    const out: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].replace(/[ \t\u00a0\u3000]+/g, ' ').trim();
      if (line.length > 0) {
        out.push(line);
      }
    }
    return out.join('\n');
  }

  /** 读取标签属性值（支持双引号、单引号、无引号） */
  static attr(tagHtml: string, name: string): string {
    const re: RegExp = new RegExp(name + '\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>/]+))', 'i');
    const m: RegExpMatchArray | null = tagHtml.match(re);
    if (m === null) {
      return '';
    }
    if (m[1] !== undefined && m[1] !== null) {
      return m[1];
    }
    if (m[2] !== undefined && m[2] !== null) {
      return m[2];
    }
    if (m[3] !== undefined && m[3] !== null) {
      return m[3];
    }
    return '';
  }

  private static isVoid(tag: string): boolean {
    const t: string = tag.toLowerCase();
    for (let i = 0; i < HtmlLite.VOID_TAGS.length; i++) {
      if (HtmlLite.VOID_TAGS[i] === t) {
        return true;
      }
    }
    return false;
  }

  /** 找标签的结束位置（'>'，跳过引号内的内容） */
  private static endOfTag(html: string, start: number): number {
    let i: number = start;
    let quote: string = '';
    while (i < html.length) {
      const ch: string = html.charAt(i);
      if (quote.length > 0) {
        if (ch === quote) {
          quote = '';
        }
      } else if (ch === '"' || ch === "'") {
        quote = ch;
      } else if (ch === '>') {
        return i;
      }
      i++;
    }
    return -1;
  }

  /** 从 '<' 位置读取标签名 */
  private static tagNameAt(html: string, ltIndex: number): string {
    let i: number = ltIndex + 1;
    let name: string = '';
    while (i < html.length) {
      const ch: string = html.charAt(i);
      if (ch === '/' || ch === '!' || ch === '?') {
        return '';
      }
      if (ch === '>' || ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '/') {
        break;
      }
      name = name + ch;
      i++;
    }
    return name.toLowerCase();
  }

  /**
   * 从某个 '<' 开始，配对取出同标签元素的完整 HTML（含自身）。
   * 使用深度计数，正确处理表格等嵌套标签。
   */
  static extractBalanced(html: string, ltIndex: number, tag: string): string {
    if (tag.length === 0 || HtmlLite.isVoid(tag)) {
      const end: number = HtmlLite.endOfTag(html, ltIndex);
      return end < 0 ? '' : html.substring(ltIndex, end + 1);
    }
    let depth: number = 0;
    let i: number = ltIndex;
    const lower: string = html.toLowerCase();
    const openNeedle: string = '<' + tag;
    const closeNeedle: string = '</' + tag;

    while (i < html.length) {
      const lt: number = lower.indexOf('<', i);
      if (lt < 0) {
        break;
      }
      const gt: number = HtmlLite.endOfTag(html, lt);
      if (gt < 0) {
        break;
      }
      const head: string = lower.substring(lt, Math.min(lower.length, lt + tag.length + 2));
      const isClose: boolean = head.indexOf(closeNeedle) === 0;
      const isOpen: boolean = head.indexOf(openNeedle) === 0;

      if (isClose) {
        depth--;
        if (depth <= 0) {
          return html.substring(ltIndex, gt + 1);
        }
      } else if (isOpen) {
        // 排除 <tableX 这类前缀相同的标签
        const after: string = lower.charAt(lt + openNeedle.length);
        const valid: boolean = after === '' || after === '>' || after === ' ' || after === '\t' ||
          after === '\n' || after === '\r' || after === '/';
        if (valid) {
          const selfClosing: boolean = html.substring(gt - 1, gt + 1) === '/>';
          if (!selfClosing) {
            depth++;
          }
        }
      }
      i = gt + 1;
    }
    return depth > 0 ? html.substring(ltIndex, html.length) : '';
  }

  /** 按 id 找元素 */
  static findById(html: string, id: string): HtmlElement | null {
    const lower: string = html.toLowerCase();
    const needle: string = 'id="' + id.toLowerCase() + '"';
    const needle2: string = "id='" + id.toLowerCase() + "'";
    let at: number = lower.indexOf(needle);
    if (at < 0) {
      at = lower.indexOf(needle2);
    }
    if (at < 0) {
      return null;
    }
    // 回退到标签起始
    let lt: number = at;
    while (lt >= 0 && html.charAt(lt) !== '<') {
      lt--;
    }
    if (lt < 0) {
      return null;
    }
    const tag: string = HtmlLite.tagNameAt(html, lt);
    if (tag.length === 0) {
      return null;
    }
    const outer: string = HtmlLite.extractBalanced(html, lt, tag);
    if (outer.length === 0) {
      return null;
    }
    const openEnd: number = HtmlLite.endOfTag(outer, 0);
    const el: HtmlElement = new HtmlElement();
    el.tag = tag;
    el.attributes = openEnd > 0 ? outer.substring(0, openEnd + 1) : '';
    el.id = HtmlLite.attr(el.attributes, 'id');
    el.cls = HtmlLite.attr(el.attributes, 'class');
    el.outer = outer;
    el.inner = openEnd > 0 ? outer.substring(openEnd + 1, Math.max(openEnd + 1, outer.length - (tag.length + 3))) : '';
    return el;
  }

  /** 取指定标签的所有顶层元素 */
  static findAll(html: string, tag: string): string[] {
    const result: string[] = [];
    const lower: string = html.toLowerCase();
    const needle: string = '<' + tag;
    let i: number = 0;
    while (i < html.length) {
      const at: number = lower.indexOf(needle, i);
      if (at < 0) {
        break;
      }
      const after: string = lower.charAt(at + needle.length);
      const valid: boolean = after === '>' || after === ' ' || after === '\t' || after === '\n' ||
        after === '\r' || after === '/';
      if (!valid) {
        i = at + needle.length;
        continue;
      }
      const outer: string = HtmlLite.extractBalanced(html, at, tag);
      if (outer.length === 0) {
        i = at + needle.length;
        continue;
      }
      result.push(outer);
      i = at + outer.length;
    }
    return result;
  }

  /** 解析一个 <td>/<th> */
  private static parseCell(outer: string): HtmlCell {
    const cell: HtmlCell = new HtmlCell();
    const gt: number = HtmlLite.endOfTag(outer, 0);
    const openTag: string = gt > 0 ? outer.substring(0, gt + 1) : outer;
    cell.openTag = openTag;
    cell.tag = HtmlLite.tagNameAt(outer, 0);
    cell.id = HtmlLite.attr(openTag, 'id');
    cell.cls = HtmlLite.attr(openTag, 'class');
    const cs: string = HtmlLite.attr(openTag, 'colspan');
    const rs: string = HtmlLite.attr(openTag, 'rowspan');
    cell.colspan = cs.length > 0 ? parseInt(cs, 10) : 1;
    cell.rowspan = rs.length > 0 ? parseInt(rs, 10) : 1;
    if (isNaN(cell.colspan) || cell.colspan < 1) {
      cell.colspan = 1;
    }
    if (isNaN(cell.rowspan) || cell.rowspan < 1) {
      cell.rowspan = 1;
    }
    const closeIdx: number = outer.toLowerCase().lastIndexOf('</');
    cell.inner = closeIdx > gt ? outer.substring(gt + 1, closeIdx) : '';
    cell.text = HtmlLite.toText(cell.inner);
    return cell;
  }

  /**
   * 按文档顺序扫描行内的 td/th 单元格。
   *
   * 注意：不能用「先 findAll 再去 indexOf 排序」的做法来自称顺序——
   * 当两行的单元格内容完全相同时（例如成绩页中 序号=2 且 学分=2，
   * 两者都渲染成 <td>2</td>），indexOf 会对两个不同单元格返回同一位置，
   * 排序随即错乱。这里改为从左到右单次扫描，能保证严格顺序。
   */
  private static scanCells(rowHtml: string): HtmlCell[] {
    const cells: HtmlCell[] = [];
    const lower: string = rowHtml.toLowerCase();
    let i: number = 0;
    while (i < rowHtml.length) {
      const td: number = lower.indexOf('<td', i);
      const th: number = lower.indexOf('<th', i);
      let at: number = -1;
      if (td >= 0 && th >= 0) {
        at = td < th ? td : th;
      } else if (td >= 0) {
        at = td;
      } else if (th >= 0) {
        at = th;
      }
      if (at < 0) {
        break;
      }
      // 排除 <tdx 这类前缀相同的标签
      const after: string = lower.charAt(at + 3);
      if (!(after === '>' || after === ' ' || after === '\t' || after === '\n' || after === '\r')) {
        i = at + 3;
        continue;
      }
      const tag: string = lower.substring(at + 1, at + 3) === 'td' ? 'td' : 'th';
      const outer: string = HtmlLite.extractBalanced(rowHtml, at, tag);
      if (outer.length === 0) {
        i = at + 3;
        continue;
      }
      cells.push(HtmlLite.parseCell(outer));
      i = at + outer.length;
    }
    return cells;
  }

  /** 解析一个 <tr> */
  private static parseRow(outer: string): HtmlRow {
    const row: HtmlRow = new HtmlRow();
    row.cells = HtmlLite.scanCells(outer);
    row.text = HtmlLite.toText(outer);
    return row;
  }

  /** 解析一个 <table> */
  static parseTable(outer: string): HtmlTable {
    const table: HtmlTable = new HtmlTable();
    const gt: number = HtmlLite.endOfTag(outer, 0);
    const openTag: string = gt > 0 ? outer.substring(0, gt + 1) : outer;
    table.id = HtmlLite.attr(openTag, 'id');
    table.cls = HtmlLite.attr(openTag, 'class');
    const trs: string[] = HtmlLite.findAll(outer, 'tr');
    for (let i = 0; i < trs.length; i++) {
      table.rows.push(HtmlLite.parseRow(trs[i]));
    }
    return table;
  }

  /** 解析页面中所有表格 */
  static parseTables(html: string): HtmlTable[] {
    const result: HtmlTable[] = [];
    const tables: string[] = HtmlLite.findAll(html, 'table');
    for (let i = 0; i < tables.length; i++) {
      result.push(HtmlLite.parseTable(tables[i]));
    }
    return result;
  }

  /**
   * 找 id 匹配的表格。
   *
   * 注意：不能用 parseTables（它只遍历顶层 table），因为真实页面里
   * 课程设置总表 #mxh 是**嵌套**在 #dataList 内部的子表。
   * 这里直接按 id 定位元素再解析。
   */
  static findTableById(html: string, id: string): HtmlTable | null {
    const el: HtmlElement | null = HtmlLite.findById(html, id);
    if (el === null || el.tag !== 'table') {
      return null;
    }
    return HtmlLite.parseTable(el.outer);
  }

  /** 找表头包含关键字的第一张表格 */
  static findTableByHeader(html: string, keyword: string): HtmlTable | null {
    const tables: HtmlTable[] = HtmlLite.parseTables(html);
    for (let i = 0; i < tables.length; i++) {
      const t: HtmlTable = tables[i];
      for (let r = 0; r < t.rows.length && r < 3; r++) {
        if (t.rows[r].text.indexOf(keyword) >= 0) {
          return t;
        }
      }
    }
    return null;
  }

  /** 读取 select 及其选项 */
  static findSelect(html: string, name: string): HtmlOption[] {
    const result: HtmlOption[] = [];
    const lower: string = html.toLowerCase();
    const needle: string = 'name="' + name.toLowerCase() + '"';
    const at: number = lower.indexOf(needle);
    if (at < 0) {
      return result;
    }
    // 回退找 <select
    let selStart: number = html.toLowerCase().lastIndexOf('<select', at);
    if (selStart < 0) {
      return result;
    }
    const selOuter: string = HtmlLite.extractBalanced(html, selStart, 'select');
    if (selOuter.length === 0) {
      return result;
    }
    const opts: string[] = HtmlLite.findAll(selOuter, 'option');
    for (let i = 0; i < opts.length; i++) {
      const opt: string = opts[i];
      const gt: number = HtmlLite.endOfTag(opt, 0);
      const openTag: string = gt > 0 ? opt.substring(0, gt + 1) : opt;
      const value: string = HtmlLite.attr(openTag, 'value');
      const selected: boolean = /selected/i.test(openTag);
      const inner: string = gt > 0 ? opt.substring(gt + 1, Math.max(gt + 1, opt.toLowerCase().lastIndexOf('</'))) : '';
      const label: string = HtmlLite.toText(inner);
      result.push(new HtmlOption(label.length > 0 ? label : value, value, selected));
    }
    return result;
  }

  /** 读取 input 的 value */
  static findInputValue(html: string, name: string): string {
    const lower: string = html.toLowerCase();
    const re: RegExp = new RegExp('<input[^>]*name\\s*=\\s*["\']?' + name.toLowerCase() + '["\']?[^>]*>', 'i');
    const m: RegExpMatchArray | null = lower.match(re);
    if (m === null || m.length === 0) {
      return '';
    }
    return HtmlLite.attr(m[0], 'value');
  }

  /**
   * 判断页面是否是被踢回登录页。
   *
   * 注意不能只用 name="userAccount" 判断：学生端门户 xsMain.jsp 里有一个供
   * 管理员切换用的 loginForm1，字段名是小写 useraccount（不区分大小写会误判），
   * 且它是登录成功后的正常页面。
   * 这里用「必须有密码输入框」+「有验证码或 encoded 字段」双重条件，
   * 既能识别主门户登录页与 /jsxsd/ 的会话失效页，又不会误判门户首页。
   */
  static isLoginPage(html: string): boolean {
    const hasPassword: boolean = /type\s*=\s*["']password["']/i.test(html);
    if (!hasPassword) {
      return false;
    }
    if (html.indexOf('RANDOMCODE') >= 0 || html.indexOf('SafeCodeImg') >= 0) {
      return true;
    }
    if (html.indexOf('name="encoded"') >= 0 || html.indexOf('id="encoded"') >= 0) {
      return true;
    }
    return false;
  }
}
