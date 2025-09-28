// simple_bench.c — Paragon CPU vs GPU micro-benchmark via C-ABI (portable)
//
// Build the Go shared lib first, e.g. on Linux:
//   go build -buildmode=c-shared -o teleport_amd64_linux.so main.go
// Your build script should copy the emitted header to: teleport.h

#if !defined(_WIN32) && !defined(__APPLE__)
  // Enable POSIX clock_gettime on Linux/BSD
  #ifndef _POSIX_C_SOURCE
  #define _POSIX_C_SOURCE 199309L
  #endif
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdbool.h>

#if defined(_WIN32)
  #define WIN32_LEAN_AND_MEAN
  #include <windows.h>
  #include <malloc.h>
  #define strdup _strdup
  static double now_sec(void) {
      LARGE_INTEGER f, t;
      QueryPerformanceFrequency(&f);
      QueryPerformanceCounter(&t);
      return (double)t.QuadPart / (double)f.QuadPart;
  }
#elif defined(__APPLE__)
  #include <mach/mach_time.h>
  static double now_sec(void) {
      static mach_timebase_info_data_t tb = {0,0};
      if (tb.denom == 0) mach_timebase_info(&tb);
      uint64_t t = mach_continuous_time(); // monotonic
      return (double)t * (double)tb.numer / (double)tb.denom / 1e9;
  }
#else
  #include <time.h>
  static double now_sec(void) {
      struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
      return ts.tv_sec + ts.tv_nsec * 1e-9;
  }
#endif

// ────────── Paragon C-ABI (from Go) ──────────
// The build script places the generated header next to the lib as teleport.h
#include "teleport.h"

