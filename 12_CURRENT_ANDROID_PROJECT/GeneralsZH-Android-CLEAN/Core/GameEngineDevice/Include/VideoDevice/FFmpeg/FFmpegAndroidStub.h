// GeneralsX @feature android-port 06/07/2026
// FFmpeg is not yet ported to Android (vcpkg ffmpeg:arm64-android is broken).
// This stub provides the minimal type/function/enum declarations the engine's
// audio and video code references, so it compiles and links. All functions are
// no-ops returning failure — audio decoding and video playback are disabled
// until a real ffmpeg is hand-built for Android. The game boots and renders
// without it.
#pragma once

#ifdef __ANDROID__

#include <cstdint>
#include <cstdlib>

// Minimal AVFrame stub — covers all fields the engine reads.
struct AVFrame {
    int format;
    int nb_samples;
    int sample_rate;
    uint8_t *data[8];
    struct AVChannelLayout { int nb_channels; } ch_layout;
};

// Media type constants.
enum AVMediaType {
    AVMEDIA_TYPE_UNKNOWN = -1,
    AVMEDIA_TYPE_VIDEO = 0,
    AVMEDIA_TYPE_AUDIO = 1,
    AVMEDIA_TYPE_DATA = 2,
    AVMEDIA_TYPE_SUBTITLE = 3,
};

// Sample format enum stub.
enum AVSampleFormat { AV_SAMPLE_FMT_NONE = 0, AV_SAMPLE_FMT_S16 = 1 };

// Stub ffmpeg functions referenced by the engine.
inline int av_get_bytes_per_sample(int) { return 2; }
inline int av_samples_get_buffer_size(void*, int, int, int, int) { return 0; }
inline int av_sample_fmt_is_planar(int) { return 0; }
inline void* av_malloc(size_t n) { return malloc(n); }
inline void av_freep(void *p) { void **pp = (void**)p; if (pp && *pp) { free(*pp); *pp = nullptr; } }
inline void av_free(void *p) { free(p); }

#endif // __ANDROID__
