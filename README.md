# Teleport

[![Go](https://img.shields.io/badge/Go-1.21%2B-blue?logo=go)](https://golang.org/)
[![C](https://img.shields.io/badge/C-C11%2B-brightgreen?logo=c)](<https://en.wikipedia.org/wiki/C_(programming_language)>)
[![GPU](https://img.shields.io/badge/GPU-WebGPU-orange?logo=webgpu)](https://gpuweb.github.io/gpuweb/)

**Toolkit for Enabling Language-agnostic Execution of Paragon Objects in Real-time Targets**

Teleport provides a C ABI (Application Binary Interface) wrapper around the [Paragon](https://github.com/openfluke/paragon) neural network library, enabling seamless integration and execution of Paragon objects (e.g., `Network[float32]`) across programming languages, runtimes, and targets. It supports real-time inference on CPU and GPU (via WebGPU), with dynamic JSON-based method invocation for flexibility.

This pipeline compiles Paragon's Go-based computations into a shared library (`libparacast.so`), exposing a stable C ABI. Call it from C, C++, Rust, Python (via ctypes), or any language with FFI support—without recompiling the host app.

## Features

- **Language-Agnostic ABI**: Export Paragon methods via C functions; pass JSON strings for args/returns.
- **CPU/GPU Switching**: Runtime toggle between CPU fallback and WebGPU acceleration.
- **Dynamic Invocation**: Call any exported method (e.g., `Forward`, `PerturbWeights`) with JSON params—no static typing required.
- **Real-Time Targets**: Optimized for low-latency inference; supports embedded/edge devices with WebGPU backends (e.g., Mesa, ANGLE).
- **Error Handling**: JSON responses with `"error"` fields for robust integration.
- **Memory Management**: Caller-owned strings; explicit cleanup via `Paragon_Free`.
- **Benchmarked Performance**: Up to 1.37x speedup on GPU vs. CPU (see [benchmark](#benchmark)).

## Prerequisites

- Go 1.21+ (for building the shared lib).
- C compiler (e.g., GCC 11+).
- WebGPU runtime (e.g., [wgpu](https://wgpu.rs/) or browser via WASM; Linux: Mesa i915/Intel Arc).
- Paragon v3: `go mod tidy` pulls it automatically.

## Building

1. Clone and init:

   ```
   git clone <your-repo-url>
   cd teleport
   go mod tidy
   ```

2. Build the shared library:

   ```
   go build -buildmode=c-shared -o libparacast.so main.go
   ```

   - Outputs: `libparacast.so` (Linux/macOS) or `paracast.dll` (Windows).
   - For WASM: Use `tinygo build` with WebGPU flags (see [docs](https://tinygo.org/)).

3. (Optional) Install headers: Copy `paragon.h` (generated or manual) to `/usr/local/include`.

## Usage

### C Example: Simple Inference Benchmark

This micro-benchmark creates a 784→256→10 feedforward network, runs forward passes on CPU/GPU, and compares outputs.

**simple_bench.c**:

```c
// simple_bench.c — Paragon CPU vs GPU micro-benchmark via C-ABI
//
//   gcc -std=c11 simple_bench.c -L. -lparacast -o simple_bench \
//       -Wl,-rpath,'$ORIGIN' -ldl -lm -lpthread
//
//   (Shared lib was built with:
//      go build -buildmode=c-shared -o libparacast.so main.go )

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>
#include <stdbool.h>

// ────────── Paragon C-ABI ──────────
extern char* Paragon_NewNetworkFloat32(const char*, const char*, const char*, _Bool, _Bool);
extern char* Paragon_Call(long long, const char*, const char*);
extern char* Paragon_EnableGPU(long long);
extern char* Paragon_DisableGPU(long long);
extern char* Paragon_PerturbWeights(long long, double, long long);
extern void  Paragon_Free(long long);
extern void  Paragon_FreeCString(char*);

// ────────── helpers ──────────
static char* steal(char* p) {            // strdup → caller owns
    if (!p) return NULL;
    char* c = strdup(p);
    Paragon_FreeCString(p);
    return c;
}
static bool is_error(const char* js) { return js && strstr(js, "\"error\""); }

static long long parse_handle(const char* js) {
    const char* h = strstr(js, "\"handle\"");
    if (!h) return 0;
    const char* colon = strchr(h, ':');
    while (colon && (*++colon==' '||*colon=='\t'));
    return strtoll(colon, NULL, 10);
}

static double now_sec(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec*1e-9;
}

// JSON [[[ … ]]] : batch=1, height=1, width=784
static char* make_input(void) {
    srand(42);
    char* buf = malloc(23000); // plenty
    strcpy(buf, "[[[");
    for (int i=0;i<784;i++){
        float v = (float)rand()/RAND_MAX;
        char tmp[32]; snprintf(tmp,sizeof tmp,"%.6f",v);
        strcat(buf,tmp);
        if (i<783) strcat(buf,",");
    }
    strcat(buf,"]]]");
    return buf;
}

// pulls first N floats from {"output":[[ … ]]}
static void extract(const char* js,float*out,int n){
    const char* p=strstr(js,"[["); if(!p) return; p+=2;
    for(int i=0;i<n;i++){
        out[i]=strtof(p,(char**)&p);
        p=strchr(p, i==n-1?']':','); if(!p)break; ++p;
    }
}

// ────────── main ──────────
int main(void){
    puts("Simple Paragon CPU vs GPU Benchmark");
    puts("===================================");

    /* network layout */
    const char* layers =
        "[{\"Width\":784,\"Height\":1},"
         "{\"Width\":256,\"Height\":1},"
         "{\"Width\":10,\"Height\":1}]";
    const char* activ = "[\"relu\",\"relu\",\"relu\"]";
    const char* fully  = "[true,true,true]";

    /* create network */
    char* r = steal(Paragon_NewNetworkFloat32(layers,activ,fully,true,false));
    printf("NewNetwork → %s\n", r);
    if(is_error(r)){free(r); return 1;}
    long long h = parse_handle(r); free(r);

    /* init weights */
    r = steal(Paragon_PerturbWeights(h,0.1,42));
    printf("PerturbWeights → %s\n", r);
    if(is_error(r)){free(r); goto fail;} free(r);

    /* input */
    char* in = make_input();
    const int RUNS = 100;

    /* ---- CPU ---- */
    puts("\nCPU:");
    r = steal(Paragon_DisableGPU(h));  printf("DisableGPU → %s\n", r); free(r);

    for(int i=0;i<10;i++){ r=steal(Paragon_Call(h,"Forward",in)); free(r);} // warm

    double t0=now_sec();
    for(int i=0;i<RUNS;i++){ r=steal(Paragon_Call(h,"Forward",in)); free(r);}
    double cpu_t = now_sec()-t0;

    r = steal(Paragon_Call(h,"ExtractOutput","[]"));
    char* cpu_out = r;

    printf("  time  %.6fs  (%.1f inf/s)\n", cpu_t, RUNS/cpu_t);

    /* ---- GPU ---- */
    puts("\nGPU:");
    r = steal(Paragon_EnableGPU(h));   printf("EnableGPU → %s\n", r);
    if(is_error(r)){free(r); goto done;} free(r);

    for(int i=0;i<10;i++){ r=steal(Paragon_Call(h,"Forward",in)); free(r);} // warm

    t0=now_sec();
    for(int i=0;i<RUNS;i++){ r=steal(Paragon_Call(h,"Forward",in)); free(r);}
    double gpu_t = now_sec()-t0;

    r = steal(Paragon_Call(h,"ExtractOutput","[]"));
    char* gpu_out = r;

    printf("  time  %.6fs  (%.1f inf/s)\n", gpu_t, RUNS/gpu_t);
    printf("  speed-up %.2fx\n", cpu_t/gpu_t);

    /* compare first 10 */
    float c[10]={0}, g[10]={0}; extract(cpu_out,c,10); extract(gpu_out,g,10);
    puts("\nIdx |    CPU     |    GPU     | Δ");
    puts("----+-----------+-----------+-----------");
    int ok=0;
    for(int i=0;i<10;i++){
        float d=fabsf(c[i]-g[i]);
        printf("%3d | %9.5f | %9.5f | %9.5f\n",i,c[i],g[i],d);
        if(d<1e-4f) ok++;
    }
    printf("\nMatch within 1e-4: %d/10\n", ok);

done:
    free(cpu_out); free(gpu_out); free(in); Paragon_Free(h);
    return 0;
fail:
    Paragon_Free(h); free(in); return 1;
}
```

Compile and run:

```
gcc -std=c11 simple_bench.c -L. -lparacast -o simple_bench -Wl,-rpath,'$ORIGIN' -ldl -lm -lpthread
./simple_bench
```

### Sample Output (Linux, Intel Arc + Mesa i915)

```
Simple Paragon CPU vs GPU Benchmark
===================================
[wgpu] [Warn] Detected skylake derivative running on mesa i915. Clears to srgb textures will use manual shader clears.
🚀 GPU Selected: 0x25a2 (0x10de) - Type: discrete-gpu
NewNetwork → {"debug":false,"gpu":true,"gpu_init_ms":1701,"gpu_init_ok":true,"handle":1,"layers":3,"type":"Network[float32]"}
PerturbWeights → {"status":"weights perturbed"}

CPU:
DisableGPU → {"handle":1,"status":"GPU disabled"}
  time  0.037603s  (2659.4 inf/s)

GPU:
EnableGPU → {"handle":1,"status":"GPU enabled"}
  time  0.027348s  (3656.6 inf/s)
  speed-up 1.37x

Idx |    CPU     |    GPU     | Δ
----+-----------+-----------+-----------
  0 |   0.00000 |   0.00000 |   0.00000
  1 |  26.15084 |  26.15084 |   0.00001
  2 |  35.77044 |  35.77044 |   0.00000
  3 |   0.00000 |   0.00000 |   0.00000
  4 |  48.82456 |  48.82457 |   0.00001
  5 |  13.98466 |  13.98464 |   0.00003
  6 |   0.00000 |   0.00000 |   0.00000
  7 |   0.00000 |   0.00000 |   0.00000
  8 |  61.21801 |  61.21799 |   0.00003
  9 |   0.00000 |   0.00000 |   0.00000

Match within 1e-4: 10/10
```

### Python Example (via ctypes)

```python
import ctypes
import json

lib = ctypes.CDLL('./libparacast.so')

# Function signatures
lib.Paragon_NewNetworkFloat32.restype = ctypes.c_char_p
lib.Paragon_Call.restype = ctypes.c_char_p
lib.Paragon_Free.argtypes = [ctypes.c_int64]
lib.Paragon_FreeCString.argtypes = [ctypes.c_char_p]

# Layers JSON
layers = '[{"Width":784,"Height":1},{"Width":256,"Height":1},{"Width":10,"Height":1}]'
acts = '["relu","relu","relu"]'
fully = '[true,true,true]'

# Create network
r = lib.Paragon_NewNetworkFloat32(layers.encode(), acts.encode(), fully.encode(), True, False)
resp = json.loads(r.decode())
handle = resp['handle']
lib.Paragon_FreeCString(r)

# Perturb weights
r = lib.Paragon_Call(handle, b'PerturbWeights', b'[0.1, 42]')
lib.Paragon_FreeCString(r)

# Input: [[[random floats]]]
input_json = '[[[0.1,0.2,...]]]'  # Truncated; generate as needed

# Forward pass
r = lib.Paragon_Call(handle, b'Forward', input_json.encode())
output = json.loads(r.decode())
lib.Paragon_FreeCString(r)

print("Output:", output)

# Cleanup
lib.Paragon_Free(handle)
```

## C ABI Reference

Include `<paragon.h>` (auto-generated or manual) for declarations.

| Function                                                                                                                               | Description                                                   | Args                          | Returns                                                                               |
| -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------------------------- |
| `char* Paragon_NewNetworkFloat32(const char* layersJSON, const char* activationsJSON, const char* fullyJSON, bool useGPU, bool debug)` | Create `Network[float32]`. JSON arrays for layers/acts/fully. | JSON strings, bools           | JSON: `{"handle":ID, "type":"Network[float32]", "gpu":bool, "gpu_init_ok":bool, ...}` |
| `char* Paragon_Call(int64_t handle, const char* method, const char* argsJSON)`                                                         | Invoke method (e.g., `"Forward"`) with JSON args.             | Handle, method str, JSON args | JSON result or `{"error":"msg"}`                                                      |
| `char* Paragon_EnableGPU(int64_t handle)`                                                                                              | Init/switch to GPU.                                           | Handle                        | JSON: `{"status":"GPU enabled", "handle":ID}` or error                                |
| `char* Paragon_DisableGPU(int64_t handle)`                                                                                             | Switch to CPU; cleanup GPU.                                   | Handle                        | JSON: `{"status":"GPU disabled", "handle":ID}`                                        |
| `char* Paragon_PerturbWeights(int64_t handle, double magnitude, int64_t seed)`                                                         | Randomize weights.                                            | Handle, float, int            | JSON: `{"status":"weights perturbed"}`                                                |
| `void Paragon_Free(int64_t handle)`                                                                                                    | Cleanup object/GPU resources.                                 | Handle                        | -                                                                                     |
| `void Paragon_FreeCString(char* str)`                                                                                                  | Free JSON response string.                                    | C str                         | -                                                                                     |
| `char* Paragon_ListMethods(int64_t handle)`                                                                                            | List exported methods.                                        | Handle                        | JSON: `{"methods":[{...}], "count":N}`                                                |
| `char* Paragon_GetInfo(int64_t handle)`                                                                                                | Object metadata.                                              | Handle                        | JSON: `{"type":"...", "methods":N, ...}`                                              |
| `char* Paragon_GetVersion()`                                                                                                           | ABI version.                                                  | -                             | `"Paragon C ABI v1.0 (float32)"`                                                      |

- **JSON Args**: Arrays `[]` for multi-params; single objects for structs/slices. Supports nesting (e.g., `[[[floats]]]` for tensors).
- **Error Handling**: Check for `"error"` in JSON; free strings regardless.
- **Threading**: Safe via Go mutex; but limit concurrent calls per handle.

## Limitations

- Float32 only (extend via templates).
- WebGPU init can be slow (~1-2s); warm-up recommended.
- No internet/package installs in build env.
- WASM targets: Use TinyGo + Emscripten for browser/edge.

## Contributing

Fork, PR with tests. Run `go test ./...` and benchmarks.

## License

Apache-2.0. See [LICENSE](LICENSE). Paragon is Apache-2.0.
