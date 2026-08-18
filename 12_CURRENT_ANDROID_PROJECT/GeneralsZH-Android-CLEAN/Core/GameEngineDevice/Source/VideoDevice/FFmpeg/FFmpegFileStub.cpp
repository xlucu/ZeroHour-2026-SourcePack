// FFmpegFileStub.cpp — Android stub for FFmpegFile (no ffmpeg available yet).
// GeneralsX @feature android-port 06/07/2026
//
// Provides empty implementations of every FFmpegFile method so the engine links
// without ffmpeg. All audio/video decoding returns failure/no-op: the game boots
// and renders, but speech/EVA audio and intro videos are silent. Replace with
// the real FFmpegFile.cpp once ffmpeg is hand-built for Android arm64.
#include "VideoDevice/FFmpeg/FFmpegFile.h"
#include "Common/file.h"

FFmpegFile::FFmpegFile() {}
FFmpegFile::FFmpegFile(File *file) { (void)file; }
FFmpegFile::~FFmpegFile() {}

Bool FFmpegFile::open(File *file) { (void)file; return FALSE; }
void FFmpegFile::close() {}
Bool FFmpegFile::decodePacket() { return FALSE; }
void FFmpegFile::seekFrame(int frame_idx) { (void)frame_idx; }
Bool FFmpegFile::hasAudio() const { return FALSE; }

Int FFmpegFile::getSizeForSamples(Int numSamples) const { (void)numSamples; return 0; }
Int FFmpegFile::getNumChannels() const { return 0; }
Int FFmpegFile::getSampleRate() const { return 0; }
Int FFmpegFile::getBytesPerSample() const { return 0; }

Int FFmpegFile::getWidth() const { return 0; }
Int FFmpegFile::getHeight() const { return 0; }
Int FFmpegFile::getNumFrames() const { return 0; }
Int FFmpegFile::getCurrentFrame() const { return 0; }
Int FFmpegFile::getPixelFormat() const { return 0; }
UnsignedInt FFmpegFile::getFrameTime() const { return 0; }

Int FFmpegFile::readPacket(void *opaque, UnsignedByte *buf, Int buf_size) {
    (void)opaque; (void)buf; (void)buf_size; return 0;
}
const FFmpegFile::FFmpegStream *FFmpegFile::findMatch(int type) const {
    (void)type; return nullptr;
}
