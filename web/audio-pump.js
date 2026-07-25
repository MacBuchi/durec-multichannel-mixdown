// Audio output for the browser preview (docs/PLAN-PWA.md S4).
//
// The audio thread must never wait for anything, so this processor does the
// least possible work: it copies interleaved stereo f32 out of a ring buffer
// in a SharedArrayBuffer that Dart keeps filled. No wasm call, no allocation,
// no message passing in the callback.
//
// The ring holds interleaved samples; `state` carries the indices so both
// sides can advance them without locks:
//   [0] read index  (samples, owned by this processor)
//   [1] write index (samples, owned by the filler)
//   [2] underruns   (diagnostics — the filler fell behind)
//   [3] frames played (so the playhead follows what was actually heard,
//       not what was produced)
class DurecmixPump extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const { ring, state } = options.processorOptions;
    this.ring = new Float32Array(ring);
    this.state = new Int32Array(state);
  }

  process(_inputs, outputs) {
    const out = outputs[0];
    const left = out[0];
    const right = out.length > 1 ? out[1] : out[0];
    const capacity = this.ring.length;
    const wanted = left.length * 2;

    let read = Atomics.load(this.state, 0);
    const write = Atomics.load(this.state, 1);
    const available = (write - read + capacity) % capacity;

    if (available < wanted) {
      // Underrun: silence is the only honest answer, and counting it makes
      // the problem visible instead of merely audible.
      left.fill(0);
      right.fill(0);
      Atomics.add(this.state, 2, 1);
      return true;
    }

    for (let i = 0; i < left.length; i++) {
      left[i] = this.ring[read];
      right[i] = this.ring[read + 1];
      read += 2;
      if (read >= capacity) read -= capacity;
    }
    Atomics.store(this.state, 0, read);
    Atomics.add(this.state, 3, left.length);
    return true;
  }
}

registerProcessor('durecmix-pump', DurecmixPump);
