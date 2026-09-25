/*
 * ReAuthService：会话失效后的「重新验证」流程
 *
 * ===== 为什么需要它 =====
 * 教务系统的会话（JSESSIONID）会在服务端过期。原做法是直接清掉本地会话、
 * 把用户丢回登录页，用户得重走「账号 → 密码 → 验证码」三步 —— 但账号密码
 * 明明已经存在系统密钥库里，只有验证码是每次必须新的。
 *
 * 现在的流程：
 *   1. 有凭据时业务请求遇到登录页 → 只置「等待重新验证」标记，不退出登录，
 *      界面弹出居中的验证码弹窗（原本的页面与浏览位置保持不变）；
 *   2. 弹窗里优先尝试**自动登录**：拉一张验证码，用系统 OCR 识别后直接提交，
 *      成功即静默续期，用户无感；
 *   3. OCR 不可用（设备无该能力）或识别失败 → 降级为手动输入验证码。
 *
 * ===== OCR 为什么用动态 import =====
 * OCR 能力（SystemCapability.AI.OCR.TextRecognition）在部分设备/模拟器上不存在。
 * 本应用踩过静态导入缺失 HMS 导出导致模块加载期硬崩的坑（见 README 的 PDF 闪退一节），
 * 因此这里先 canIUse 探测，只有确认支持才 `await import()` 加载 OcrProbe，
 * 让「不支持」成为可捕获的降级路径，而不是让整个模块图崩掉。
 */
import { AppState } from './AppState';
import { CredentialStore, Credential } from './CredentialStore';
import { Logger } from '../common/Logger';
import { ContextHolder } from '../common/ContextHolder';
import { AppError } from '../common/Result';
import { AuthRecovery, AuthRecoveryDecider } from '../common/AuthRecovery';
import { LoginFailKind } from '../network/QzApi';
import { util } from '@kit.ArkTS';
import {
  AS_HAS_CREDENTIAL, AS_REAUTH_PENDING, AS_LOGGED_IN
} from '../common/Constants';

/** OCR 能力标识 */
const OCR_SYSCAP: string = 'SystemCapability.AI.OCR.TextRecognition';

/**
 * 交互路径的登录提交次数上限。
 *
 * 取 3 的依据：OCR 单次识别正确率有限，但「换一张图」几乎总能换到一张
 * 识别正确的；同时 3 次仍是很小的 POST 量，不至于把账号打到临时锁定。
 * 静默路径不适用此值（固定 1 次）。
 */
export const MAX_LOGIN_ATTEMPTS: number = 3;

/** 自动登录的结果 */
export class AutoLoginOutcome {
  ok: boolean = false;
  /** 失败原因；成功时为空 */
  reason: string = '';
  /** 是否因为设备不支持 OCR 而失败（界面据此直接给手动输入，不显示"重试"） */
  ocrUnavailable: boolean = false;
  /** 尝试识别出的验证码（便于排查；成功时即实际使用的那串） */
  triedCaptcha: string = '';
  /**
   * 本次 OCR 所用的**同一张**验证码图的 dataUri。
   *
   * 为什么必须带着这张图：早先弹窗在识别失败时会「预填 OCR 文本 + 另取一张新图」，
   * 预填内容与所见图必然不一致，用户直接提交必然失败 —— 会被误认为「OCR 不行」。
   * 现在把图文一起给出，用户只需改错的那一位。
   * 为空表示没有可用图片（例如根本没走到取图步骤）。
   */
  captchaImage: string = '';
  /** 已消耗的登录提交次数（重试时让界面能如实说明） */
  attempts: number = 0;
  /** 失败类别（供重试决策；成功时为 NONE） */
  failKind: LoginFailKind = LoginFailKind.NONE;

  constructor(ok: boolean, reason: string, ocrUnavailable: boolean, triedCaptcha: string) {
    this.ok = ok;
    this.reason = reason;
    this.ocrUnavailable = ocrUnavailable;
    this.triedCaptcha = triedCaptcha;
  }
}

