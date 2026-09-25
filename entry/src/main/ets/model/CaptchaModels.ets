/*
 * CaptchaModels：验证码 OCR 的轻量数据模型
 *
 * 单独成文件，是为了让纯逻辑模块（CaptchaVote）不必依赖 `@kit` 的
 * OCR 声明文件即可编译与单测；OcrProbe 负责把 SDK 的
 * `textRecognition.TextWord` 转换成本类型。
 */

/** 一个文字块的包围盒（像素坐标，取自 OCR 的 cornerPoints） */
export class TextBox {
  value: string = '';
  /** 左上角与右下角（cornerPoints 归约而来） */
  x0: number = 0;
  y0: number = 0;
  x1: number = 0;
  y1: number = 0;

  constructor(value: string, x0: number, y0: number, x1: number, y1: number) {
    this.value = value;
    this.x0 = x0;
    this.y0 = y0;
    this.x1 = x1;
    this.y1 = y1;
  }

  left(): number {
    return this.x0;
  }

  width(): number {
    return this.x1 - this.x0;
  }

  height(): number {
    return this.y1 - this.y0;
  }
}