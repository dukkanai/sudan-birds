import { encode } from "npm:jpeg-js@0.4.4";
export function jpeg(width = 16, height = 16, noisy = false) {
  const data = new Uint8Array(width * height * 4);
  let seed = 117;
  for (let i = 0; i < data.length; i++) {
    seed = (Math.imul(seed, 1664525) + 1013904223) | 0;
    data[i] = i % 4 === 3 ? 255 : noisy ? seed >>> 24 : 120;
  }
  return new Uint8Array(encode({ width, height, data }, 80).data);
}
export function assert(value: unknown): asserts value {
  if (!value) throw new Error("Assertion failed");
}