export class ReAuthService {
  /**
   * 正在进行的自动登录尝试。
   *
   * 为什么必须去重：有两处会触发无感续期 —— 启动时的
   * `Index.trySilentRenewal` 和前台会话保活 `SessionKeepAlive`。
   * 若它们同时发现会话失效，会各自去取验证码、各自提交一次登录：
   * 两次登录共用同一个 JSESSIONID，后一次必然把前一次的验证码作废，
   * 结果是「两次都失败」，白白多打两轮请求。
   * 让并发调用共享同一个 Promise，只发出一次真实的登录尝试。
   */
  private static autoLoginInFlight: Promise<AutoLoginOutcome> | null = null;

  /** 本设备是否具备端上推理能力（只探测 syscap，不加载模块） */
  static modelAvailable(): boolean {
    try {
      return canIUse('SystemCapability.AI.MindSporeLite');
    } catch (e) {
      return false;
    }
  }

  /** 本设备是否具备 OCR 能力（只探测 syscap，不加载模块） */
  static ocrAvailable(): boolean {
    try {
      return canIUse(OCR_SYSCAP);
    } catch (e) {
      return false;
    }
  }

  /** 是否正在等待重新验证 */
  static isPending(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>(AS_REAUTH_PENDING);
    return v === true;
  }

  /** 标记需要重新验证 */
  static markPending(): void {
    AppStorage.setOrCreate(AS_REAUTH_PENDING, true);
  }

  /** 取消「等待验证」（用户手动关闭弹窗，或验证成功） */
  static clearPending(): void {
    AppStorage.setOrCreate(AS_REAUTH_PENDING, false);
  }

  /** 同步「是否已保存凭据」到 AppStorage（供 QzApi 同步判断） */
  static async refreshCredentialFlag(): Promise<boolean> {
    const has: boolean = await CredentialStore.exists();
    AppStorage.setOrCreate(AS_HAS_CREDENTIAL, has);
    return has;
  }

  static setCredentialFlag(has: boolean): void {
    AppStorage.setOrCreate(AS_HAS_CREDENTIAL, has);
  }

  /**
   * 页面捕获到「会话失效」错误时统一调用：**先静默续期，失败才决定要不要弹窗**。
   *
   * 这是「登录后到退出登录之间尽量不打扰用户」的关键落点。两个必须区分的场景：
   *
   *   - `interactive = false`（页面首次自动加载，例如刚切到某页）：
   *     续期失败也**不弹窗、不置标记**，只让页面给一句内联提示。
   *     否则用户一进页面就撞上一个登录框 —— 而他可能只是想看看缓存数据。
   *   - `interactive = true`（用户点了重试/切学期/查询空教室等）：
   *     续期失败才置标记，弹窗出现。这时用户正在等结果，弹窗是恰当的。
   *
   * 自动路径同时受「刚失败过就跳过」的限制，避免一次启动内连打两轮登录请求。
   *
   * @returns true = 已续期成功，页面应重新加载数据
   */
  static async recoverIfExpired(e: Object, interactive: boolean): Promise<boolean> {
    // 决策规则集中在 AuthRecoveryDecider（纯逻辑、有单测）：
    // 「错误类型 × 是否续期成功 × 是否用户主动」→ 该重载 / 该弹窗 / 该安静。
    if (!AppError.isAuthExpired(e)) {
      return AuthRecoveryDecider.shouldReload(AuthRecovery.NONE);
    }
    const out: AutoLoginOutcome = await ReAuthService.tryAutoLogin();
    const decision: AuthRecovery =
      AuthRecoveryDecider.decide(true, out.ok, interactive);
    if (out.ok) {
      Logger.info('session renewed silently');
      ReAuthService.clearPending();
    } else {
      Logger.info('silent renewal failed: ' + out.reason);
      if (AuthRecoveryDecider.shouldPopup(decision)) {
        ReAuthService.markPending();
      }
    }
    return AuthRecoveryDecider.shouldReload(decision);
  }

  /**
   * 尝试静默自动登录：拉验证码 → OCR 识别 → 提交登录。
   *
   * 只在设备支持 OCR 时才会真正加载 OCR 模块；否则立即返回
   * `ocrUnavailable=true`，由界面直接进入手动输入。
   *
   * 这里的重试次数是 1（即不重试）：它服务于启动静默续期这类
   * 「用户没在等」的场景，多次 POST 既无必要也有锁定风险。
   * 用户交互路径请用 `autoLoginWithRetry()`。
   */
  static async tryAutoLogin(): Promise<AutoLoginOutcome> {
    // 并发调用共享同一次尝试（见 autoLoginInFlight 的说明）
    if (ReAuthService.autoLoginInFlight !== null) {
      return await ReAuthService.autoLoginInFlight;
    }
    ReAuthService.autoLoginInFlight = ReAuthService.doAutoLogin(1);
    try {
      return await ReAuthService.autoLoginInFlight;
    } finally {
      ReAuthService.autoLoginInFlight = null;
    }
  }

