#include "egl_renderer.h"

#include <algorithm>
#include <cstring>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <native_image/native_image.h>
#include <native_window/external_window.h>

namespace jellyfin {
namespace player {
namespace {

const char *kVertexShader = R"(#version 300 es
layout(location = 0) in vec2 aPos;
layout(location = 1) in vec2 aUv;
uniform vec2 uScale;
out vec2 vUv;
void main() {
    vUv = aUv;
    gl_Position = vec4(aPos * uScale, 0.0, 1.0);
}
)";

const char *kFragmentShader = R"(#version 300 es
precision mediump float;
in vec2 vUv;
uniform sampler2D uTex;
out vec4 fragColor;
void main() {
    fragColor = texture(uTex, vUv);
}
)";

unsigned int CompileShader(GLenum type, const char *src, std::string &error)
{
    const unsigned int shader = glCreateShader(type);
    glShaderSource(shader, 1, &src, nullptr);
    glCompileShader(shader);
    GLint ok = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[512] = {0};
        glGetShaderInfoLog(shader, sizeof(log) - 1, nullptr, log);
        error = std::string("着色器编译失败：") + log;
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

} // namespace

EglRenderer::~EglRenderer()
{
    destroy();
}

bool EglRenderer::init(uint64_t surfaceId, std::string &error, int requestedWidth, int requestedHeight)
{
    destroy();
    surfaceId_ = surfaceId;

    OHNativeWindow *window = nullptr;
    const int32_t rc = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window);
    if (rc != 0 || window == nullptr) {
        error = "无法从 surfaceId 创建 native window（rc=" + std::to_string(rc) + "）";
        return false;
    }
    nativeWindow_ = window;
    // 与官方 XComponent 路径共用同一套初始化，避免两条序列各自演化（本会话踩过这类坑）
    return initWithWindow(window, requestedWidth, requestedHeight, error);
}

bool EglRenderer::buildProgram(std::string &error)
{
    const unsigned int vs = CompileShader(GL_VERTEX_SHADER, kVertexShader, error);
    if (vs == 0) {
        return false;
    }
    const unsigned int fs = CompileShader(GL_FRAGMENT_SHADER, kFragmentShader, error);
    if (fs == 0) {
        glDeleteShader(vs);
        return false;
    }
    const unsigned int program = glCreateProgram();
    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);
    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    glDeleteShader(vs);
    glDeleteShader(fs);
    if (linked != GL_TRUE) {
        char log[512] = {0};
        glGetProgramInfoLog(program, sizeof(log) - 1, nullptr, log);
        error = std::string("着色器链接失败：") + log;
        glDeleteProgram(program);
        return false;
    }
    program_ = program;
    // 按名字查询 attribute 位置：不能假定 layout(location=…) 一定生效，
    // 否则 glVertexAttribPointer 绑到无效位置 → 绘制变成空操作（画面全黑但 GL 无错误）。
    attribPos_ = glGetAttribLocation(program, "aPos");
    attribUv_ = glGetAttribLocation(program, "aUv");
    uniformTex_ = glGetUniformLocation(program, "uTex");
    uniformScale_ = glGetUniformLocation(program, "uScale");
    if (attribPos_ < 0 || attribUv_ < 0) {
        error = "着色器 attribute 未找到（aPos=" + std::to_string(attribPos_) + ", aUv="
                + std::to_string(attribUv_) + "）";
        glDeleteProgram(program);
        program_ = 0;
        return false;
    }
    return true;
}

