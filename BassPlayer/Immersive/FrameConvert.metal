#include <metal_stdlib>
using namespace metal;

// Software-decoded frames arrive as separate Y / Cb / Cr planes (FFmpeg yuv420p, yuv420p10).
// The immersive screen's AVSampleBufferVideoRenderer wants a bi-planar (NV12 / P010-style)
// CVPixelBuffer, so these two kernels repack the planes. `scale` is 1 for 8-bit and for
// MSB-aligned 10-bit; 64 (2^6) lifts LSB-aligned 10-bit samples into P010's MSB alignment.

kernel void copyPlane(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float &scale [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    dst.write(src.read(gid) * scale, gid);
}

kernel void interleaveChroma(texture2d<float, access::read> cb [[texture(0)]],
                             texture2d<float, access::read> cr [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             constant float &scale [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    dst.write(float4(cb.read(gid).r * scale, cr.read(gid).r * scale, 0.0, 1.0), gid);
}