  /**
   * 交互路径的自动登录：识别失败或服务端判「验证码错」时，
   * 换一张图重试，累计提交次数不超过 MAX_LOGIN_ATTEMPTS。
   *
   * ===== 为什么只在验证码类失败上重试 =====
   * 每次重试都是「取一张新验证码 + POST 一次登录」。若把账号/密码错
   * 也当成可重试，就会拿错误的凭据反复 POST，有把账号打到临时锁定的风险。
   * 因此这里只对两种可恢复情况重试：
   *   - OCR 没能给出 4 位结果（压根没提交，或提交的必然不对）；
   *   - 服务端明确回「验证码」类错误（`LoginFailKind.CAPTCHA`）。
   * 其余（凭据错、被拒、未知）立即停止并如实回报。
   */
  static async autoLoginWithRetry(maxAttempts: number): Promise<AutoLoginOutcome> {
    if (ReAuthService.autoLoginInFlight !== null) {
      return await ReAuthService.autoLoginInFlight;
    }
    ReAuthService.autoLoginInFlight = ReAuthService.doAutoLogin(maxAttempts);
    try {
      return await ReAuthService.autoLoginInFlight;
    } finally {
      ReAuthService.autoLoginInFlight = null;
    }
  }

  /**
   * 真正的自动登录动作；只应由 tryAutoLogin / autoLoginWithRetry 调用（它们负责去重）。
   *
   * @param maxAttempts 最多提交几次登录（取值 >= 1）
   */
  private static async doAutoLogin(maxAttempts: number): Promise<AutoLoginOutcome> {
    // 端上模型或系统 OCR 有其一即可自动识别
    if (!ReAuthService.modelAvailable() && !ReAuthService.ocrAvailable()) {
      return new AutoLoginOutcome(false, '本机不支持自动识别验证码', true, '');
    }
    const cred: Credential | null = await CredentialStore.load();
    if (cred === null || cred.account.length === 0 || cred.password.length === 0) {
      return new AutoLoginOutcome(false, '没有可用的已保存账号密码', false, '');
    }

    const limit: number = maxAttempts < 1 ? 1 : maxAttempts;
    let last: AutoLoginOutcome | null = null;

    for (let attempt = 1; attempt <= limit; attempt++) {
      // 取验证码原图：识别与「失败时展示同一张图」都用它
      let jpeg: ArrayBuffer;
      try {
        jpeg = await AppState.apiInstance().fetchCaptcha();
      } catch (e) {
        return new AutoLoginOutcome(false, '无法获取验证码，请检查网络', false, '');
      }
      if (jpeg.byteLength === 0) {
        return new AutoLoginOutcome(false, '验证码为空，请重试', false, '');
      }
      const imageUri: string = ReAuthService.toDataUri(jpeg);

      // 识别：与登录页/重登弹窗共用同一条「模型优先、通用 OCR 兜底」路径。
      // 早先这里只调通用 OCR（实测约 42%），而端上模型约 92%，
      // 白白让静默续期成功率低了五个百分点。
      let code: string = '';
      try {
        const ctx = ContextHolder.get();
        const solved: CaptchaSolve | null =
          ctx === null ? null : await ReAuthService.solveCaptcha(ctx);
        if (solved === null || !solved.ocrOk) {
          const reason: string = solved === null ? '无法获取验证码' : solved.reason;
          Logger.warn('auto login captcha unsolved: ' + reason);
          last = new AutoLoginOutcome(false, '验证码识别失败，请手动输入', false,
            solved === null ? '' : solved.text);
          last.captchaImage = imageUri;
          last.attempts = attempt;
          // 识别不出 → 换一张再试（这是可恢复失败）
          continue;
        }
        code = solved.text;
      } catch (e) {
        const msg: string = ReAuthService.errText(e);
        Logger.warn('captcha solve failed: ' + msg);
        return new AutoLoginOutcome(false, '自动识别不可用，请手动输入', true, '');
      }

      const res: AutoLoginOutcome = await ReAuthService.loginWith(cred.account, cred.password, code);
      res.captchaImage = imageUri;
      res.attempts = attempt;
      if (res.ok) {
        return res;
      }
      last = res;
      // 只有验证码类的失败才值得换图重试
      if (res.failKind !== LoginFailKind.CAPTCHA) {
        Logger.info('auto login stopped: non-captcha failure');
        return res;
      }
      Logger.info('auto login retry after captcha error, attempt=' + attempt.toString());
    }

    if (last === null) {
      return new AutoLoginOutcome(false, '自动识别不可用，请手动输入', false, '');
    }
    // 重试到上限仍失败：把原因讲清楚，避免用户以为是「一下就失败」
    if (last.failKind === LoginFailKind.CAPTCHA || last.triedCaptcha.length === 0) {
      const msg: string = limit > 1
        ? ('连续 ' + limit.toString() + ' 次自动识别均未通过，请手动输入')
        : last.reason;
      const out: AutoLoginOutcome = new AutoLoginOutcome(false, msg, false, last.triedCaptcha);
      out.captchaImage = last.captchaImage;
      out.attempts = last.attempts;
      return out;
    }
    return last;
  }

