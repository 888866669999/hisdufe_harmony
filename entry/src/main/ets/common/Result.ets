/*
 * 统一的错误/结果模型
 */

/** 业务错误类型 */
export enum ErrKind {
  NONE = 0,
  NETWORK = 1,
  AUTH_EXPIRED = 2,
  CAPTCHA = 3,
  BAD_CREDENTIALS = 4,
  PARSE = 5,
  SERVER = 6,
  UNKNOWN = 7
}

export class AppError extends Error {
  kind: ErrKind;
  detail: string;

  constructor(kind: ErrKind, message: string, detail: string = '') {
    super(message);
    this.kind = kind;
    this.detail = detail;
  }

  /** 面向用户的中文提示 */
  toUserText(): string {
    switch (this.kind) {
      case ErrKind.NETWORK:
        return '网络连接失败，请检查网络后重试';
      case ErrKind.AUTH_EXPIRED:
        return '登录状态已失效，请重新登录';
      case ErrKind.CAPTCHA:
        return '验证码错误，请重新输入';
      case ErrKind.BAD_CREDENTIALS:
        return '账号或密码错误';
      case ErrKind.PARSE:
        return '数据解析失败，教务系统可能已改版';
      case ErrKind.SERVER:
        return '教务系统响应异常，请稍后重试';
      default:
        return this.message.length > 0 ? this.message : '发生未知错误';
    }
  }

  /**
   * 把「任意抛出物」安全地转成用户可读文本。
   *
   * 为什么必须有这个函数：
   *   页面里原本统一写 `const err = e as AppError; err.toUserText()`。
   *   但 `as` 只是类型断言，**不做运行时检查**；一旦抛出的是原生错误
   *   （TypeError / SyntaxError，或底层 HMS 抛出的普通对象），
   *   `err.toUserText` 就是 undefined，调用它会**在 catch 块里再抛一次**，
   *   变成未处理的 Promise 异常 —— 页面白屏甚至崩溃。
   *   这里显式判别类型，任何抛出物都能得到一个可显示的字符串。
   */
  static describe(e: Object): string {
    if (e instanceof AppError) {
      return (e as AppError).toUserText();
    }
    if (e !== null && e !== undefined) {
      const err: Error = e as Error;
      // 原生错误没有 kind，直接回显 message 更利于定位问题
      if (err.message !== undefined && err.message !== null && err.message.length > 0) {
        return err.message;
      }
      try {
        return String(e);
      } catch (inner) {
        // 连字符串化都失败时走兜底
      }
    }
    return '发生未知错误';
  }

  /**
   * 该异常是否由「会话失效」引起。
   *
   * 用途：会话失效时不应该在页面里显示错误 —— 那是「重新登录」弹窗负责的事。
   * 页面若同时渲染一个错误视图，弹窗背后会露出「登录状态已失效」的报错，
   * 显得像是两条互相冲突的提示。页面据此跳过错误态即可。
   */
  static isAuthExpired(e: Object): boolean {
    return e instanceof AppError && (e as AppError).kind === ErrKind.AUTH_EXPIRED;
  }
}
