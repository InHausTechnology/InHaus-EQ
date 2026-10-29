//
//  eq_dsp.c
//  InHausEQ
//
//  Coefficients: RBJ Audio EQ Cookbook (peaking, low shelf, high shelf, Q form).
//  Filters: transposed direct form II, double-precision state.
//
//  Threading:
//  - One UI thread calls the eq_set_* functions.
//  - One audio thread calls eq_process.
//  - Band coefficients are triple-buffered: the UI thread always writes a slot
//    the audio thread is not reading, then publishes it with an atomic store.
//  - Scalar settings (master, input gain, bypass) are single atomics.
//  - Filter state belongs to the audio thread and is never reset by a swap,
//    so moving a slider does not click.
//

#include "eq_dsp.h"

#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EQ_SLOTS 3
#define EQ_CLIP_KNEE 0.891     /* -1 dBFS: soft clipping starts here */
#define EQ_CLIP_CEIL 0.999     /* output never reaches 1.0 */
#define EQ_MASTER_TAU 0.030    /* seconds */
#define EQ_SCOPE_SIZE 65536    /* analyzer ring buffer, power of two, > 2 x largest FFT */

typedef struct {
    double b0, b1, b2, a1, a2;
} Biquad;

typedef struct {
    Biquad bq[EQ_MAX_BANDS];
    int    active[EQ_MAX_BANDS]; /* 0 = pass straight through */
    int    count;
    double preampLin;
} CoeffSlot;

struct EQEngine {
    /* UI-thread state */
    double fs;
    EQBand bands[EQ_MAX_BANDS];
    int    bandCount;
    float  preampDB;

    /* Shared */
    CoeffSlot     slot[EQ_SLOTS];
    atomic_int    published;
    atomic_int    inUse;
    _Atomic float masterTarget;  /* linear */
    _Atomic float inputGain;     /* linear */
    atomic_int    bypass;
    _Atomic double smoothCoef;   /* written only while stopped */

    /* Audio-thread state */
    double z[EQ_MAX_BANDS][2][2]; /* [band][channel][z1,z2] */
    double masterCurrent;
    int    lastSlot;

    /* Analyzer: the audio thread writes, the UI thread reads (a torn read only
       affects one frame of the display). */
    float       scope[2][EQ_SCOPE_SIZE];  /* [0] before EQ, [1] after, mono */
    atomic_uint scopePos;                 /* total samples written */

    /* Analyzer scratch (UI thread only). Twiddles are built once for the largest size;
       smaller FFTs step through them. The window is rebuilt when the size changes. */
    double fftRe[EQ_SPECTRUM_FFT_MAX];
    double fftIm[EQ_SPECTRUM_FFT_MAX];
    double window[EQ_SPECTRUM_FFT_MAX];
    double cosTable[EQ_SPECTRUM_FFT_MAX / 2];
    double sinTable[EQ_SPECTRUM_FFT_MAX / 2];
    int    windowSize;
};

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