  /** JPEG 字节 → data:image/jpeg;base64,...（供界面直接显示同一张图） */
  private static toDataUri(jpeg: ArrayBuffer): string {
    try {
      const helper: util.Base64Helper = new util.Base64Helper();
      const b64: string = helper.encodeToStringSync(new Uint8Array(jpeg));
      return 'data:image/jpeg;base64,' + b64;
    } catch (e) {
      return '';
    }
  }

  /** 用指定验证码登录（手动输入与 OCR 共用同一条提交路径） */
  static async loginWith(account: string, password: string, captcha: string): Promise<AutoLoginOutcome> {
    try {
      const res = await AppState.apiInstance().login(account, password, captcha);
      if (!res.success) {
        const out: AutoLoginOutcome = new AutoLoginOutcome(false, res.message, false, captcha);
        out.failKind = res.kind;
        return out;
      }
      ReAuthService.clearPending();
      AppStorage.setOrCreate(AS_LOGGED_IN, true);
      await AppState.onLoggedIn(account);
      Logger.info('reauth succeeded');
      return new AutoLoginOutcome(true, '', false, captcha);
    } catch (e) {
      const out: AutoLoginOutcome = new AutoLoginOutcome(false, ReAuthService.errText(e), false, captcha);
      // 网络/未知异常：归为不可重试，避免把网络抖动放大成连续登录 POST
      out.failKind = LoginFailKind.UNKNOWN;
      return out;
    }
  }

  /**
   * 手动输入的登录入口：用保存的凭据 + 用户输入的验证码。
   * 与 OCR 路径共用 loginWith，保证两条路径行为一致。
   */
  static async loginWithSaved(account: string, password: string,
    captcha: string): Promise<AutoLoginOutcome> {
    return await ReAuthService.loginWith(account, password, captcha);
  }

  /** 取一张新的验证码图片（base64 data URI），同时返回原始字节供 OCR 复用 */
  static async fetchCaptchaImage(): Promise<CaptchaImage | null> {
    try {
      const buf: ArrayBuffer = await AppState.apiInstance().fetchCaptcha();
      if (buf.byteLength === 0) {
        return null;
      }
      const helper: util.Base64Helper = new util.Base64Helper();
      const b64: string = helper.encodeToStringSync(new Uint8Array(buf));
      return new CaptchaImage('data:image/jpeg;base64,' + b64, buf);
    } catch (e) {
      Logger.warn('fetch captcha image failed');
      return null;
    }
  }

