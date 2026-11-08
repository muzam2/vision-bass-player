//
//  Shaders.metal
#include <metal_stdlib>
using namespace metal;

struct VertexIn
{
    float4 pos [[attribute(0)]];
    float2 uv [[attribute(1)]];
};

struct VertexOut {
    float4 renderedCoordinate [[position]];
    float2 textureCoordinate;
};

vertex VertexOut mapTexture(VertexIn input [[stage_in]]) {
    VertexOut outVertex;
    outVertex.renderedCoordinate = input.pos;
    outVertex.textureCoordinate = input.uv;
    return outVertex;
}

vertex VertexOut mapSphereTexture(VertexIn input [[stage_in]], constant float4x4& uniforms [[ buffer(2) ]]) {
    VertexOut outVertex;
    outVertex.renderedCoordinate = uniforms * input.pos;
    outVertex.textureCoordinate = input.uv;
    return outVertex;
}

fragment half4 displayTexture(VertexOut mappingVertex [[ stage_in ]],
                              texture2d<half, access::sample> texture [[ texture(0) ]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    return half4(texture.sample(s, mappingVertex.textureCoordinate));
}

fragment half4 displayYUVTexture(VertexOut in [[ stage_in ]],
                                  texture2d<half> yTexture [[ texture(0) ]],
                                  texture2d<half> uTexture [[ texture(1) ]],
                                  texture2d<half> vTexture [[ texture(2) ]],
                                  sampler textureSampler [[ sampler(0) ]],
                                  constant float3x3& yuvToBGRMatrix [[ buffer(0) ]],
                                  constant float3& colorOffset [[ buffer(1) ]],
                                  constant uchar3& leftShift [[ buffer(2) ]])
{
    half3 yuv;
    yuv.x = yTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.y = uTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.z = vTexture.sample(textureSampler, in.textureCoordinate).r;
    return half4(half3x3(yuvToBGRMatrix)*(yuv*half3(leftShift)+half3(colorOffset)), 1);
}


fragment half4 displayNV12Texture(VertexOut in [[ stage_in ]],
                                  texture2d<half> lumaTexture [[ texture(0) ]],
                                  texture2d<half> chromaTexture [[ texture(1) ]],
                                  sampler textureSampler [[ sampler(0) ]],
                                  constant float3x3& yuvToBGRMatrix [[ buffer(0) ]],
                                  constant float3& colorOffset [[ buffer(1) ]],
                                  constant uchar3& leftShift [[ buffer(2) ]])
{
    half3 yuv;
    yuv.x = lumaTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.yz = chromaTexture.sample(textureSampler, in.textureCoordinate).rg;
    return half4(half3x3(yuvToBGRMatrix)*(yuv*half3(leftShift)+half3(colorOffset)), 1);
}

half3 shaderLinearize(half3 rgb) {
    rgb = pow(max(rgb,0), half3(4096.0/(2523 * 128)));
    rgb = max(rgb - half3(3424./4096), 0.0) / (half3(2413./4096 * 32) - half3(2392./4096 * 32) * rgb);
    rgb = pow(rgb, half3(4096.0 * 4 / 2610));
    return rgb;
}

half3 shaderDeLinearize(half3 rgb) {
    rgb = pow(max(rgb,0), half3(2610./4096 / 4));
    rgb = (half3(3424./4096) - half3(2413./4096 * 32) * rgb) / (half3(1.0) + half3(2392./4096 * 32) * rgb);
    rgb = pow(rgb, half3(2523./4096 * 128));
    return rgb;
}

fragment half4 displayYCCTexture(VertexOut in [[ stage_in ]],
                                  texture2d<half> lumaTexture [[ texture(0) ]],
                                  texture2d<half> chromaTexture [[ texture(1) ]],
                                  sampler textureSampler [[ sampler(0) ]],
                                  constant float3x3& yuvToBGRMatrix [[ buffer(0) ]],
                                  constant float3& colorOffset [[ buffer(1) ]],
                                  constant uchar3& leftShift [[ buffer(2) ]])
{
    half3 ipt;
    ipt.x = lumaTexture.sample(textureSampler, in.textureCoordinate).r;
    ipt.yz = chromaTexture.sample(textureSampler, in.textureCoordinate).rg;
//    half3x3 ipt2lms = half3x3{{1, 0.1952, 0.4104}, {1, -0.2278, 0.2264}, {1, 0.0652, -1.3538}};
//    half3x3 lms2rgb = half3x3{{3.238998, -0.719461, -0.002862}, {-2.272734, 1.874998, -0.268066}, {0.086733, -0.158947, 1.074494}};
    half3x3 ipt2lms = half3x3{{1, 799/8192, 1681/8192}, {1, -933/8192, 1091/8192}, {1, 267/8192, -5545/8192}};
    half3x3 lms2rgb = half3x3{{3.43661, -0.79133, -0.0259499}, {-2.50645, 1.98360, -0.0989137}, {0.06984, -0.192271, 1.12486}};
    half3 lms = ipt2lms*ipt;
    lms = shaderLinearize(lms);
    half3 rgb = lms2rgb*lms;
    rgb = shaderDeLinearize(rgb);
    return half4(rgb, 1);
}

// ---------------------------------------------------------------------------------------------
// Dolby Vision profile 5 (IPT-PQ-C2) — vendored addition for Bass Player.
// The RPU reshaping and colour matrices arrive as one flat float array (see DoviMetadata.Layout).
// Pipeline: normalised code values → per-component reshape (polynomial or MMR) → subtract offset
// → ycc_to_rgb matrix (gives PQ-encoded LMS) → PQ EOTF → rgb_to_lms matrix (gives linear BT.2020
// RGB) → PQ OETF for an ITU-R 2100 PQ layer.
// ---------------------------------------------------------------------------------------------

#define DOVI_NUM_PIVOTS      0
#define DOVI_PIVOTS          3
#define DOVI_METHOD          30
#define DOVI_POLY_COEF       54
#define DOVI_MMR_ORDER       126
#define DOVI_MMR_CONSTANT    150
#define DOVI_MMR_COEF        174
#define DOVI_NONLINEAR       678
#define DOVI_NONLINEAR_OFF   687
#define DOVI_LINEAR          690

static inline float3 pqEOTF(float3 e) {
    const float m1 = 2610.0 / 16384.0, m2 = 2523.0 / 32.0;
    const float c1 = 3424.0 / 4096.0, c2 = 2413.0 / 128.0, c3 = 2392.0 / 128.0;
    float3 p = pow(max(e, 0.0), float3(1.0 / m2));
    float3 num = max(p - c1, 0.0);
    float3 den = c2 - c3 * p;
    return pow(num / den, float3(1.0 / m1));          // 0…1 == 0…10000 nits
}

static inline float3 pqOETF(float3 l) {
    const float m1 = 2610.0 / 16384.0, m2 = 2523.0 / 32.0;
    const float c1 = 3424.0 / 4096.0, c2 = 2413.0 / 128.0, c3 = 2392.0 / 128.0;
    float3 p = pow(max(l, 0.0), float3(m1));
    return pow((c1 + c2 * p) / (1.0 + c3 * p), float3(m2));
}

static inline float doviMMR(constant float* d, int c, int piece, float3 sig) {
    int order = int(d[DOVI_MMR_ORDER + c * 8 + piece]);
    float s = d[DOVI_MMR_CONSTANT + c * 8 + piece];
    float3 xo = sig;                        // sig^(o+1), updated each iteration
    for (int o = 0; o < order; o++) {
        int base = DOVI_MMR_COEF + ((c * 8 + piece) * 3 + o) * 7;
        // Terms: x, y, z, xy, xz, yz, xyz of the current power.
        s += d[base + 0] * xo.x + d[base + 1] * xo.y + d[base + 2] * xo.z
           + d[base + 3] * xo.x * xo.y + d[base + 4] * xo.x * xo.z + d[base + 5] * xo.y * xo.z
           + d[base + 6] * xo.x * xo.y * xo.z;
        xo *= sig;
    }
    return s;
}

static inline float3 doviReshape(constant float* d, float3 sig) {
    float3 out = sig;
    for (int c = 0; c < 3; c++) {
        int n = int(d[DOVI_NUM_PIVOTS + c]);
        float s = sig[c];
        if (n < 2) continue;
        float lo = d[DOVI_PIVOTS + c * 9];
        float hi = d[DOVI_PIVOTS + c * 9 + n - 1];
        s = clamp(s, lo, hi);
        int piece = 0;
        for (int i = 1; i < n - 1; i++) {
            if (s >= d[DOVI_PIVOTS + c * 9 + i]) piece = i;
        }
        if (d[DOVI_METHOD + c * 8 + piece] > 0.5) {
            out[c] = doviMMR(d, c, piece, sig);
        } else {
            int base = DOVI_POLY_COEF + (c * 8 + piece) * 3;
            out[c] = d[base] + s * (d[base + 1] + s * d[base + 2]);
        }
    }
    return out;
}

static inline float4 doviToPQ(float3 ycc, constant float* d) {
    float3 r = doviReshape(d, ycc);
    r -= float3(d[DOVI_NONLINEAR_OFF], d[DOVI_NONLINEAR_OFF + 1], d[DOVI_NONLINEAR_OFF + 2]);
    // Row-major 3x3 in the array; Metal float3x3 is column-major, so build columns explicitly.
    float3x3 nonlinear = float3x3(float3(d[DOVI_NONLINEAR + 0], d[DOVI_NONLINEAR + 3], d[DOVI_NONLINEAR + 6]),
                                  float3(d[DOVI_NONLINEAR + 1], d[DOVI_NONLINEAR + 4], d[DOVI_NONLINEAR + 7]),
                                  float3(d[DOVI_NONLINEAR + 2], d[DOVI_NONLINEAR + 5], d[DOVI_NONLINEAR + 8]));
    float3x3 linearM = float3x3(float3(d[DOVI_LINEAR + 0], d[DOVI_LINEAR + 3], d[DOVI_LINEAR + 6]),
                                float3(d[DOVI_LINEAR + 1], d[DOVI_LINEAR + 4], d[DOVI_LINEAR + 7]),
                                float3(d[DOVI_LINEAR + 2], d[DOVI_LINEAR + 5], d[DOVI_LINEAR + 8]));
    float3 lmsPQ = nonlinear * r;
    float3 lms = pqEOTF(lmsPQ);
    float3 rgb = max(linearM * lms, 0.0);            // linear BT.2020, 1.0 == 10000 nits
    return float4(pqOETF(rgb), 1.0);
}

fragment float4 displayDoviNV12Texture(VertexOut in [[ stage_in ]],
                                       texture2d<float> lumaTexture [[ texture(0) ]],
                                       texture2d<float> chromaTexture [[ texture(1) ]],
                                       sampler textureSampler [[ sampler(0) ]],
                                       constant uchar3& leftShift [[ buffer(2) ]],
                                       constant float* dovi [[ buffer(3) ]])
{
    float3 ycc;
    ycc.x = lumaTexture.sample(textureSampler, in.textureCoordinate).r;
    ycc.yz = chromaTexture.sample(textureSampler, in.textureCoordinate).rg;
    ycc *= float3(leftShift);
    return doviToPQ(ycc, dovi);
}

fragment float4 displayDoviYUVTexture(VertexOut in [[ stage_in ]],
                                      texture2d<float> yTexture [[ texture(0) ]],
                                      texture2d<float> uTexture [[ texture(1) ]],
                                      texture2d<float> vTexture [[ texture(2) ]],
                                      sampler textureSampler [[ sampler(0) ]],
                                      constant uchar3& leftShift [[ buffer(2) ]],
                                      constant float* dovi [[ buffer(3) ]])
{
    float3 ycc;
    ycc.x = yTexture.sample(textureSampler, in.textureCoordinate).r;
    ycc.y = uTexture.sample(textureSampler, in.textureCoordinate).r;
    ycc.z = vTexture.sample(textureSampler, in.textureCoordinate).r;
    ycc *= float3(leftShift);
    return doviToPQ(ycc, dovi);
}