static double clampd(double v, double lo, double hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static const Biquad kPassthrough = { 1.0, 0.0, 0.0, 0.0, 0.0 };

/* Cleans one band. Returns 0 if the band should not run (off, non-finite, or flat). */
static int sanitize_band(const EQBand *in, double fs, EQBand *out) {
    *out = *in;
    if (!in->enabled) return 0;
    if (!isfinite(in->freqHz) || !isfinite(in->gainDB) || !isfinite(in->q)) return 0;
    if (in->type != EQ_PEAK && in->type != EQ_LOWSHELF && in->type != EQ_HIGHSHELF) return 0;
    out->freqHz = (float)clampd(in->freqHz, 10.0, 0.45 * fs);
    out->gainDB = (float)clampd(in->gainDB, -24.0, 24.0);
    out->q      = (float)clampd(in->q, 0.1, 10.0);
    if (fabs(out->gainDB) < 0.001) return 0; /* 0 dB = no change; skip the work */
    return 1;
}

static Biquad make_biquad(const EQBand *b, double fs) {
    const double A     = pow(10.0, (double)b->gainDB / 40.0);
    const double w0    = 2.0 * M_PI * (double)b->freqHz / fs;
    const double cw    = cos(w0);
    const double alpha = sin(w0) / (2.0 * (double)b->q);
    double b0, b1, b2, a0, a1, a2;

    if (b->type == EQ_LOWSHELF) {
        const double sa = 2.0 * sqrt(A) * alpha;
        b0 =        A * ((A + 1.0) - (A - 1.0) * cw + sa);
        b1 =  2.0 * A * ((A - 1.0) - (A + 1.0) * cw);
        b2 =        A * ((A + 1.0) - (A - 1.0) * cw - sa);
        a0 =             (A + 1.0) + (A - 1.0) * cw + sa;
        a1 = -2.0 *     ((A - 1.0) + (A + 1.0) * cw);
        a2 =             (A + 1.0) + (A - 1.0) * cw - sa;
    } else if (b->type == EQ_HIGHSHELF) {
        const double sa = 2.0 * sqrt(A) * alpha;
        b0 =        A * ((A + 1.0) + (A - 1.0) * cw + sa);
        b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw);
        b2 =        A * ((A + 1.0) + (A - 1.0) * cw - sa);
        a0 =             (A + 1.0) - (A - 1.0) * cw + sa;
        a1 =  2.0 *     ((A - 1.0) - (A + 1.0) * cw);
        a2 =             (A + 1.0) - (A - 1.0) * cw - sa;
    } else { /* EQ_PEAK */
        b0 = 1.0 + alpha * A;
        b1 = -2.0 * cw;
        b2 = 1.0 - alpha * A;
        a0 = 1.0 + alpha / A;
        a1 = -2.0 * cw;
        a2 = 1.0 - alpha / A;
    }

    Biquad q = { b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0 };
    if (!isfinite(q.b0) || !isfinite(q.b1) || !isfinite(q.b2) ||
        !isfinite(q.a1) || !isfinite(q.a2)) {
        return kPassthrough;
    }
    return q;
}

static double preamp_linear(float preampDB) {
    if (!isfinite(preampDB)) return 1.0;
    return pow(10.0, clampd(preampDB, -30.0, 12.0) / 20.0);
}

/* Fills one coefficient slot from the engine's stored bands. UI thread only. */
static void build_slot(const EQEngine *e, CoeffSlot *s) {
    s->count = e->bandCount;
    s->preampLin = preamp_linear(e->preampDB);
    for (int i = 0; i < EQ_MAX_BANDS; i++) {
        EQBand clean;
        if (i < e->bandCount && sanitize_band(&e->bands[i], e->fs, &clean)) {
            s->bq[i] = make_biquad(&clean, e->fs);
            s->active[i] = 1;
        } else {
            s->bq[i] = kPassthrough;
            s->active[i] = 0;
        }
    }
}

static double smoothing_coef(double fs) {
    return 1.0 - exp(-1.0 / (EQ_MASTER_TAU * fs));
}

static double soft_clip(double x) {
    const double ax = fabs(x);
    if (ax <= EQ_CLIP_KNEE) return x;
    const double room = EQ_CLIP_CEIL - EQ_CLIP_KNEE;
    const double y = EQ_CLIP_KNEE + room * tanh((ax - EQ_CLIP_KNEE) / room);
    return x < 0.0 ? -y : y;
}

/* ------------------------------------------------------------------ */
/* Lifecycle                                                           */
/* ------------------------------------------------------------------ */

