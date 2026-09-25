/*
 * AuthRecovery：会话失效后的**恢复决策**（纯逻辑，无 @kit 依赖）
 *
 * 为什么单独抽出来：
 *   这段决策是「登录后到退出登录之间尽量不打扰用户」的全部依据，
 *   但它原本埋在 ReAuthService 里 —— 那个模块要碰 @kit（OCR/密钥库），
 *   在 Node 测试环境里只能被整体替换成桩，于是**决策本身测不到**。
 *   抽成纯函数后，四行真值表可以被直接断言，改动时不会悄悄回归。
 *
 * 为什么这张真值表重要（踩过的坑）：
 *   早先网络层（QzApi.ensureAuthed）一发现登录页就置「等待重新验证」标记，
 *   而它同时服务于**页面首次自动加载**。结果是用户一进某个页面就撞上
 *   「需要重新登录」弹窗 —— 而他可能只是想看一眼本地缓存的课表。
 *   正确行为取决于两个维度：错误是不是会话失效、以及这次请求是不是
 *   用户主动发起的。缺了后一个维度就一定会打扰到人。
 */

/** 会话续期后的处置结果 */
export enum AuthRecovery {
  /** 不是会话失效类错误，页面按普通错误处理 */
  NONE = 0,
  /** 已静默续期成功，页面应重新加载数据 */
  RENEWED = 1,
  /**
   * 续期失败，但这次请求**不是用户主动发起的**（页面自动首次加载），
   * 因此既不弹窗也不置标记 —— 页面显示一句内联提示即可。
   */
  DEFERRED = 2,
  /** 续期失败，且是用户主动操作 → 置标记，弹窗出现 */
  NEED_MANUAL = 3
}

export class AuthRecoveryDecider {
  /**
   * 决定如何处理一次请求失败。
   *
   * @param authExpired 该错误是否为「会话失效」（AppError.kind === AUTH_EXPIRED）
   * @param renewed     静默续期（已保存账号密码 + OCR 自动登录）是否成功
   * @param interactive 本次请求是否为用户主动发起
   *                    （点了重试 / 切学期 / 查空教室…；页面首次自动加载为 false）
   */
  static decide(authExpired: boolean, renewed: boolean, interactive: boolean): AuthRecovery {
    if (!authExpired) {
      return AuthRecovery.NONE;
    }
    if (renewed) {
      return AuthRecovery.RENEWED;
    }
    return interactive ? AuthRecovery.NEED_MANUAL : AuthRecovery.DEFERRED;
  }

  /** 该结果是否要求页面重新加载数据 */
  static shouldReload(r: AuthRecovery): boolean {
    return r === AuthRecovery.RENEWED;
  }

  /** 该结果是否应该置「等待重新验证」标记（即是否弹窗） */
  static shouldPopup(r: AuthRecovery): boolean {
    return r === AuthRecovery.NEED_MANUAL;
  }

  /** 该结果下页面应显示的内联提示（空串表示不显示） */
  static inlineHint(r: AuthRecovery): string {
    return r === AuthRecovery.DEFERRED
      ? '登录状态已过期，重新加载即可自动登录'
      : '';
  }
}