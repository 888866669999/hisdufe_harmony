/*
 * CaptchaModel：用端上推理跑 ddddocr 的训练模型识别验证码
 *
 * ===== 为什么走「训练模型」而不是继续调通用 OCR =====
 * 通用文字识别（@kit.CoreVisionKit）是按自然场景文字训练的，对验证码这种
 * 「4 个扭曲字符」的输入几乎不可用 —— 实测多种预处理组合下完全正确率只有
 * **14%–42%**（见 README 的验证码识别一节，有逐变体的实测数据）。
 * 而开源项目 ddddocr（MIT 许可）专门在这类验证码上训练过，
 * 在**同一批语料上实测 11/12（92%）**，差距是量级性的。
 *
 * 因此这里直接使用它的模型，而不是继续在通用 OCR 上做预处理调参。
 *
 * ===== 模型是怎么进到端上的 =====
 * ddddocr 只发布 ONNX。HarmonyOS 的 ArkTS 端**没有** ONNX/TFLite 运行时，
 * 只有 MindSpore Lite（且只吃 `.ms` = MindIR）。链路是：
 *
 *   common.onnx（ddddocr 自带）
 *     → converter_lite（官方 MindSpore Lite 工具，--fmk=ONNX --fp16=on）
 *     → captcha_crnn.ms（27 MB，内置在 rawfile）
 *
 * 注意：ddddocr 另有一个量化过的 common_old.onnx（13 MB，精度更高一点），
 * 但它用了 ConvInteger / DynamicQuantizeLSTM 等量化算子，
 * converter_lite **不支持**，因此只能退用浮点版（fp16 后 27 MB）。
 *
 * ===== 关于网络：本方案不需要联网 =====
 * 模型随包内置、推理在本机完成，不上传验证码，也不请求任何第三方服务。
 */
import { common } from '@kit.AbilityKit';
import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { image } from '@kit.ImageKit';
import { Logger } from '../common/Logger';
import { CaptchaCharset } from '../model/CaptchaCharset';

/** 模型文件（放在 rawfile 里随包分发） */
const MODEL_RAWFILE: string = 'captcha_crnn.ms';

/** 模型要求的输入尺寸：灰度、高 64、宽 160（训练时就固定成这个宽） */
export const MODEL_HEIGHT: number = 64;
export const MODEL_WIDTH: number = 160;

/** 推理结果 */
export class ModelOutcome {
  ok: boolean = false;
  text: string = '';
  reason: string = '';

  constructor(ok: boolean, text: string, reason: string) {
    this.ok = ok;
    this.text = text;
    this.reason = reason;
  }
}

export class CaptchaModel {
  /** 已加载的模型（懒加载，首次识别时才读盘） */
  private static model: mindSporeLite.Model | null = null;
  /** 加载中的 Promise，避免并发重复加载 */
  private static loading: Promise<mindSporeLite.Model | null> | null = null;

  /** 本设备是否具备端上推理能力 */
  static supported(): boolean {
    try {
      return canIUse('SystemCapability.AI.MindSporeLite');
    } catch (e) {
      return false;
    }
  }

  /** 是否已加载好模型 */
  static isReady(): boolean {
    return CaptchaModel.model !== null;
  }

  /**
   * 读取 rawfile 里的模型字节。
   * 用 buffer 形式加载（loadModelFromBuffer），避免依赖资源路径在不同
   * 上下文下的解析差异。
   *
   * 单独抽出来是因为 `resourceManager.getRawFileContentSync` 的返回类型
   * 在 ArkTS 下需要显式声明才能通过编译（不允许 any/unknown）。
   */
  private static readModelBytes(ctx: Object): ArrayBuffer {
    const c = ctx as common.Context;
    const bytes: Uint8Array =
      c.resourceManager.getRawFileContentSync(MODEL_RAWFILE);
    return bytes.buffer as ArrayBuffer;
  }

  /** 加载模型（幂等） */
  static async load(ctx: Object): Promise<mindSporeLite.Model | null> {
    if (CaptchaModel.model !== null) {
      return CaptchaModel.model;
    }
    if (CaptchaModel.loading !== null) {
      return await CaptchaModel.loading;
    }
    CaptchaModel.loading = CaptchaModel.doLoad(ctx);
    try {
      return await CaptchaModel.loading;
    } finally {
      CaptchaModel.loading = null;
    }
  }

  private static async doLoad(ctx: Object): Promise<mindSporeLite.Model | null> {
    try {
      const bytes: ArrayBuffer = CaptchaModel.readModelBytes(ctx);
      if (bytes.byteLength === 0) {
        Logger.warn('captcha model: rawfile empty');
        return null;
      }
      const context: mindSporeLite.Context = {
        target: ['cpu'],
        cpu: { threadNum: 2, threadAffinityMode: 1 }
      };
      const m: mindSporeLite.Model =
        await mindSporeLite.loadModelFromBuffer(bytes, context);
      CaptchaModel.model = m;
      // 打印真实的输入张量形状，便于确认与预处理是否匹配
      try {
        const inputs: mindSporeLite.MSTensor[] = m.getInputs();
        if (inputs.length > 0) {
          Logger.info('captcha model loaded: input=' + JSON.stringify(inputs[0].shape) +
            ' dtype=' + inputs[0].dtype.toString());
        }
      } catch (e) {
        // 打印失败不影响使用
      }
      return m;
    } catch (e) {
      const err: Error = e as Error;
      Logger.warn('captcha model load failed: ' +
        (err !== undefined && err.message !== undefined ? err.message : String(e)));
      return null;
    }
  }

