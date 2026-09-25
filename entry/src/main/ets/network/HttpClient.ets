/*
 * HttpClient：基于 @kit.NetworkKit 的 http 模块
 *
 * 负责：GET/POST、form 编码、超时、Cookie 自动回填、错误归类。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { CookieJar } from './CookieJar';
import { AppError, ErrKind } from '../common/Result';
import { Logger } from '../common/Logger';
import { UrlGuard } from '../common/UrlGuard';
import { HTTP_CONNECT_TIMEOUT, HTTP_READ_TIMEOUT } from '../common/Constants';

/** HTTP 响应 */
export class HttpResponse {
  status: number = 0;
  body: string = '';
  /** 最终地址（跟随重定向后） */
  finalUrl: string = '';
  /** 响应头 map（用于取 location 等） */
  headers: Map<string, string> = new Map<string, string>();

  /** 取响应头（大小写不敏感） */
  header(name: string): string {
    const direct: string | undefined = this.headers.get(name);
    if (direct !== undefined) {
      return direct;
    }
    const lower: string = name.toLowerCase();
    const keys: string[] = Array.from(this.headers.keys());
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() === lower) {
        const v: string | undefined = this.headers.get(keys[i]);
        return v === undefined ? '' : v;
      }
    }
    return '';
  }
}

/** 表单键值对 */
export class FormField {
  name: string;
  value: string;

  constructor(name: string, value: string) {
    this.name = name;
    this.value = value;
  }
}

export class HttpClient {
  private jar: CookieJar;
  private userAgent: string =
    'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36';

  constructor(jar: CookieJar) {
    this.jar = jar;
  }

  cookieJar(): CookieJar {
    return this.jar;
  }

  /** URL 编码表单 */
  static encodeForm(fields: FormField[]): string {
    const parts: string[] = [];
    for (let i = 0; i < fields.length; i++) {
      const f: FormField = fields[i];
      parts.push(encodeURIComponent(f.name) + '=' + encodeURIComponent(f.value));
    }
    return parts.join('&');
  }

  async get(url: string): Promise<HttpResponse> {
    return await this.send(http.RequestMethod.GET, url, '', '');
  }

  async postForm(url: string, fields: FormField[]): Promise<HttpResponse> {
    return await this.send(http.RequestMethod.POST, url, HttpClient.encodeForm(fields),
      'application/x-www-form-urlencoded');
  }

  /** 抓取二进制（用于验证码图片） */
  async getBinary(url: string): Promise<ArrayBuffer> {
    return await this.fetchBinary(url, 'image/*,*/*;q=0.8', '验证码获取失败');
  }