EQEngine *eq_create(double sampleRate) {
    if (!(sampleRate > 0.0) || !isfinite(sampleRate)) sampleRate = 48000.0;
    EQEngine *e = (EQEngine *)calloc(1, sizeof(EQEngine));
    if (!e) return NULL;
    e->fs = sampleRate;
    e->bandCount = 0;
    e->preampDB = 0.0f;
    for (int s = 0; s < EQ_SLOTS; s++) build_slot(e, &e->slot[s]);
    atomic_init(&e->published, 0);
    atomic_init(&e->inUse, 0);
    atomic_init(&e->masterTarget, 1.0f);
    atomic_init(&e->inputGain, 1.0f);
    atomic_init(&e->bypass, 0);
    atomic_init(&e->smoothCoef, smoothing_coef(sampleRate));
    e->masterCurrent = 1.0;
    e->lastSlot = 0;
    atomic_init(&e->scopePos, 0u);
    for (int k = 0; k < EQ_SPECTRUM_FFT_MAX / 2; k++) {
        e->cosTable[k] = cos(2.0 * M_PI * k / EQ_SPECTRUM_FFT_MAX);
        e->sinTable[k] = sin(2.0 * M_PI * k / EQ_SPECTRUM_FFT_MAX);
    }
    e->windowSize = 0;   /* built on first use */
    return e;
}

void eq_destroy(EQEngine *e) {
    free(e);
}

/* ------------------------------------------------------------------ */
/* UI thread                                                           */
/* ------------------------------------------------------------------ */

int eq_set_bands(EQEngine *e, const EQBand *bands, int count, float preampDB) {
    if (!e) return 0;
    if (!bands || count < 0) count = 0;
    if (count > EQ_MAX_BANDS) count = EQ_MAX_BANDS;

    if (count > 0) memcpy(e->bands, bands, sizeof(EQBand) * (size_t)count);
    e->bandCount = count;
    e->preampDB = preampDB;

    /* Pick a slot that is neither published nor being read. One always exists. */
    const int pub = atomic_load(&e->published);
    const int use = atomic_load(&e->inUse);
    int w = 0;
    while (w == pub || w == use) w++;

    build_slot(e, &e->slot[w]);
    atomic_store(&e->published, w);
    return 1;
}

void eq_set_sample_rate(EQEngine *e, double sampleRate) {
    if (!e || !(sampleRate > 0.0) || !isfinite(sampleRate)) return;
    e->fs = sampleRate;
    for (int s = 0; s < EQ_SLOTS; s++) build_slot(e, &e->slot[s]);
    atomic_store(&e->smoothCoef, smoothing_coef(sampleRate));
    memset(e->z, 0, sizeof(e->z));
    e->masterCurrent = (double)atomic_load(&e->masterTarget);
}

void eq_set_master_gain_db(EQEngine *e, float db) {
    if (!e || isnan(db)) return;
    const double lin = pow(10.0, clampd(db, -60.0, 12.0) / 20.0);
    atomic_store(&e->masterTarget, (float)lin);
}

void eq_set_input_gain(EQEngine *e, float linear) {
    if (!e) return;
    if (!isfinite(linear)) linear = 1.0f;
    atomic_store(&e->inputGain, (float)clampd(linear, 1.0, 8.0));
}

void eq_set_bypass(EQEngine *e, int bypass) {
    if (!e) return;
    atomic_store(&e->bypass, bypass ? 1 : 0);
}

double eq_response_db(const EQBand *bands, int count, float preampDB,
                      double sampleRate, double freqHz) {
    if (!(sampleRate > 0.0) || !isfinite(sampleRate)) return 0.0;
    if (!bands || count < 0) count = 0;
    if (count > EQ_MAX_BANDS) count = EQ_MAX_BANDS;

    const double f  = clampd(freqHz, 1.0, 0.4999 * sampleRate);
    const double w  = 2.0 * M_PI * f / sampleRate;
    const double c1 = cos(w);
    const double c2 = cos(2.0 * w);

    double db = 20.0 * log10(preamp_linear(preampDB));
    for (int i = 0; i < count; i++) {
        EQBand clean;
        if (!sanitize_band(&bands[i], sampleRate, &clean)) continue;
        const Biquad q = make_biquad(&clean, sampleRate);
        const double num = q.b0 * q.b0 + q.b1 * q.b1 + q.b2 * q.b2
                         + 2.0 * (q.b0 * q.b1 + q.b1 * q.b2) * c1
                         + 2.0 * q.b0 * q.b2 * c2;
        const double den = 1.0 + q.a1 * q.a1 + q.a2 * q.a2
                         + 2.0 * (q.a1 + q.a1 * q.a2) * c1
                         + 2.0 * q.a2 * c2;
        if (num > 0.0 && den > 0.0) db += 10.0 * log10(num / den);
    }
    return db;
}