  /** 释放模型（退出登录等场景可调用，非必须） */
  static release(): void {
    const m = CaptchaModel.model;
    CaptchaModel.model = null;
    if (m !== null) {
      // Model 接口在 ArkTS 侧没有显式 release；置空后由 GC 回收。
      Logger.info('captcha model released');
    }
  }

  /**
   * 识别一张验证码。
   *
   * @param jpeg 验证码原图（JPEG 字节）
   * @param ctx  应用上下文（用于读取 rawfile）
   */
  static async recognize(jpeg: ArrayBuffer, ctx: Object): Promise<ModelOutcome> {
    let src: image.ImageSource | null = null;
    let gray: image.PixelMap | null = null;
    try {
      const m: mindSporeLite.Model | null = await CaptchaModel.load(ctx);
      if (m === null) {
        return new ModelOutcome(false, '', '模型未加载');
      }

      src = image.createImageSource(jpeg);
      const info: image.ImageInfo = await src.getImageInfo();
      if (info.size.width <= 0 || info.size.height <= 0) {
        return new ModelOutcome(false, '', '验证码尺寸异常');
      }

      // 1) 解码为灰度、等比缩放到高 64
      //    解码器只接受绝对尺寸，因此先按目标高算出宽，再在下面补白到 160。
      const scale: number = MODEL_HEIGHT / info.size.height;
      let targetW: number = Math.round(info.size.width * scale);
      if (targetW < 1) {
        targetW = 1;
      }
      const pm: image.PixelMap = await src.createPixelMap({
        desiredSize: { width: targetW, height: MODEL_HEIGHT },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: true
      });
      gray = pm;

      // 2) 读像素并按 stride 去填充，再转灰度 + 归一化 + 右侧补白到 160
      const stride: number = pm.getBytesNumberPerRow();
      const raw: ArrayBuffer = new ArrayBuffer(stride * MODEL_HEIGHT);
      await pm.readPixelsToBuffer(raw);
      const bytes: Uint8Array = new Uint8Array(raw);

      const tensor: Float32Array = new Float32Array(MODEL_HEIGHT * MODEL_WIDTH);
      // 补白像素用 255（白底），与训练时的 padding 一致
      tensor.fill(1.0);
      for (let y = 0; y < MODEL_HEIGHT; y++) {
        const rowBase: number = y * stride;
        for (let x = 0; x < targetW && x < MODEL_WIDTH; x++) {
          const o: number = rowBase + x * 4;
          // ITU-R BT.601 整数亮度，避免浮点开销
          const g: number = (bytes[o] * 77 + bytes[o + 1] * 151 + bytes[o + 2] * 28) >> 8;
          tensor[y * MODEL_WIDTH + x] = g / 255.0;
        }
      }

      // 3) 填入输入张量（NCHW: 1×1×64×160）
      const inputs: mindSporeLite.MSTensor[] = m.getInputs();
      if (inputs.length === 0) {
        return new ModelOutcome(false, '', '模型无输入张量');
      }
      inputs[0].setData(tensor.buffer as ArrayBuffer);

      // 4) 推理
      const outputs: mindSporeLite.MSTensor[] = await m.predict(inputs);
      if (outputs.length === 0) {
        return new ModelOutcome(false, '', '模型无输出');
      }
      const out: mindSporeLite.MSTensor = outputs[0];
      const probs: Float32Array = new Float32Array(out.getData());
      const shape: number[] = out.shape;
      // 期望 [T, 1, C]；T 为时间步（本模型在 width=160 时约 20 步）
      if (shape.length !== 3) {
        return new ModelOutcome(false, '',
          '输出形状异常: ' + JSON.stringify(shape));
      }
      const steps: number = shape[0];
      const classes: number = shape[2];
      const indices: number[] = [];
      for (let t = 0; t < steps; t++) {
        let best: number = 0;
        let bestVal: number = -1;
        const base: number = t * classes;
        for (let c = 0; c < classes; c++) {
          const v: number = probs[base + c];
          if (v > bestVal) {
            bestVal = v;
            best = c;
          }
        }
        indices.push(best);
      }
      const text: string = CaptchaCharset.decode(indices);
      Logger.info('captcha model: steps=' + steps.toString() + ' classes=' +
        classes.toString() + ' len=' + text.length.toString());
      if (text.length === 0) {
        return new ModelOutcome(false, '', '未识别出字符');
      }
      return new ModelOutcome(true, text, '');
    } catch (e) {
      const err: Error = e as Error;
      const msg: string = (err !== undefined && err.message !== undefined) ? err.message : String(e);
      Logger.warn('captcha model run failed: ' + msg);
      return new ModelOutcome(false, '', msg);
    } finally {
      if (gray !== null) {
        try {
          gray.release();
        } catch (e) {
          // 忽略
        }
      }
      if (src !== null) {
        try {
          src.release();
        } catch (e) {
          // 忽略
        }
      }
    }
  }
}