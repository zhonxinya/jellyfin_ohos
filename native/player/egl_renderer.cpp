#include "egl_renderer.h"

#include <cstring>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
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
    // surface 刚创建时几何可能还是 0：从 native window 读缓冲几何，必要时用 ArkTS 侧传入的组件尺寸设置
    if (surfaceWidth_ <= 0 || surfaceHeight_ <= 0) {
        int32_t bufW = 0;
        int32_t bufH = 0;
        OH_NativeWindow_NativeWindowHandleOpt(window, GET_BUFFER_GEOMETRY, &bufW, &bufH);
        if (bufW > 0 && bufH > 0) {
            surfaceWidth_ = bufW;
            surfaceHeight_ = bufH;
        } else if (requestedWidth_ > 0 && requestedHeight_ > 0) {
            OH_NativeWindow_NativeWindowHandleOpt(window, SET_BUFFER_GEOMETRY, requestedWidth_,
                                                 requestedHeight_);
            surfaceWidth_ = requestedWidth_;
            surfaceHeight_ = requestedHeight_;
        }
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

    if (eglSwapBuffers(static_cast<EGLDisplay>(display_), static_cast<EGLSurface>(surface_)) != EGL_TRUE) {
        error = "eglSwapBuffers 失败（0x" + std::to_string(eglGetError()) + "）";
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
    if (nativeWindow_ != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(static_cast<OHNativeWindow *>(nativeWindow_));
        nativeWindow_ = nullptr;
    }
    ready_ = false;
    surfaceWidth_ = 0;
    surfaceHeight_ = 0;
}

} // namespace player
} // namespace jellyfin
