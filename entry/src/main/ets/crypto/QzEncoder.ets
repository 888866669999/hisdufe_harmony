/*
 * 强智教务登录加密：与门户 login() 完全一致的 encoded 生成逻辑
 *
 * 流程：
 *   1. POST /Logon.do?method=logon&flag=sess  ->  返回 "scode#sxh"
 *   2. sxh 为 20 位数字串，scode 为一串随机字符
 *   3. 拼出 code = 账号 + "%%%" + 密码
 *   4. 对 i < 20：把 code 的第 i 个字符，与从 scode 头部按 sxh[i] 长度截取的片段一起追加，并从 scode 中移除该片段
 *      对 i >= 20：直接把 code 剩余部分整体追加
 *   5. 结果作为 encoded 字段提交
 */

export class QzEncoder {
  /**
   * 由会话串构造 encoded 参数。
   * @param sessText 形如 "scode#sxh" 的服务端返回
   * @param account 学号
   * @param password 密码
   * @returns encoded 字符串；若会话串非法则返回空串
   */
  static buildEncoded(sessText: string, account: string, password: string): string {
    if (sessText.length === 0) {
      return '';
    }
    const parts: string[] = sessText.split('#');
    if (parts.length < 2) {
      return '';
    }
    let scode: string = parts[0];
    const sxh: string = parts[1];
    if (scode.length === 0 || sxh.length < 20) {
      return '';
    }

    const code: string = account + '%%%' + password;
    let encoded: string = '';

    for (let i = 0; i < code.length; i++) {
      if (i < 20) {
        const take: number = parseInt(sxh.substring(i, i + 1), 10);
        if (isNaN(take) || take < 0) {
          return '';
        }
        let piece: string = '';
        if (take > 0) {
          piece = scode.substring(0, take);
          scode = scode.substring(take, scode.length);
        }
        encoded = encoded + code.substring(i, i + 1) + piece;
      } else {
        encoded = encoded + code.substring(i, code.length);
        break;
      }
    }
    return encoded;
  }

  /** 服务端在会话不可用时返回 "no" */
  static isRejected(sessText: string): boolean {
    return sessText.trim() === 'no';
  }
}