/* ------------------------------------------------------------------ */
/* Audio thread                                                        */
/* ------------------------------------------------------------------ */

void eq_process(EQEngine *e,
                const float *inL, const float *inR, int inStride,
                float *outL, float *outR, int outStride, int frames) {
    if (!e || !inL || !inR || !outL || !outR || frames <= 0) return;
    if (inStride < 1) inStride = 1;
    if (outStride < 1) outStride = 1;

    const float inGain = atomic_load(&e->inputGain);
    const unsigned scopeStart = atomic_load_explicit(&e->scopePos, memory_order_relaxed);
    const unsigned scopeMask = EQ_SCOPE_SIZE - 1;

    if (atomic_load(&e->bypass)) {
        for (int i = 0; i < frames; i++) {
            const float l = inL[i * inStride] * inGain;
            const float r = inR[i * inStride] * inGain;
            outL[i * outStride] = l;
            outR[i * outStride] = r;
            const float mono = isfinite(l + r) ? 0.5f * (l + r) : 0.0f;
            e->scope[0][(scopeStart + (unsigned)i) & scopeMask] = mono;
            e->scope[1][(scopeStart + (unsigned)i) & scopeMask] = mono;
        }
        atomic_store_explicit(&e->scopePos, scopeStart + (unsigned)frames, memory_order_release);
        return;
    }

    /* Grab the newest coefficients and mark them in use. The re-check makes sure
       the UI thread can't start rewriting this slot under us. */
    int idx = atomic_load(&e->published);
    for (int tries = 0; tries < 4; tries++) {
        atomic_store(&e->inUse, idx);
        const int again = atomic_load(&e->published);
        if (again == idx) break;
        idx = again;
    }
    const CoeffSlot *s = &e->slot[idx];

    /* A band that was off and is now on starts from silence, not stale state. */
    if (idx != e->lastSlot) {
        const CoeffSlot *prev = &e->slot[e->lastSlot];
        for (int b = 0; b < EQ_MAX_BANDS; b++) {
            if (s->active[b] && !prev->active[b]) {
                e->z[b][0][0] = e->z[b][0][1] = 0.0;
                e->z[b][1][0] = e->z[b][1][1] = 0.0;
            }
        }
        e->lastSlot = idx;
    }

    const double pre    = s->preampLin * (double)inGain;
    const double target = (double)atomic_load(&e->masterTarget);
    const double coef   = atomic_load(&e->smoothCoef);
    const int    nb     = s->count;
    double g = e->masterCurrent;
    int bad = 0;

    for (int i = 0; i < frames; i++) {
        double x[2] = { (double)inL[i * inStride] * pre, (double)inR[i * inStride] * pre };

        for (int b = 0; b < nb; b++) {
            if (!s->active[b]) continue;
            const Biquad *q = &s->bq[b];
            for (int ch = 0; ch < 2; ch++) {
                double *z = e->z[b][ch];
                const double y = q->b0 * x[ch] + z[0];
                z[0] = q->b1 * x[ch] - q->a1 * y + z[1];
                z[1] = q->b2 * x[ch] - q->a2 * y;
                x[ch] = y;
            }
        }

        g += (target - g) * coef;
        const double yl = soft_clip(x[0] * g);
        const double yr = soft_clip(x[1] * g);
        const int finite = isfinite(yl) && isfinite(yr);
        if (!finite) bad = 1;
        outL[i * outStride] = (float)yl;
        outR[i * outStride] = (float)yr;

        const unsigned slot = (scopeStart + (unsigned)i) & scopeMask;
        const double before = 0.5 * ((double)inL[i * inStride] + (double)inR[i * inStride]) * (double)inGain;
        e->scope[0][slot] = isfinite(before) ? (float)before : 0.0f;
        e->scope[1][slot] = finite ? (float)(0.5 * (yl + yr)) : 0.0f;
    }
    atomic_store_explicit(&e->scopePos, scopeStart + (unsigned)frames, memory_order_release);

    if (bad) {
        /* Something non-finite got in: silence this buffer and start clean. */
        for (int i = 0; i < frames; i++) {
            outL[i * outStride] = 0.0f;
            outR[i * outStride] = 0.0f;
        }
        memset(e->z, 0, sizeof(e->z));
        g = target;
    }
    e->masterCurrent = isfinite(g) ? g : target;
}