bool EglRenderer::renderRgba(const uint8_t *rgba, int width, int height, std::string &error)
{
    if (!drawFrame(rgba, width, height, error)) {
        return false;
    }
    if (eglSwapBuffers(static_cast<EGLDisplay>(display_), static_cast<EGLSurface>(surface_)) != EGL_TRUE) {
        error = "eglSwapBuffers 失败（EGL 0x" + std::to_string(eglGetError()) + "，几何 "
                + std::to_string(surfaceWidth_) + "x" + std::to_string(surfaceHeight_)
                + "，初始化时几何 " + geometryAtInit_ + "）";
        return false;
    }
    if (nativeImage_ != nullptr) {
        // TEXTURE 路径：**先 swap 出 buffer 再发布**，否则 UpdateSurfaceImage 返回
        // NATIVE_ERROR_NO_BUFFER(40601000)（实测过这个顺序错误）
        const int32_t updated = OH_NativeImage_UpdateSurfaceImage(static_cast<OH_NativeImage *>(nativeImage_));
        if (updated != 0) {
            error = "OH_NativeImage_UpdateSurfaceImage 失败（" + std::to_string(updated) + "）";
            return false;
        }
    }
    return true;
}

/**
 * 重绘最近一帧并在 **swap 之前** 回读帧缓冲。
 *
 * 为什么必须重绘：`eglSwapBuffers` 之后后台缓冲内容未定义，此时 `glReadPixels` 读到的是全黑
 * （实测 autoDump 导出 1260x2619 全黑，而 swap 前的清屏自检能正确读到红色）。
 * 因此导出渲染帧的正确做法是：重新绘制一次 → 立刻回读 → 不 swap（避免污染上屏内容）。
 */
bool EglRenderer::redrawAndReadback(const uint8_t *rgba, int width, int height,
                                    std::vector<uint8_t> &out, int &outWidth, int &outHeight,
                                    std::string &error)
{
    if (nativeImage_ != nullptr) {
        // TEXTURE 路径的内容在 XComponent 的纹理里，没有可回读的帧缓冲；
        // 如实报错，让上层改用截图或"导出解码帧"来验证（不给出误导性的黑图）。
        error = "TEXTURE 路径不支持帧缓冲回读（内容在 XComponent 纹理中）";
        return false;
    }
    if (!drawFrame(rgba, width, height, error)) {
        return false;
    }
    glFinish();
    return readbackRgba(out, outWidth, outHeight, error);
}

/** 渲染缓冲最大宽度：软件 GL（模拟器）无法承受全屏尺寸的每帧交换，限制到视频量级 */
constexpr int32_t kMaxRenderWidth = 640;

