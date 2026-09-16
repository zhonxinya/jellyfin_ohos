#include "egl_renderer.h"

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
out vec2 vUv;
void main() {
    vUv = aUv;
    gl_Position = vec4(aPos, 0.0, 1.0);
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
    requestedWidth_ = requestedWidth;
    requestedHeight_ = requestedHeight;

    OHNativeWindow *window = nullptr;
    const int32_t rc = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window);
    if (rc != 0 || window == nullptr) {
        error = "无法从 surfaceId 创建 native window（rc=" + std::to_string(rc) + "）";
        return false;
    }
    nativeWindow_ = window;

    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY) {
        error = "eglGetDisplay 失败";
        return false;
    }
    EGLint major = 0;
    EGLint minor = 0;
    if (eglInitialize(display, &major, &minor) != EGL_TRUE) {
        error = "eglInitialize 失败";
        return false;
    }
    display_ = display;

    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig config = nullptr;
    EGLint numConfigs = 0;
    if (eglChooseConfig(display, configAttribs, &config, 1, &numConfigs) != EGL_TRUE || numConfigs < 1) {
        error = "eglChooseConfig 未找到匹配的 RGBA8888 配置";
        return false;
    }

    // 关键：先落实缓冲几何再用它创建 EGL surface。
    // 几何为 0 时 OHOS 的 eglSwapBuffers 会失败（实测 0x12301，非标准 EGL 错误码）。
    int32_t bufW = 0;
    int32_t bufH = 0;
    OH_NativeWindow_NativeWindowHandleOpt(window, GET_BUFFER_GEOMETRY, &bufW, &bufH);
    // 实测该值可能宽高转置（2619x1260 vs 实际 1260x2619），导致 eglSwapBuffers 失败；
    // 因此只要调用方给了组件真实像素尺寸，就以它为准强制重设几何。
    if (requestedWidth_ > 0 && requestedHeight_ > 0) {
        OH_NativeWindow_NativeWindowHandleOpt(window, SET_BUFFER_GEOMETRY, requestedWidth_,
                                             requestedHeight_);
        bufW = requestedWidth_;
        bufH = requestedHeight_;
    }
    geometryAtInit_ = std::to_string(bufW) + "x" + std::to_string(bufH);

    EGLSurface surface = eglCreateWindowSurface(display, config,
                                                reinterpret_cast<EGLNativeWindowType>(window), nullptr);
    if (surface == EGL_NO_SURFACE) {
        error = "eglCreateWindowSurface 失败（0x" + std::to_string(eglGetError()) + "）";
        return false;
    }
    surface_ = surface;

    const EGLint contextAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs);
    if (context == EGL_NO_CONTEXT) {
        error = "eglCreateContext 失败";
        return false;
    }
    context_ = context;

    if (eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) {
        error = "eglMakeCurrent 失败";
        return false;
    }
    eglQuerySurface(display, surface, EGL_WIDTH, &surfaceWidth_);
    eglQuerySurface(display, surface, EGL_HEIGHT, &surfaceHeight_);
    if (surfaceWidth_ <= 0 || surfaceHeight_ <= 0) {
        surfaceWidth_ = bufW;
        surfaceHeight_ = bufH;
    }

    if (!buildProgram(error)) {
        return false;
    }

    glGenTextures(1, &texture_);
    glBindTexture(GL_TEXTURE_2D, texture_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    static const float kQuad[] = {
        // 位置(x,y)     纹理坐标(u,v)：v 已翻转（解码输出是自上而下）
        -1.0f, -1.0f,  0.0f, 1.0f,
         1.0f, -1.0f,  1.0f, 1.0f,
        -1.0f,  1.0f,  0.0f, 0.0f,
         1.0f,  1.0f,  1.0f, 0.0f
    };
    glGenBuffers(1, &vbo_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(kQuad), kQuad, GL_STATIC_DRAW);

    ready_ = true;
    return true;
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
    attribPos_ = 0;
    attribUv_ = 1;
    uniformTex_ = glGetUniformLocation(program, "uTex");
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
    if (!drawFrame(rgba, width, height, error)) {
        return false;
    }
    glFinish();
    return readbackRgba(out, outWidth, outHeight, error);
}