/* ------------------------------------------------------------------ */
/* Spectrum analyzer (UI thread)                                       */
/* ------------------------------------------------------------------ */

unsigned eq_scope_position(const EQEngine *e) {
    return e ? atomic_load_explicit(&((EQEngine *)e)->scopePos, memory_order_acquire) : 0u;
}

double eq_get_sample_rate(const EQEngine *e) {
    return e ? e->fs : 0.0;
}

/* FFT size for a sample rate: doubles until bins are no wider than ~17.6 Hz
   (4096 at 44.1/48k, 8192 at 88.2/96k, 16384 at 176.4/192k), capped at the max. */
static int spectrum_size(double fs) {
    int n = EQ_SPECTRUM_FFT;
    while (n < EQ_SPECTRUM_FFT_MAX && fs / n > 17.6) n <<= 1;
    return n;
}

/* In-place iterative radix-2 FFT of length n (a power of two, <= EQ_SPECTRUM_FFT_MAX).
   cosT/sinT hold the twiddles for EQ_SPECTRUM_FFT_MAX. */
static void fft_inplace(double *re, double *im, int n, const double *cosT, const double *sinT) {
    for (int i = 1, j = 0; i < n; i++) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            double t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }
    for (int len = 2; len <= n; len <<= 1) {
        const int half = len >> 1;
        const int step = EQ_SPECTRUM_FFT_MAX / len;
        for (int i = 0; i < n; i += len) {
            for (int k = 0; k < half; k++) {
                const double wr = cosT[k * step];
                const double wi = -sinT[k * step];
                const int a = i + k, b = a + half;
                const double vr = re[b] * wr - im[b] * wi;
                const double vi = re[b] * wi + im[b] * wr;
                re[b] = re[a] - vr;
                im[b] = im[a] - vi;
                re[a] += vr;
                im[a] += vi;
            }
        }
    }
}

int eq_spectrum(EQEngine *e, int post, double minHz, double maxHz, float *outDB, int points) {
    if (!e || !outDB || points <= 0) return 0;
    const int which = post ? 1 : 0;
    const double fs = e->fs;
    if (!(minHz > 0.0) || !(maxHz > minHz) || !(fs > 0.0)) return 0;

    const int n = spectrum_size(fs);
    if (e->windowSize != n) {
        for (int i = 0; i < n; i++) {
            e->window[i] = 0.5 - 0.5 * cos(2.0 * M_PI * i / n);   /* periodic Hann */
        }
        e->windowSize = n;
    }

    /* Copy the newest n samples out of the ring and window them. */
    const unsigned pos = atomic_load_explicit(&e->scopePos, memory_order_acquire);
    const unsigned start = pos - (unsigned)n;
    const unsigned mask = EQ_SCOPE_SIZE - 1;
    for (int i = 0; i < n; i++) {
        e->fftRe[i] = (double)e->scope[which][(start + (unsigned)i) & mask] * e->window[i];
        e->fftIm[i] = 0.0;
    }
    fft_inplace(e->fftRe, e->fftIm, n, e->cosTable, e->sinTable);

    /* Amplitude per bin, scaled so a full-scale sine reads 1.0 (Hann sum = n/2). */
    const double scale = 2.0 / (n * 0.5);
    const double binHz = fs / n;
    const int lastBin = n / 2 - 1;
    const double ratio = pow(maxHz / minHz, 1.0 / (points > 1 ? points - 1 : 1));
    const double halfStep = sqrt(ratio);

    for (int p = 0; p < points; p++) {
        const double center = minHz * pow(ratio, p);
        const double lo = center / halfStep, hi = center * halfStep;
        int kLo = (int)ceil(lo / binHz), kHi = (int)floor(hi / binHz);
        if (kLo < 1) kLo = 1;
        if (kHi > lastBin) kHi = lastBin;

        double amp = 0.0;
        if (kLo <= kHi) {
            for (int k = kLo; k <= kHi; k++) {   /* several bins in this band: take the loudest */
                const double m = sqrt(e->fftRe[k] * e->fftRe[k] + e->fftIm[k] * e->fftIm[k]);
                if (m > amp) amp = m;
            }
        } else {                                  /* band narrower than a bin: interpolate */
            double kf = center / binHz;
            if (kf < 1.0) kf = 1.0;
            if (kf > lastBin) kf = lastBin;
            const int k0 = (int)kf;
            const int k1 = k0 < lastBin ? k0 + 1 : k0;
            const double t = kf - k0;
            const double m0 = sqrt(e->fftRe[k0] * e->fftRe[k0] + e->fftIm[k0] * e->fftIm[k0]);
            const double m1 = sqrt(e->fftRe[k1] * e->fftRe[k1] + e->fftIm[k1] * e->fftIm[k1]);
            amp = m0 + (m1 - m0) * t;
        }
        double db = 20.0 * log10(amp * scale + 1e-12);
        if (!isfinite(db) || db < -120.0) db = -120.0;
        outDB[p] = (float)db;
    }
    return 1;
}