/** 上传纹理并绘制一帧（不含 swap 与发布），供 renderRgba 与导出前重绘共用 */
bool EglRenderer::drawFrame(const uint8_t *rgba, int width, int height, std::string &error)
{
    if (!ready_ || rgba == nullptr || width <= 0 || height <= 0) {
        error = "渲染器未就绪或帧无效";
        return false;
    }
    eglMakeCurrent(static_cast<EGLDisplay>(display_), static_cast<EGLSurface>(surface_),
                   static_cast<EGLSurface>(surface_), static_cast<EGLContext>(context_));

    // 每帧都重新查询 surface 几何。
    //
    // 为什么不能只在初始化时查一次：宿主会按「视频比例」调整 XComponent 的尺寸
    // （见 ArkTS 的 PlayerAspect），surface 的缓冲尺寸随之改变；沿用旧尺寸会让
    // glViewport 与顶点缩放都按旧几何计算 —— 表现为切比例后画面被拉伸/位置偏移。
    // eglQuerySurface 只读属性，代价可忽略。
    {
        EGLint qw = 0;
        EGLint qh = 0;
        eglQuerySurface(static_cast<EGLDisplay>(display_), static_cast<EGLSurface>(surface_),
                        EGL_WIDTH, &qw);
        eglQuerySurface(static_cast<EGLDisplay>(display_), static_cast<EGLSurface>(surface_),
                        EGL_HEIGHT, &qh);
        if (qw > 0 && qh > 0) {
            surfaceWidth_ = qw;
            surfaceHeight_ = qh;
        }
    }
    // 上下文可能在 surface 重建后失效：每次渲染前确保 current
    eglMakeCurrent(static_cast<EGLDisplay>(display_), static_cast<EGLSurface>(surface_),
                   static_cast<EGLSurface>(surface_), static_cast<EGLContext>(context_));
    glViewport(0, 0, surfaceWidth_, surfaceHeight_);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glUseProgram(program_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, texture_);
    // 每帧都重设纹理参数：纹理可能因某些驱动/平台状态被重置，
    // 一旦采样器认为纹理不完整，采样结果就是**全黑且无 GL 错误**（正是本会话踩到的现象）。
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR) {
        // 不检查 GL 错误会让"上传失败 → 整幅黑"看起来像"渲染成功"
        error = "glTexImage2D 失败（0x" + std::to_string(glErr) + "，帧 " + std::to_string(width) + "x"
                + std::to_string(height) + "）";
        return false;
    }
    glUniform1i(uniformTex_, 0);
    // 画面比例：顶点缩放 = (帧尺寸 × 比例系数) / surface 尺寸，>1 的部分被视口裁掉。
    if (uniformScale_ >= 0) {
        const float sx = static_cast<float>(surfaceWidth_ > 0 ? surfaceWidth_ : 1);
        const float sy = static_cast<float>(surfaceHeight_ > 0 ? surfaceHeight_ : 1);
        const float fx = static_cast<float>(width);
        const float fy = static_cast<float>(height);
        if (scaleMode_ == ScaleMode::Stretch) {
            // 非等比铺满：直接用满屏顶点，不缩放
            glUniform2f(uniformScale_, 1.0f, 1.0f);
        } else {
            float k = 1.0f;
            if (scaleMode_ == ScaleMode::Contain) {
                k = std::min(sx / fx, sy / fy);   // 完整可见：取小系数，多余区域留黑边
            } else if (scaleMode_ == ScaleMode::Cover) {
                k = std::max(sx / fx, sy / fy);   // 铺满并裁剪：取大系数，超出部分由视口裁掉
            } else {
                k = std::min(1.0f, std::min(sx / fx, sy / fy));  // 原始：1:1；装不下时退回适应
            }
            glUniform2f(uniformScale_, (fx * k) / sx, (fy * k) / sy);
        }
    }

    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glEnableVertexAttribArray(static_cast<GLuint>(attribPos_));
    glVertexAttribPointer(static_cast<GLuint>(attribPos_), 2, GL_FLOAT, GL_FALSE,
                          4 * sizeof(float), reinterpret_cast<void *>(0));
    glEnableVertexAttribArray(static_cast<GLuint>(attribUv_));
    glVertexAttribPointer(static_cast<GLuint>(attribUv_), 2, GL_FLOAT, GL_FALSE,
                          4 * sizeof(float), reinterpret_cast<void *>(2 * sizeof(float)));
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glErr = glGetError();
    if (glErr != GL_NO_ERROR) {
        error = "glDrawArrays 失败（0x" + std::to_string(glErr) + "）";
        return false;
    }
    return true;
}

bool EglRenderer::readbackRgba(std::vector<uint8_t> &out, int &width, int &height, std::string &error)
{
    if (!ready_ || surfaceWidth_ <= 0 || surfaceHeight_ <= 0) {
        error = "渲染器未就绪";
        return false;
    }
    width = surfaceWidth_;
    height = surfaceHeight_;
    out.assign(static_cast<size_t>(width) * height * 4u, 0);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, out.data());
    const GLenum glErr = glGetError();
    if (glErr != GL_NO_ERROR) {
        error = "glReadPixels 失败（0x" + std::to_string(glErr) + "）";
        return false;
    }
    // GL 原点在左下：翻转为自上而下，便于直接编码 PNG
    const size_t stride = static_cast<size_t>(width) * 4u;
    std::vector<uint8_t> tmp(stride);
    for (int y = 0; y < height / 2; ++y) {
        uint8_t *top = out.data() + static_cast<size_t>(y) * stride;
        uint8_t *bottom = out.data() + static_cast<size_t>(height - 1 - y) * stride;
        std::memcpy(tmp.data(), top, stride);
        std::memcpy(top, bottom, stride);
        std::memcpy(bottom, tmp.data(), stride);
    }
    return true;
}

