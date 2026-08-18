#ifndef QUILL_WEBRTC_AUDIO_H
#define QUILL_WEBRTC_AUDIO_H

#ifdef __cplusplus
extern "C" {
#endif

typedef void *QuillEchoCanceller;

QuillEchoCanceller quill_aec_create(int sample_rate);
void quill_aec_destroy(QuillEchoCanceller canceller);
int quill_aec_process(
    QuillEchoCanceller canceller,
    const float *near_audio,
    const float *far_audio,
    float *output,
    int sample_count
);

#ifdef __cplusplus
}
#endif

#endif