/* ------------------------------------------------------------------ */
/* Self-test                                                           */
/* ------------------------------------------------------------------ */

static void fill_sine(float *buf, int n, double freq, double fs, double amp) {
    for (int i = 0; i < n; i++) buf[i] = (float)(amp * sin(2.0 * M_PI * freq * i / fs));
}

static double rms(const float *buf, int from, int to) {
    double sum = 0.0;
    for (int i = from; i < to; i++) sum += (double)buf[i] * (double)buf[i];
    return sqrt(sum / (double)(to - from));
}

static int report(const char *name, int ok, double value) {
    printf("eq_selftest: %-34s %s (%.4f)\n", name, ok ? "PASS" : "FAIL", value);
    return ok ? 1 : 0;
}

int eq_selftest(void) {
    const double fs = 48000.0;
    const int n = 48000;
    float *in  = (float *)malloc(sizeof(float) * (size_t)n);
    float *out = (float *)malloc(sizeof(float) * (size_t)n);
    float *out2 = (float *)malloc(sizeof(float) * (size_t)n);
    if (!in || !out || !out2) {
        free(in); free(out); free(out2);
        printf("eq_selftest: out of memory\n");
        return 0;
    }
    int passed = 0;
    const EQBand peak = { EQ_PEAK, 1000.0f, 6.0f, 1.41f, 1 };

    /* a. no bands: output equals input */
    {
        EQEngine *e = eq_create(fs);
        fill_sine(in, n, 1000.0, fs, 0.5);
        eq_process(e, in, in, 1, out, out2, 1, n);
        double worst = 0.0;
        for (int i = 0; i < n; i++) {
            const double d = fabs((double)out[i] - (double)in[i]);
            if (d > worst) worst = d;
        }
        passed += report("a. flat = untouched", worst <= 1e-6, worst);
        eq_destroy(e);
    }

    /* b. response of +6 dB peak at 1 kHz */
    {
        const double at1k  = eq_response_db(&peak, 1, 0.0f, fs, 1000.0);
        const double at100 = eq_response_db(&peak, 1, 0.0f, fs, 100.0);
        const int ok = fabs(at1k - 6.0) <= 0.05 && fabs(at100) <= 0.5;
        passed += report("b. curve: +6 dB at 1k, ~0 at 100", ok, at1k);
    }

    /* c. measured gain through the engine */
    {
        EQEngine *e = eq_create(fs);
        eq_set_bands(e, &peak, 1, 0.0f);
        fill_sine(in, n, 1000.0, fs, 0.1);
        eq_process(e, in, in, 1, out, out2, 1, n);
        const double gainDB = 20.0 * log10(rms(out, n / 2, n) / rms(in, n / 2, n));
        passed += report("c. measured gain at 1 kHz", fabs(gainDB - 6.0) <= 0.2, gainDB);
        eq_destroy(e);
    }

    /* d. NaN band is ignored; a NaN input sample doesn't poison later audio */
    {
        EQEngine *e = eq_create(fs);
        EQBand bad = peak;
        bad.q = NAN;
        eq_set_bands(e, &bad, 1, 0.0f);
        fill_sine(in, n, 1000.0, fs, 0.5);
        eq_process(e, in, in, 1, out, out2, 1, n);
        int finite = 1;
        for (int i = 0; i < n; i++) if (!isfinite(out[i]) || !isfinite(out2[i])) finite = 0;

        eq_set_bands(e, &peak, 1, 0.0f);
        in[0] = NAN;
        eq_process(e, in, in, 1, out, out2, 1, 512);       /* poisoned buffer */
        fill_sine(in, n, 1000.0, fs, 0.5);
        eq_process(e, in, in, 1, out, out2, 1, n);         /* must be clean again */
        double peakOut = 0.0;
        for (int i = 0; i < n; i++) {
            if (!isfinite(out[i])) finite = 0;
            if (fabs(out[i]) > peakOut) peakOut = fabs(out[i]);
        }
        passed += report("d. NaN never reaches the output", finite && peakOut > 0.1, peakOut);
        eq_destroy(e);
    }

    /* e. +12 dB master on a loud sine stays below full scale */
    {
        EQEngine *e = eq_create(fs);
        eq_set_master_gain_db(e, 12.0f);
        fill_sine(in, n, 1000.0, fs, 0.5);
        eq_process(e, in, in, 1, out, out2, 1, n);
        double worst = 0.0;
        for (int i = 0; i < n; i++) if (fabs(out[i]) > worst) worst = fabs(out[i]);
        passed += report("e. clipper keeps |out| < 1.0", worst < 1.0, worst);
        eq_destroy(e);
    }

    /* f. analyzer: a -12 dBFS 1 kHz sine reads about -12 before the EQ and about -6 after +6 dB */
    {
        EQEngine *e = eq_create(fs);
        eq_set_bands(e, &peak, 1, 0.0f);
        fill_sine(in, n, 1000.0, fs, 0.25);
        eq_process(e, in, in, 1, out, out2, 1, n);
        float before[200], after[200];
        eq_spectrum(e, 0, 20.0, 20000.0, before, 200);
        eq_spectrum(e, 1, 20.0, 20000.0, after, 200);
        int peakIndex = 0;
        for (int i = 1; i < 200; i++) if (after[i] > after[peakIndex]) peakIndex = i;
        const double peakHz = 20.0 * pow(1000.0, peakIndex / 199.0);
        float beforePeak = -200.0f;
        for (int i = 0; i < 200; i++) if (before[i] > beforePeak) beforePeak = before[i];
        int ok = fabs(peakHz - 1000.0) < 60.0
              && fabs(after[peakIndex] - (-6.02)) <= 1.0
              && fabs(beforePeak - (-12.04)) <= 1.0
              && after[0] < -80.0f;
        eq_destroy(e);

        /* Same check at 192 kHz (bigger FFT). */
        const double hiFs = 192000.0;
        e = eq_create(hiFs);
        eq_set_bands(e, &peak, 1, 0.0f);
        fill_sine(in, n, 1000.0, hiFs, 0.25);
        eq_process(e, in, in, 1, out, out2, 1, n);
        eq_spectrum(e, 1, 20.0, 20000.0, after, 200);
        int hiIndex = 0;
        for (int i = 1; i < 200; i++) if (after[i] > after[hiIndex]) hiIndex = i;
        const double hiHz = 20.0 * pow(1000.0, hiIndex / 199.0);
        ok = ok && fabs(hiHz - 1000.0) < 60.0
                && fabs(after[hiIndex] - (-6.02)) <= 1.0
                && after[0] < -80.0f;
        eq_destroy(e);
        passed += report("f. analyzer sees the EQ change", ok, after[hiIndex]);
    }

    free(in); free(out); free(out2);
    printf("eq_selftest: %d/6 passed\n", passed);
    return passed;
}