bool EglRenderer::initFromTexture(uint32_t textureId, std::string &error, int requestedWidth,
                                int requestedHeight)
{
    destroy();
    requestedWidth_ = requestedWidth;
    requestedHeight_ = requestedHeight;

    OH_NativeImage *image = OH_NativeImage_Create(textureId, GL_TEXTURE_2D);
    if (image == nullptr) {
        error = "OH_NativeImage_Create 失败（textureId=" + std::to_string(textureId) + "）";
        return false;
    }
    nativeImage_ = image;
    OHNativeWindow *window = OH_NativeImage_AcquireNativeWindow(image);
    if (window == nullptr) {
        error = "OH_NativeImage_AcquireNativeWindow 失败";
        destroy();
        return false;
    }
    nativeWindow_ = window;

    return initWithWindow(window, requestedWidth, requestedHeight, error);
}

/**
 * 官方路径入口：window 由 ArkUI 经 `OH_NativeXComponent` 回调给出（见 xcomponent_bridge.h），
 * 尺寸取 `OH_NativeXComponent_GetXComponentSize()`。与 surfaceId 路径共用同一套初始化。
 */
bool EglRenderer::initFromWindow(void *nativeWindow, int width, int height, std::string &error)
{
    destroy();
    if (nativeWindow == nullptr) {
        error = "XComponent window 为空（surface 尚未创建）";
        return false;
    }
    requestedWidth_ = width;
    requestedHeight_ = height;
    nativeWindow_ = nativeWindow;
    return initWithWindow(nativeWindow, width, height, error);
}

/** 两条路径共用的初始化：EGL display/config/context、程序、纹理与顶点缓冲 */
bool EglRenderer::initWithWindow(void *windowPtr, int requestedWidth, int requestedHeight,
                                 std::string &error)
{
    OHNativeWindow *window = static_cast<OHNativeWindow *>(windowPtr);
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint major = 0;
    EGLint minor = 0;
    if (display == EGL_NO_DISPLAY || eglInitialize(display, &major, &minor) != EGL_TRUE) {
        error = "eglInitialize 失败";
        destroy();
        return false;
    }
    display_ = display;

    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE
    };
    EGLConfig config = nullptr;
    EGLint numConfigs = 0;
    if (eglChooseConfig(display, configAttribs, &config, 1, &numConfigs) != EGL_TRUE || numConfigs < 1) {
        error = "eglChooseConfig 失败";
        destroy();
        return false;
    }
    // 渲染缓冲**不跟随组件全尺寸**：模拟器的 GL 是软件光栅化（日志可见 DGLES
    // `d_eglSwapBuffers_special ... speed 531k/s`），让它每帧交换 1260x2619（330 万像素）
    // 会直接失败（实测 eglSwapBuffers 0x12301）。这里按视频尺寸量级限制缓冲（默认 ≤640 宽，
    // 保持宽高比），由 ArkUI 把该内容放大到 XComponent 尺寸。
    int32_t w = requestedWidth;
    int32_t h = requestedHeight;
    if (w > kMaxRenderWidth) {
        h = static_cast<int32_t>(static_cast<int64_t>(h) * kMaxRenderWidth / w);
        w = kMaxRenderWidth;
    }
    if (w <= 0 || h <= 0) {
        w = 640;
        h = 360;
    }
    OH_NativeWindow_NativeWindowHandleOpt(window, SET_BUFFER_GEOMETRY, w, h);
    geometryAtInit_ = std::to_string(w) + "x" + std::to_string(h);

    EGLSurface surface = eglCreateWindowSurface(display, config,
                                                reinterpret_cast<EGLNativeWindowType>(window), nullptr);
    if (surface == EGL_NO_SURFACE) {
        error = "eglCreateWindowSurface 失败（EGL 0x" + std::to_string(eglGetError()) + "）";
        destroy();
        return false;
    }
    surface_ = surface;
    const EGLint contextAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs);
    if (context == EGL_NO_CONTEXT || eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) {
        error = "EGL 上下文创建/切换失败";
        destroy();
        return false;
    }
    context_ = context;
    eglQuerySurface(display, surface, EGL_WIDTH, &surfaceWidth_);
    eglQuerySurface(display, surface, EGL_HEIGHT, &surfaceHeight_);
    if (surfaceWidth_ <= 0 || surfaceHeight_ <= 0) {
        surfaceWidth_ = w;
        surfaceHeight_ = h;
    }
    if (!buildProgram(error)) {
        destroy();
        return false;
    }
    glGenTextures(1, &texture_);
    glBindTexture(GL_TEXTURE_2D, texture_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    static const float kQuad[] = {
        -1.0f, -1.0f, 0.0f, 1.0f, 1.0f, -1.0f, 1.0f, 1.0f,
        -1.0f, 1.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 0.0f
    };
    glGenBuffers(1, &vbo_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(kQuad), kQuad, GL_STATIC_DRAW);
    ready_ = true;
    return true;
}

