/*
 * PixelBuffer：与平台无关的 RGBA_8888 像素缓冲
 *
 * 为什么要有这一层：预处理逻辑（CaptchaPrep / CaptchaVote）要能在 Node 里
 * 离线单测，就不能直接依赖 `@kit.ImageKit` 的 PixelMap。
 * 因此把「读到的像素字节 + 宽高」抽成一个纯数据结构，
 * 由 OcrProbe 负责在 PixelMap 与本类型之间搬运。
 *
 * 约定：data 为行优先 RGBA，长度 = width * height * 4。
 */
export class PixelBuffer {
  width: number = 0;
  height: number = 0;
  data: Uint8Array;

  constructor(width: number, height: number, data: Uint8Array) {
    this.width = width;
    this.height = height;
    this.data = data;
  }

  /** 是否与声明的宽高一致（防止读像素时 stride 不一致导致越界） */
  isValid(): boolean {
    return this.width > 0 && this.height > 0 &&
      this.data.length >= this.width * this.height * 4;
  }
}