// ────────── tiny portable strdup ──────────
static char* xstrdup(const char* s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char* p = (char*)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

// ────────── helpers ──────────
static char* steal(char* p) {            // take ownership of Go-allocated C string
    if (!p) return NULL;
    char* c = xstrdup(p);
    Paragon_FreeCString(p);
    return c;
}
static bool is_error(const char* js) { return js && strstr(js, "\"error\""); }

static long long parse_handle(const char* js) {
    const char* h = strstr(js, "\"handle\"");
    if (!h) return 0;
    const char* colon = strchr(h, ':');
    while (colon && (*++colon==' '||*colon=='\t'));
    return (long long)strtoll(colon, NULL, 10);
}

// JSON [[[ … ]]] : batch=1, height=1, width=in_dim
static char* make_input(int in_dim) {
    srand(42);
    size_t cap = 16 + (size_t)in_dim * 12;
    char* buf = (char*)malloc(cap);
    size_t len = 0;
    len += snprintf(buf+len, cap-len, "[[[");
    for (int i=0;i<in_dim;i++){
        float v = (float)rand() / (float)RAND_MAX;
        if (i < in_dim-1) len += snprintf(buf+len, cap-len, "%.6f,", v);
        else              len += snprintf(buf+len, cap-len, "%.6f", v);
    }
    len += snprintf(buf+len, cap-len, "]]]");
    return buf;
}

// pulls first N floats from {"output":[[ … ]]}
static void extract_first_n(const char* js,float*out,int n){
    const char* p=strstr(js,"[["); if(!p) return; p+=2;
    for(int i=0;i<n;i++){
        out[i]=strtof(p,(char**)&p);
        p=strchr(p, i==n-1?']':','); if(!p)break; ++p;
    }
}

// rough VRAM estimate for FC weights (float32)
static double est_vram_mb_fc(int in_dim, int hidden, int hidden_layers, int out_dim) {
    double params = (double)in_dim * hidden;
    if (hidden_layers > 1) params += (double)(hidden_layers-1) * hidden * hidden;
    params += (double)hidden * out_dim;
    params += (double)hidden_layers * hidden + out_dim; // biases
    return params * 4.0 / (1024.0*1024.0);
}

// build JSON for layers/activations/fully (Height=1 for FC)
static char* build_layers_json(int in_dim, int hidden, int hidden_layers, int out_dim) {
    size_t cap = 64 + (size_t)(hidden_layers+2) * 40;
    char* buf = (char*)malloc(cap);
    size_t len = 0;
    len += snprintf(buf+len, cap-len, "[");
    len += snprintf(buf+len, cap-len, "{\"Width\":%d,\"Height\":1},", in_dim);
    for (int i=0;i<hidden_layers;i++) {
        len += snprintf(buf+len, cap-len, "{\"Width\":%d,\"Height\":1},", hidden);
    }
    if (buf[len-1] == ',') len--;
    len += snprintf(buf+len, cap-len, ",{\"Width\":%d,\"Height\":1}]", out_dim);
    for (size_t i=1;i<len;i++){ if (buf[i-1]==']' && buf[i]==',') buf[i]=' '; }
    return buf;
}

static char* build_activ_json(int total_layers) {
    size_t cap = 32 + (size_t)total_layers * 8;
    char* buf = (char*)malloc(cap);
    size_t len = 0;
    len += snprintf(buf+len, cap-len, "[");
    for (int i=0;i<total_layers;i++) {
        len += snprintf(buf+len, cap-len, "\"relu\"");
        if (i < total_layers-1) len += snprintf(buf+len, cap-len, ",");
    }
    len += snprintf(buf+len, cap-len, "]");
    return buf;
}

static char* build_fully_json(int total_layers) {
    size_t cap = 32 + (size_t)total_layers * 6;
    char* buf = (char*)malloc(cap);
    size_t len = 0;
    len += snprintf(buf+len, cap-len, "[");
    for (int i=0;i<total_layers;i++) {
        len += snprintf(buf+len, cap-len, "true");
        if (i < total_layers-1) len += snprintf(buf+len, cap-len, ",");
    }
    len += snprintf(buf+len, cap-len, "]");
    return buf;
}

static void run_case(const char* name, int in_dim, int hidden, int hidden_layers, int out_dim, int runs) {
    int total_layers = 1 + hidden_layers + 1;
    char* layers = build_layers_json(in_dim, hidden, hidden_layers, out_dim);
    char* activ  = build_activ_json(total_layers);
    char* fully  = build_fully_json(total_layers);

    double est_mb = est_vram_mb_fc(in_dim, hidden, hidden_layers, out_dim);

    printf("\n=== Case: %s ===\n", name);
    printf("Shape: %d →", in_dim);
    for (int i=0;i<hidden_layers;i++) printf(" %d →", hidden);
    printf(" %d   (~weights %.2f MB)\n", out_dim, est_mb);

    char* r = steal(Paragon_NewNetworkFloat32(layers,activ,fully,true,false));
    printf("NewNetwork → %s\n", r);
    if (is_error(r)) { free(r); goto cleanup; }
    long long h = parse_handle(r); free(r);

    r = steal(Paragon_PerturbWeights(h, 0.1, 42));
    printf("PerturbWeights → %s\n", r);
    if (is_error(r)) { free(r); Paragon_Free(h); goto cleanup; }
    free(r);

    char* in = make_input(in_dim);

    // ---- CPU ----
    puts("\nCPU:");
    r = steal(Paragon_DisableGPU(h));  printf("DisableGPU → %s\n", r); free(r);
    for (int i=0;i<10;i++){ r=steal(Paragon_Call(h,"Forward",in)); free(r);} // warmup
    double t0=now_sec();
    for (int i=0;i<runs;i++){ r=steal(Paragon_Call(h,"Forward",in)); free(r); }
    double cpu_t = now_sec()-t0;
    r = steal(Paragon_Call(h,"ExtractOutput","[]"));
    char* cpu_out = r;
    printf("  time  %.6fs  (%.1f inf/s)\n", cpu_t, runs/cpu_t);

    // ---- GPU ----
    puts("\nGPU:");
    r = steal(Paragon_EnableGPU(h));   printf("EnableGPU → %s\n", r);
    if (is_error(r)) { free(r); goto compare_and_done; }
    free(r);
    for (int i=0;i<10;i++){ r=steal(Paragon_Call(h,"Forward",in)); free(r);} // warmup
    t0=now_sec();
    for (int i=0;i<runs;i++){ r=steal(Paragon_Call(h,"Forward",in)); free(r); }
    double gpu_t = now_sec()-t0;
    r = steal(Paragon_Call(h,"ExtractOutput","[]"));
    char* gpu_out = r;
    printf("  time  %.6fs  (%.1f inf/s)\n", gpu_t, runs/gpu_t);
    printf("  speed-up %.2fx\n", cpu_t/gpu_t);

    // parity check (first 10 outputs)
    {
        float c[10]={0}, g[10]={0}; extract_first_n(cpu_out,c,10); extract_first_n(gpu_out,g,10);
        puts("\nIdx |    CPU     |    GPU     | Δ");
        puts("----+-----------+-----------+-----------");
        int ok=0;
        for(int i=0;i<10;i++){
            float d=fabsf(c[i]-g[i]);
            printf("%3d | %9.5f | %9.5f | %9.5f\n",i,c[i],g[i],d);
            if(d<1e-4f) ok++;
        }
        printf("\nMatch within 1e-4: %d/10\n", ok);
    }
    free(gpu_out);

compare_and_done:
    free(cpu_out); free(in); Paragon_Free(h);

cleanup:
    free(layers); free(activ); free(fully);
}

int main(void){
    puts("Simple Paragon CPU vs GPU Benchmark (portable)");
    puts("==============================================");

    struct { const char* name; int hidden; int hidden_layers; } cases[10] = {
        {"S1",   64, 1},
        {"S2",  128, 1},
        {"S3",  256, 1},
        {"M1",  256, 2},
        {"M2",  384, 2},
        {"M3",  512, 2},
        {"L1",  768, 3},
        {"L2", 1024, 3},
        {"XL1",1536, 4},
        {"XL2",2048, 4}
        // Add {"XXL", 3072, 4} if you want ~123MB weights stress
    };

    const int IN  = 784;
    const int OUT = 10;
    const int RUNS = 100;

    for (int i=0;i<10;i++){
        run_case(cases[i].name, IN, cases[i].hidden, cases[i].hidden_layers, OUT, RUNS);
    }
    return 0;
}