  /**
   * 通用二进制下载（验证码、PDF 等）。
   * 与 getBinary 的区别：会校验 HTTP 状态码，并允许自定义 Accept 与错误文案。
   */
  async fetchBinary(url: string, accept: string, failMessage: string): Promise<ArrayBuffer> {
    // SSRF 防护：这些地址可能来自**远端页面解析结果**（培养方案的附件路径），
    // 属不可信输入。发请求前必须校验协议与主机，
    // 拒绝 localhost / 环回 / 私有 / 保留地址（见 UrlGuard）。
    try {
      UrlGuard.check(url);
    } catch (e) {
      Logger.warn('binary fetch blocked by UrlGuard: ' + url);
      throw new AppError(ErrKind.SERVER, failMessage, 'URL 被安全策略拒绝');
    }
    const req: http.HttpRequest = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'User-Agent': this.userAgent,
        'Accept': accept,
        // 与页面请求一致：部分接口会校验来源
        'Origin': HttpClient.originOf(url),
        'Referer': HttpClient.originOf(url) + '/'
      };
      const cookie: string = this.jar.toHeader();
      if (cookie.length > 0) {
        headers['Cookie'] = cookie;
      }
      const res: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: HTTP_CONNECT_TIMEOUT,
        readTimeout: HTTP_READ_TIMEOUT,
        // 同上：验证码/PDF 这类二进制内容绝不能命中缓存
        usingCache: false,
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      });
      this.absorbCookies(res);
      if (res.responseCode >= 400) {
        Logger.warn('binary fetch http ' + res.responseCode + ' url=' + url);
        throw new AppError(ErrKind.SERVER, failMessage, 'http=' + res.responseCode);
      }
      const data: ArrayBuffer | string = res.result as ArrayBuffer | string;
      if (data instanceof ArrayBuffer) {
        return data;
      }
      return new ArrayBuffer(0);
    } catch (e) {
      if (e instanceof AppError) {
        throw e;
      }
      const err: BusinessError = e as BusinessError;
      Logger.error('binary fetch failed: ' + err.code);
      throw new AppError(ErrKind.NETWORK, failMessage, 'code=' + err.code);
    } finally {
      req.destroy();
    }
  }

  /**
   * 吸收响应里的 cookie。
   *
   * 重要：HarmonyOS 的 http 模块返回的 `res.cookies` 不是标准 Set-Cookie 文本，
   * 实测是 Netscape cookie 文件格式，字段以 TAB 分隔：
   *   #HttpOnly_jw.sdufe.edu.cn \t FALSE \t / \t FALSE \t 0 \t JSESSIONID \t AFE48128...
   * 即：域 \t 包含子域 \t 路径 \t 安全 \t 过期 \t 名称 \t 值
   * 且 HttpOnly 会被写成域名前缀 "#HttpOnly_"。
   * 早期版本也可能返回 "name=value; name2=value2" 形式，因此两者都兼容。
   */
  private absorbCookies(res: http.HttpResponse): void {
    let raw: string = '';
    try {
      const v: string = res.cookies;
      if (v !== undefined && v !== null) {
        raw = v;
      }
    } catch (e) {
      Logger.warn('cookies field unavailable');
      return;
    }
    if (raw.length === 0) {
      return;
    }

    // 统一换行，便于按行处理
    const normalized: string = raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/,(?=[^;=\s]+\t)/g, '\n');
    const lines: string[] = normalized.split('\n');
    let absorbed: number = 0;

    for (let i = 0; i < lines.length; i++) {
      let line: string = lines[i];
      if (line.length === 0) {
        continue;
      }
      // HttpOnly 前缀会粘在域名前
      line = line.replace(/#HttpOnly_/g, '');

      if (line.indexOf('\t') >= 0) {
        // Netscape 格式：取 名称(5) 与 值(6)
        const parts: string[] = line.split('\t');
        if (parts.length >= 7) {
          const name: string = parts[5].trim();
          const value: string = parts[6].trim();
          if (name.length > 0) {
            this.jar.set(name, value);
            absorbed++;
          }
        }
        continue;
      }

      // 兼容 "name=value; Path=/; HttpOnly" 形式
      if (line.indexOf('=') > 0) {
        this.jar.absorbOne(line.trim());
        absorbed++;
      }
    }
    // 用脱敏摘要而不是 toHeader()：后者会把 JSESSIONID 原文写进系统日志，
    // 而那是「持有即可用」的凭据（见 CookieJar.toLogSummary 的说明）。
    Logger.info('cookies absorbed=' + absorbed + ' jar=[' + this.jar.toLogSummary() + ']');
  }

  private async send(method: http.RequestMethod, url: string, body: string, contentType: string): Promise<HttpResponse> {
    const req: http.HttpRequest = http.createHttp();
    try {
      const origin: string = HttpClient.originOf(url);
      const headers: Record<string, string> = {
        'User-Agent': this.userAgent,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        // 与门户页面一致：服务器可能校验来源，缺失时返回 404
        'Origin': origin,
        'Referer': origin + '/'
      };
      if (contentType.length > 0) {
        headers['Content-Type'] = contentType;
      }
      const cookie: string = this.jar.toHeader();
      if (cookie.length > 0) {
        headers['Cookie'] = cookie;
      }

      const options: http.HttpRequestOptions = {
        method: method,
        header: headers,
        connectTimeout: HTTP_CONNECT_TIMEOUT,
        readTimeout: HTTP_READ_TIMEOUT,
        // 显式关闭 HTTP 缓存。默认值是 true，会让 GET 命中旧响应：
        // 最危险的是 isSessionAlive 可能读到「缓存的旧主页」而误判会话仍有效，
        // 也可能让成绩/课表拿到陈旧数据。
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      };
      if (body.length > 0) {
        options.extraData = body;
      }

      const res: http.HttpResponse = await req.request(url, options);
      this.absorbCookies(res);

      const out: HttpResponse = new HttpResponse();
      out.status = res.responseCode;
      const raw: string | Object | ArrayBuffer = res.result as string | Object | ArrayBuffer;
      out.body = typeof raw === 'string' ? raw : JSON.stringify(raw);
      out.finalUrl = url;
      out.headers = HttpClient.toHeaderMap(res.header);

      // 重定向或非成功状态时打印响应头，便于定位服务器侧行为。
      // 必须带上 URL：多个业务页面共用这一处日志，缺了 URL 就只能看到
      // 「某个请求 404 了」，无法判断是哪个接口。
      if (out.status >= 300 || out.header('location').length > 0) {
        Logger.info('http ' + out.status + ' url=' + url +
          ' location=[' + out.header('location') + ']');
      }
      // 4xx/5xx 一定是异常路径：把响应体开头打出来。
      // 强智的错误页正文往往写明原因（如「会话已失效」「参数缺失」），
      // 只看状态码会把它误判成普通服务端故障。
      if (out.status >= 400 && out.body.length > 0) {
        Logger.warn('http ' + out.status + ' body=' +
          out.body.substring(0, 240).replace(/\s+/g, ' '));
      }
      return out;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error('http request failed: ' + err.code + ' ' + err.message);
      throw new AppError(ErrKind.NETWORK, '网络请求失败', 'code=' + err.code);
    } finally {
      req.destroy();
    }
  }

  /**
   * 把 http 响应的 header 转成 Map。
   * ArkTS 不允许动态属性访问，因此通过 JSON 序列化后解析，键值统一去引号。
   */
  private static toHeaderMap(header: Object): Map<string, string> {
    const map: Map<string, string> = new Map<string, string>();
    try {
      const json: string = JSON.stringify(header);
      if (json === undefined || json === null || json.length < 3) {
        return map;
      }
      const inner: string = json.substring(1, json.length - 1);
      const pairs: string[] = inner.split(',"');
      for (let i = 0; i < pairs.length; i++) {
        let seg: string = pairs[i];
        // 还原被 split 切掉的引号
        if (i > 0) {
          seg = '"' + seg;
        }
        const colon: number = seg.indexOf('":');
        if (colon <= 0) {
          continue;
        }
        const key: string = seg.substring(seg.charAt(0) === '"' ? 1 : 0, colon);
        let value: string = seg.substring(colon + 2).trim();
        if (value.length >= 2 && value.charAt(0) === '"' && value.charAt(value.length - 1) === '"') {
          value = value.substring(1, value.length - 1);
        }
        map.set(key, value);
      }
    } catch (e) {
      Logger.warn('parse response header failed');
    }
    return map;
  }

  /** 取 URL 的 origin，如 http://jw.sdufe.edu.cn */
  private static originOf(url: string): string {
    const schemeEnd: number = url.indexOf('://');
    if (schemeEnd < 0) {
      return url;
    }
    const pathStart: number = url.indexOf('/', schemeEnd + 3);
    return pathStart < 0 ? url : url.substring(0, pathStart);
  }
}
