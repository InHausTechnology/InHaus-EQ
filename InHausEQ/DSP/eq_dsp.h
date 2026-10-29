//
//  eq_dsp.h
//  InHausEQ
//
//  Real-time EQ core: biquad filters, master gain, soft clipper.
//  Plain C11 so it is safe to call from the Core Audio IOProc.
//

#ifndef EQ_DSP_H
#define EQ_DSP_H

#ifdef __cplusplus
extern "C" {
#endif

/* Filter types. From Swift: Int32(EQ_PEAK.rawValue) */
typedef enum { EQ_PEAK = 0, EQ_LOWSHELF = 1, EQ_HIGHSHELF = 2 } EQFilterType;

/* One filter band. From Swift:
   EQBand(type: Int32(EQ_PEAK.rawValue), freqHz: 1000, gainDB: 6, q: 1.41, enabled: 1) */
typedef struct {
    int   type;     /* EQFilterType */
    float freqHz;
    float gainDB;
    float q;
    int   enabled;  /* 1 = on, 0 = off */
} EQBand;

#define EQ_MAX_BANDS 24

typedef struct EQEngine EQEngine; /* opaque; Swift sees it as OpaquePointer */

EQEngine *eq_create(double sampleRate);
void      eq_destroy(EQEngine *e);

/* ---- UI thread (one thread only) ---- */

/* Publishes a new set of bands. Lock-free; always returns 1. */
int    eq_set_bands(EQEngine *e, const EQBand *bands, int count, float preampDB);
/* Call only while audio is stopped. Recomputes filters and clears their state. */
void   eq_set_sample_rate(EQEngine *e, double sampleRate);
/* Master gain in dB, clamped -60...+12. Smoothed over ~30 ms on the audio thread. */
void   eq_set_master_gain_db(EQEngine *e, float db);
/* Linear input gain (tap headroom fix), clamped 1...8. */
void   eq_set_input_gain(EQEngine *e, float linear);
/* 1 = bypass (input * inputGain straight through), 0 = normal. */
void   eq_set_bypass(EQEngine *e, int bypass);
/* Pure function for the UI curve: whole-chain magnitude at freqHz, in dB, preamp included. */
double eq_response_db(const EQBand *bands, int count, float preampDB,
                      double sampleRate, double freqHz);
/* Runs 6 checks, prints each result, returns how many passed. Not real-time safe. */
int    eq_selftest(void);

/* ---- Spectrum analyzer (UI thread) ---- */

#define EQ_SPECTRUM_FFT     4096    /* FFT size at 44.1 / 48 kHz */
#define EQ_SPECTRUM_FFT_MAX 16384   /* at 176.4 / 192 kHz and up */

/* Level of the most recent ~85 ms of audio (mono mix of L and R), measured in `points`
   log-spaced bands from minHz to maxHz. The FFT grows with the sample rate (4096 at 48k,
   8192 at 96k, 16384 at 192k) so the bass detail is the same at every rate.
   Results are dBFS: a full-scale sine reads about 0 dB, silence -120.
   post = 1: after the EQ and volume (what you hear); post = 0: before the EQ.
   Returns 1 on success. */
int      eq_spectrum(EQEngine *e, int post, double minHz, double maxHz, float *outDB, int points);
/* Counts samples processed so far (wraps around). If it stops changing, audio has stopped. */
unsigned eq_scope_position(const EQEngine *e);
/* The sample rate the engine is running at. */
double   eq_get_sample_rate(const EQEngine *e);

/* ---- Audio thread ---- */

/* Processes `frames` stereo frames. Strides are in floats:
   interleaved stereo -> inL = buf, inR = buf + 1, inStride = 2.
   Real-time safe: no allocation, no locks, no I/O. */
void   eq_process(EQEngine *e,
                  const float *inL, const float *inR, int inStride,
                  float *outL, float *outR, int outStride, int frames);

#ifdef __cplusplus
}
#endif

#endif /* EQ_DSP_H */