/** 上传纹理并绘制一帧（不含 swap 与发布），供 renderRgba 与导出前重绘共用 */
bool EglRenderer::drawFrame(const uint8_t *rgba, int width, int height, std::string &error)
{
    if (!ready_ || rgba == nullptr || width <= 0 || height <= 0) {
        error = "渲染器未就绪或帧无效";
        return false;
    }
    if (surfaceWidth_ <= 0 || surfaceHeight_ <= 0) {
        eglQuerySurface(static_cast<EGLDisplay>(display_), static_cast<EGLSurface>(surface_),
                        EGL_WIDTH, &surfaceWidth_);
        eglQuerySurface(static_cast<EGLDisplay>(display_), static_cast<EGLSurface>(surface_),
                        EGL_HEIGHT, &surfaceHeight_);
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
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    glUniform1i(uniformTex_, 0);

    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glEnableVertexAttribArray(static_cast<GLuint>(attribPos_));
    glVertexAttribPointer(static_cast<GLuint>(attribPos_), 2, GL_FLOAT, GL_FALSE,
                          4 * sizeof(float), reinterpret_cast<void *>(0));
    glEnableVertexAttribArray(static_cast<GLuint>(attribUv_));
    glVertexAttribPointer(static_cast<GLuint>(attribUv_), 2, GL_FLOAT, GL_FALSE,
                          4 * sizeof(float), reinterpret_cast<void *>(2 * sizeof(float)));
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
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
    int32_t bufW = 0;
    int32_t bufH = 0;
    OH_NativeWindow_NativeWindowHandleOpt(window, GET_BUFFER_GEOMETRY, &bufW, &bufH);
    if (requestedWidth_ > 0 && requestedHeight_ > 0) {
        OH_NativeWindow_NativeWindowHandleOpt(window, SET_BUFFER_GEOMETRY, requestedWidth_,
                                             requestedHeight_);
        bufW = requestedWidth_;
        bufH = requestedHeight_;
    }
    geometryAtInit_ = std::to_string(bufW) + "x" + std::to_string(bufH);

    EGLSurface surface = eglCreateWindowSurface(display, config,
                                                reinterpret_cast<EGLNativeWindowType>(window), nullptr);
    if (surface == EGL_NO_SURFACE) {
        error = "eglCreateWindowSurface(纹理路径) 失败";
        destroy();
        return false;
    }
    surface_ = surface;
    const EGLint contextAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs);
    if (context == EGL_NO_CONTEXT || eglMakeCurrent(display, surface, surface, context) != EGL_TRUE) {
        error = "EGL 上下文创建/切换失败（纹理路径）";
        destroy();
        return false;
    }
    context_ = context;
    eglQuerySurface(display, surface, EGL_WIDTH, &surfaceWidth_);
    eglQuerySurface(display, surface, EGL_HEIGHT, &surfaceHeight_);
    if (surfaceWidth_ <= 0 || surfaceHeight_ <= 0) {
        surfaceWidth_ = bufW > 0 ? bufW : requestedWidth_;
        surfaceHeight_ = bufH > 0 ? bufH : requestedHeight_;
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

    report = "几何 " + std::to_string(surfaceWidth_) + "x" + std::to_string(surfaceHeight_)
             + "；清屏(红)后中心像素 rgba=(" + std::to_string(pixel[0]) + "," + std::to_string(pixel[1])
             + "," + std::to_string(pixel[2]) + "," + std::to_string(pixel[3]) + ")"
             + "；glReadPixels=" + (readErr == GL_NO_ERROR ? "OK" : ("0x" + std::to_string(readErr)))
             + "；eglSwapBuffers=" + (swapped == EGL_TRUE ? "OK" : ("0x" + std::to_string(swapErr)));

    // 清屏为红且能回读到红 → 该 surface 可作为 GL 渲染目标
    const bool surfaceRenderable = (pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60);
    report += surfaceRenderable ? "；结论：surface 可渲染" : "；结论：surface 未呈现（清屏色未回读）";
    return surfaceRenderable;
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