bool EglRenderer::selfTest(std::string &report)
{
    if (!ready_) {
        report = "渲染器未就绪";
        return false;
    }
    eglMakeCurrent(static_cast<EGLDisplay>(display_), static_cast<EGLSurface>(surface_),
                   static_cast<EGLSurface>(surface_), static_cast<EGLContext>(context_));
    glViewport(0, 0, surfaceWidth_, surfaceHeight_);
    glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glFinish();

    unsigned char pixel[4] = {0, 0, 0, 0};
    glReadPixels(surfaceWidth_ / 2, surfaceHeight_ / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    const GLenum readErr = glGetError();

    const EGLBoolean swapped = eglSwapBuffers(static_cast<EGLDisplay>(display_),
                                              static_cast<EGLSurface>(surface_));
    const EGLint swapErr = eglGetError();
    // TEXTURE 路径：swap 之后**必须**发布（UpdateSurfaceImage），否则 OH_NativeImage 的
    // 生产者/消费者会失配，之后渲染循环里的每次 swap 都失败（实测 0x12301）。
    // 该失配是本类上一版在自检里"裸 swap 不发布"造成的，务必保持两者成对。
    if (nativeImage_ != nullptr && swapped == EGL_TRUE) {
        OH_NativeImage_UpdateSurfaceImage(static_cast<OH_NativeImage *>(nativeImage_));
    }

    report = "几何 " + std::to_string(surfaceWidth_) + "x" + std::to_string(surfaceHeight_)
             + "；清屏(红)后中心像素 rgba=(" + std::to_string(pixel[0]) + "," + std::to_string(pixel[1])
             + "," + std::to_string(pixel[2]) + "," + std::to_string(pixel[3]) + ")"
             + "；glReadPixels=" + (readErr == GL_NO_ERROR ? "OK" : ("0x" + std::to_string(readErr)))
             + "；eglSwapBuffers=" + (swapped == EGL_TRUE ? "OK" : ("0x" + std::to_string(swapErr)));

    // 清屏为红且能回读到红 → 该 surface 可作为 GL 渲染目标
    const bool surfaceRenderable = (pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60);
    report += surfaceRenderable ? "；结论：surface 可渲染" : "；结论：surface 未呈现（清屏色未回读）";

    // ── 第二步：走与真实播放**完全相同**的绘制路径，画一个程序生成的 2x2 纹理四边形再回读 ──
    // 目的：把"绘制路径（着色器/VBO/attribute/纹理采样）有问题"与
    //       "surface/发布这一层有问题"区分开。上下文：真实解码帧回读全黑但 GL 无错误。
    const uint8_t checker[16] = {
        255, 0, 0, 255,     0, 255, 0, 255,     // 上排：红、绿
        0, 0, 255, 255,     255, 255, 255, 255  // 下排：蓝、白
    };
    std::string drawError;
    bool quadOk = false;
    if (drawFrame(checker, 2, 2, drawError)) {
        glFinish();
        unsigned char quadPixel[4] = {0, 0, 0, 0};
        glReadPixels(surfaceWidth_ / 2, surfaceHeight_ / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, quadPixel);
        const int nonBlack = quadPixel[0] + quadPixel[1] + quadPixel[2];
        quadOk = nonBlack > 30;
        report += "；纹理四边形回读 rgba=(" + std::to_string(quadPixel[0]) + ","
                  + std::to_string(quadPixel[1]) + "," + std::to_string(quadPixel[2]) + ","
                  + std::to_string(quadPixel[3]) + ")"
                  + (quadOk ? "（绘制路径正常）" : "（绘制路径未产出内容）");
    } else {
        report += "；纹理四边形绘制失败：" + drawError;
    }
    // 自检结束时把画面恢复为中性黑，避免把测试图案留在屏幕上。
    //
    // 必须**两条路径都做**。此前这段被 `if (nativeImage_ != nullptr)` 包着，只覆盖了
    // TEXTURE 路径；而本工程 `softPlayOpen` 的 'xcomponent' 模式走的是 `initFromWindow()`
    // （window surface，`nativeImage_` 恒为 nullptr），于是"清屏为红"的测试图案**再也没被抹掉**。
    // 设备实测后果：起播即结束（续播点靠近片尾）时视频区整块红屏 avg=(224,6,6)，
    // 看起来像渲染坏了 —— 截图验证一口咬到这个缺陷。
    // 正确顺序：清黑 → glFinish → swap（使内容真正上屏）→ 仅有 NativeImage 时才发布。
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glFinish();
    if (eglSwapBuffers(static_cast<EGLDisplay>(display_), static_cast<EGLSurface>(surface_)) ==
        EGL_TRUE && nativeImage_ != nullptr) {
        OH_NativeImage_UpdateSurfaceImage(static_cast<OH_NativeImage *>(nativeImage_));
    }
    return surfaceRenderable && quadOk;
}

void EglRenderer::destroy()
{
    if (display_ != nullptr && surface_ != nullptr && context_ != nullptr) {
        eglMakeCurrent(static_cast<EGLDisplay>(display_), EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    if (program_ != 0) {
        glDeleteProgram(program_);
        program_ = 0;
    }
    if (texture_ != 0) {
        glDeleteTextures(1, &texture_);
        texture_ = 0;
    }
    if (vbo_ != 0) {
        glDeleteBuffers(1, &vbo_);
        vbo_ = 0;
    }
    if (display_ != nullptr && context_ != nullptr) {
        eglDestroyContext(static_cast<EGLDisplay>(display_), static_cast<EGLContext>(context_));
        context_ = nullptr;
    }
    if (display_ != nullptr && surface_ != nullptr) {
        eglDestroySurface(static_cast<EGLDisplay>(display_), static_cast<EGLSurface>(surface_));
        surface_ = nullptr;
    }
    if (display_ != nullptr) {
        eglTerminate(static_cast<EGLDisplay>(display_));
        display_ = nullptr;
    }
    if (nativeImage_ != nullptr) {
        OH_NativeImage *image = static_cast<OH_NativeImage *>(nativeImage_);
        OH_NativeImage_Destroy(&image);
        nativeImage_ = nullptr;
    } else if (nativeWindow_ != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(static_cast<OHNativeWindow *>(nativeWindow_));
        nativeWindow_ = nullptr;
    }
    ready_ = false;
    surfaceWidth_ = 0;
    surfaceHeight_ = 0;
}

} // namespace player
} // namespace jellyfin