  /**
   * 取一张验证码并自动识别（**登录与重登共用的唯一入口**）。
   *
   * ===== 为什么要抽这一个方法 =====
   * 「需要图片验证码」的场景有三处：首次登录、会话失效后重登、静默续期。
   * 三处的动作完全相同（取图 → 识别 → 把结果填进输入框），
   * 抽出来才能保证识别优先级与失败降级行为完全一致。
   *
   * ===== 识别优先级 =====
   *   1. **端上训练模型**（`CaptchaModel`，ddddocr）：实测约 92%；
   *   2. 兜底用系统通用 OCR（`OcrProbe`）：实测只有约 42%，
   *      仅在模型不可用（设备不支持端上推理 / 模型加载失败）时才走。
   *
   * 返回 null 表示**连图都没取到**（网络问题），调用方应提示重试；
   * 取到图但识别失败时返回的对象 `ocrOk=false`，调用方应让用户手输。
   *
   * @param ctx 应用上下文（读取内置模型需要）
   */
  static async solveCaptcha(ctx: Object): Promise<CaptchaSolve | null> {
    const img: CaptchaImage | null = await ReAuthService.fetchCaptchaImage();
    if (img === null) {
      return null;
    }

    // 1) 优先用训练模型。
    //
    // 这里**必须动态 import**，不能静态导入 CaptchaModel：
    // 它静态依赖 `@kit.MindSporeLiteKit`，而端上推理能力在部分设备上并不存在。
    // 静态导入会让本文件（进而让所有引用它的页面）在不支持该能力的设备上
    // 于模块加载期直接失败 —— 本仓库的 PDF 闪退就是同类问题。
    // 因此先 canIUse 探测，确认支持才加载，让「不支持」成为可降级路径。
    if (ReAuthService.modelAvailable()) {
      try {
        const mod = await import('./CaptchaModel');
        const out = await mod.CaptchaModel.recognize(img.raw, ctx);
        if (out.ok && out.text.length > 0) {
          return new CaptchaSolve(img, out.text, true, '');
        }
        Logger.warn('model captcha failed: ' + out.reason);
      } catch (e) {
        Logger.warn('model captcha error');
      }
    }

    // 2) 兜底：系统通用 OCR（准确率低，仅当模型不可用时）
    if (ReAuthService.ocrAvailable()) {
      try {
        const mod = await import('./OcrProbe');
        const outcome = await mod.OcrProbe.recognizeCaptcha(img.raw, 3);
        if (outcome.ok && outcome.text.length > 0) {
          return new CaptchaSolve(img, outcome.text, true, '');
        }
        Logger.warn('ocr captcha failed: ' + outcome.reason);
      } catch (e) {
        Logger.warn('ocr module load failed');
      }
    }

    // 图取到了，但两条识别路径都没成功 → 交给用户手动输入
    return new CaptchaSolve(img, '', false, '未能自动识别，请手动输入');
  }

  /** 彻底退出：清会话并回登录页 */
  static async giveUp(): Promise<void> {
    ReAuthService.clearPending();
    await AppState.forceLogout();
  }

  private static errText(e: Object): string {
    if (e instanceof AppError) {
      return (e as AppError).toUserText();
    }
    const err: Error = e as Error;
    if (err !== undefined && err !== null && err.message !== undefined && err.message.length > 0) {
      return err.message;
    }
    return '操作失败，请重试';
  }
}

/** 验证码图片（展示用 base64 + OCR 用原始字节） */
export class CaptchaImage {
  /** data:image/...;base64,... 可直接给 Image 组件 */
  dataUri: string = '';
  /** 原始 JPEG 字节 */
  raw: ArrayBuffer;

  constructor(dataUri: string, raw: ArrayBuffer) {
    this.dataUri = dataUri;
    this.raw = raw;
  }
}

/**
 * 「取一张验证码并自动识别」的结果。
 *
 * 关键约束：`image` 与 `text` 必须是**同一张图**。
 * 早前踩过坑 —— 预填的是识别结果、显示的却是另取的一张新图，
 * 用户直接提交必然失败，还会被误认为识别功能坏了。
 */
export class CaptchaSolve {
  image: CaptchaImage | null = null;
  /** 识别出的验证码；失败时为空串 */
  text: string = '';
  /** 识别是否成功 */
  ocrOk: boolean = false;
  /** 失败原因（仅提示用，不阻塞手动输入） */
  reason: string = '';

  constructor(image: CaptchaImage | null, text: string, ocrOk: boolean, reason: string) {
    this.image = image;
    this.text = text;
    this.ocrOk = ocrOk;
    this.reason = reason;
  }
}
