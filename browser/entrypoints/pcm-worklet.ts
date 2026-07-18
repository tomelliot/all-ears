import { defineUnlistedScript } from "#imports";

// AudioWorkletProcessor entrypoint. Bundled to a web-accessible pcm-worklet.js
// and loaded via audioWorklet.addModule(runtime.getURL("/pcm-worklet.js")).
// Runs in AudioWorkletGlobalScope — no window, no chrome. The WXT unlisted-
// script wrapper only touches locals + a no-op logger, so it is safe here.
//
// The host AudioContext is created at 16 kHz, so the browser has already
// resampled the input; this processor only downmixes to mono and converts
// Float32 [-1,1] → pcm_s16le, emitting fixed 100 ms frames (~10/s).

// AudioWorkletGlobalScope globals, not in lib.dom.
declare const AudioWorkletProcessor: {
  prototype: AudioWorkletProcessor;
  new (): AudioWorkletProcessor;
};
interface AudioWorkletProcessor {
  readonly port: MessagePort;
}
declare function registerProcessor(
  name: string,
  ctor: new () => AudioWorkletProcessor & {
    process(inputs: Float32Array[][]): boolean;
  },
): void;

const FRAME_SAMPLES = 1600; // 100 ms @ 16 kHz

export default defineUnlistedScript(() => {
  class PcmDownsampler extends (AudioWorkletProcessor as {
    new (): AudioWorkletProcessor;
  }) {
    private buf = new Int16Array(FRAME_SAMPLES);
    private idx = 0;

    process(inputs: Float32Array[][]): boolean {
      const input = inputs[0];
      if (!input || input.length === 0) return true;
      const channel = input[0]; // 16 kHz context → already resampled; take ch 0
      if (!channel) return true;

      for (let i = 0; i < channel.length; i++) {
        let s = channel[i]!;
        if (s > 1) s = 1;
        else if (s < -1) s = -1;
        this.buf[this.idx++] = s < 0 ? s * 0x8000 : s * 0x7fff;
        if (this.idx === FRAME_SAMPLES) {
          // Transfer the buffer so there's no copy; allocate a fresh one.
          this.port.postMessage(this.buf, [this.buf.buffer]);
          this.buf = new Int16Array(FRAME_SAMPLES);
          this.idx = 0;
        }
      }
      return true; // keep the processor alive
    }
  }

  registerProcessor("pcm-16k", PcmDownsampler);
});
