/*
 * guest_gl_probe — in-guest proof that GL 4.x actually renders (not just a
 * version string): EGL surfaceless → 4.6 core context → FBO → draw a
 * point that a GEOMETRY SHADER amplifies to a fullscreen triangle →
 * glReadPixels → assert green.
 *
 * dlopens libEGL/libOpenGL at runtime so it cross-compiles from the macOS
 * host with no guest sysroot:
 *   zig cc -target aarch64-linux-gnu.2.34 -O2 -o guest_gl_probe \
 *     tests/integration/gl/guest_gl_probe.c
 * Ship it in the GL squashfs (/shim/) and run with the zink/venus env set.
 * Prints GLPROBE: PASS on success; every step logs so failures localize.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The 16KiB blob-align interposers (tools/venus_align_shim.c) are compiled
 * in and exported (--export-dynamic): the executable's ioctl/mmap win global
 * symbol resolution for the dlopened Mesa stack, so no LD_PRELOAD is needed
 * (preloading the shim under an explicit-ld.so invocation dies pre-main).
 */
#include "../../../tools/venus_align_shim.c"

typedef int EGLint;
typedef unsigned EGLBoolean;
typedef unsigned EGLenum;
typedef void *EGLDisplay, *EGLConfig, *EGLContext, *EGLDeviceEXT;
typedef unsigned GLenum, GLuint, GLbitfield;
typedef int GLint, GLsizei;
typedef signed char GLbyte;
typedef float GLfloat;
typedef unsigned char GLubyte, GLboolean;

#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD
#define EGL_NO_CONTEXT ((EGLContext)0)
#define EGL_NO_SURFACE ((void *)0)
#define EGL_OPENGL_API 0x30A2
#define EGL_CONTEXT_MAJOR_VERSION 0x3098
#define EGL_CONTEXT_MINOR_VERSION 0x30FB
#define EGL_CONTEXT_OPENGL_PROFILE_MASK 0x30FD
#define EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT 0x1
#define EGL_NONE 0x3038

#define GL_COLOR_BUFFER_BIT 0x4000
#define GL_FRAMEBUFFER 0x8D40
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_RENDERBUFFER 0x8D41
#define GL_RGBA8 0x8058
#define GL_FRAMEBUFFER_COMPLETE 0x8CD5
#define GL_VERTEX_SHADER 0x8B31
#define GL_FRAGMENT_SHADER 0x8B30
#define GL_GEOMETRY_SHADER 0x8DD9
#define GL_COMPILE_STATUS 0x8B81
#define GL_LINK_STATUS 0x8B82
#define GL_POINTS 0x0000
#define GL_RGBA 0x1908
#define GL_UNSIGNED_BYTE 0x1401
#define GL_VERSION 0x1F02

static void *egl, *gl;
#define E(name, ret, ...) static ret (*name)(__VA_ARGS__)
E(eglGetPlatformDisplay, EGLDisplay, EGLenum, void *, const long *);
E(eglInitialize, EGLBoolean, EGLDisplay, EGLint *, EGLint *);
E(eglBindAPI, EGLBoolean, EGLenum);
E(eglCreateContext, EGLContext, EGLDisplay, EGLConfig, EGLContext, const EGLint *);
E(eglMakeCurrent, EGLBoolean, EGLDisplay, void *, void *, EGLContext);
E(eglGetError, EGLint, void);
static void *(*eglGetProcAddress)(const char *);

#define G(ret, name, ...) static ret (*name)(__VA_ARGS__)
G(const GLubyte *, glGetString, GLenum);
G(void, glGenFramebuffers, GLsizei, GLuint *);
G(void, glBindFramebuffer, GLenum, GLuint);
G(void, glGenRenderbuffers, GLsizei, GLuint *);
G(void, glBindRenderbuffer, GLenum, GLuint);
G(void, glRenderbufferStorage, GLenum, GLenum, GLsizei, GLsizei);
G(void, glFramebufferRenderbuffer, GLenum, GLenum, GLenum, GLuint);
G(GLenum, glCheckFramebufferStatus, GLenum);
G(GLuint, glCreateShader, GLenum);
G(void, glShaderSource, GLuint, GLsizei, const char *const *, const GLint *);
G(void, glCompileShader, GLuint);
G(void, glGetShaderiv, GLuint, GLenum, GLint *);
G(void, glGetShaderInfoLog, GLuint, GLsizei, GLsizei *, char *);
G(GLuint, glCreateProgram, void);
G(void, glAttachShader, GLuint, GLuint);
G(void, glLinkProgram, GLuint);
G(void, glGetProgramiv, GLuint, GLenum, GLint *);
G(void, glGetProgramInfoLog, GLuint, GLsizei, GLsizei *, char *);
G(void, glUseProgram, GLuint);
G(void, glGenVertexArrays, GLsizei, GLuint *);
G(void, glBindVertexArray, GLuint);
G(void, glViewport, GLint, GLint, GLsizei, GLsizei);
G(void, glClearColor, GLfloat, GLfloat, GLfloat, GLfloat);
G(void, glClear, GLbitfield);
G(void, glDrawArrays, GLenum, GLint, GLsizei);
G(void, glReadPixels, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
G(void, glFinish, void);
G(GLenum, glGetError, void);

static void *sym(void *h, const char *n)
{
   void *p = dlsym(h, n);
   if (!p && eglGetProcAddress)
      p = eglGetProcAddress(n);
   if (!p) {
      printf("GLPROBE: missing symbol %s\n", n);
      exit(1);
   }
   return p;
}

static GLuint shader(GLenum type, const char *src)
{
   GLuint s = glCreateShader(type);
   glShaderSource(s, 1, &src, NULL);
   glCompileShader(s);
   GLint ok = 0;
   glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
   if (!ok) {
      char log[2048];
      glGetShaderInfoLog(s, sizeof log, NULL, log);
      printf("GLPROBE: shader compile failed (type 0x%x):\n%s\n", type, log);
      exit(1);
   }
   return s;
}

int main(void)
{
   /* stdout is a pipe in the harness: unbuffered, so a crash after partial
    * progress still leaves the step log visible. */
   setvbuf(stdout, NULL, _IONBF, 0);
   printf("GLPROBE: start\n");
   egl = dlopen("libEGL.so.1", RTLD_NOW);
   /* Desktop GL entrypoints: glvnd's libOpenGL, else legacy libGL. */
   gl = dlopen("libOpenGL.so.0", RTLD_NOW);
   if (!gl)
      gl = dlopen("libGL.so.1", RTLD_NOW);
   if (!egl || !gl) {
      printf("GLPROBE: dlopen failed egl=%p gl=%p (%s)\n", egl, gl, dlerror());
      return 1;
   }
   eglGetProcAddress = dlsym(egl, "eglGetProcAddress");
#define LE(n) n = sym(egl, #n)
   LE(eglGetPlatformDisplay); LE(eglInitialize); LE(eglBindAPI);
   LE(eglCreateContext); LE(eglMakeCurrent); LE(eglGetError);
#define LG(n) n = sym(gl, #n)
   LG(glGetString); LG(glGenFramebuffers); LG(glBindFramebuffer);
   LG(glGenRenderbuffers); LG(glBindRenderbuffer); LG(glRenderbufferStorage);
   LG(glFramebufferRenderbuffer); LG(glCheckFramebufferStatus);
   LG(glCreateShader); LG(glShaderSource); LG(glCompileShader);
   LG(glGetShaderiv); LG(glGetShaderInfoLog); LG(glCreateProgram);
   LG(glAttachShader); LG(glLinkProgram); LG(glGetProgramiv);
   LG(glGetProgramInfoLog); LG(glUseProgram); LG(glGenVertexArrays);
   LG(glBindVertexArray); LG(glViewport); LG(glClearColor); LG(glClear);
   LG(glDrawArrays); LG(glReadPixels); LG(glFinish); LG(glGetError);

   EGLDisplay dpy =
      eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, NULL, NULL);
   EGLint maj, min;
   if (!dpy || !eglInitialize(dpy, &maj, &min)) {
      printf("GLPROBE: eglInitialize failed 0x%x\n", eglGetError());
      return 1;
   }
   printf("GLPROBE: EGL %d.%d\n", maj, min);
   eglBindAPI(EGL_OPENGL_API);
   const EGLint ctx_attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 4,
                               EGL_CONTEXT_MINOR_VERSION, 6,
                               EGL_CONTEXT_OPENGL_PROFILE_MASK,
                               EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE};
   EGLContext ctx = eglCreateContext(dpy, NULL, EGL_NO_CONTEXT, ctx_attrs);
   if (!ctx) {
      printf("GLPROBE: eglCreateContext(4.6 core) failed 0x%x\n", eglGetError());
      return 1;
   }
   if (!eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) {
      printf("GLPROBE: eglMakeCurrent failed 0x%x\n", eglGetError());
      return 1;
   }
   printf("GLPROBE: context: %s\n", (const char *)glGetString(GL_VERSION));

   GLuint fbo, rbo;
   glGenFramebuffers(1, &fbo);
   glBindFramebuffer(GL_FRAMEBUFFER, fbo);
   glGenRenderbuffers(1, &rbo);
   glBindRenderbuffer(GL_RENDERBUFFER, rbo);
   glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 64, 64);
   glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                             GL_RENDERBUFFER, rbo);
   if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
      printf("GLPROBE: FBO incomplete\n");
      return 1;
   }
   printf("GLPROBE: FBO complete\n");

   /* Point in, fullscreen triangle out of the GEOMETRY shader. */
   const char *vs = "#version 460 core\n"
                    "void main() { gl_Position = vec4(0, 0, 0, 1); }\n";
   const char *gs =
      "#version 460 core\n"
      "layout(points) in;\n"
      "layout(triangle_strip, max_vertices = 3) out;\n"
      "void main() {\n"
      "  gl_Position = vec4(-1, -1, 0, 1); EmitVertex();\n"
      "  gl_Position = vec4( 3, -1, 0, 1); EmitVertex();\n"
      "  gl_Position = vec4(-1,  3, 0, 1); EmitVertex();\n"
      "  EndPrimitive();\n"
      "}\n";
   const char *fs = "#version 460 core\n"
                    "out vec4 color;\n"
                    "void main() { color = vec4(0, 1, 0, 1); }\n";
   GLuint prog = glCreateProgram();
   glAttachShader(prog, shader(GL_VERTEX_SHADER, vs));
   printf("GLPROBE: VS compiled\n");
   glAttachShader(prog, shader(GL_GEOMETRY_SHADER, gs));
   printf("GLPROBE: GS compiled\n");
   glAttachShader(prog, shader(GL_FRAGMENT_SHADER, fs));
   printf("GLPROBE: FS compiled\n");
   glLinkProgram(prog);
   GLint ok = 0;
   glGetProgramiv(prog, GL_LINK_STATUS, &ok);
   if (!ok) {
      char log[2048];
      glGetProgramInfoLog(prog, sizeof log, NULL, log);
      printf("GLPROBE: link failed:\n%s\n", log);
      return 1;
   }

   printf("GLPROBE: linked\n");
   GLuint vao;
   glGenVertexArrays(1, &vao);
   glBindVertexArray(vao);
   glViewport(0, 0, 64, 64);
   glClearColor(1, 0, 0, 1);
   glClear(GL_COLOR_BUFFER_BIT);
   glUseProgram(prog);
   printf("GLPROBE: drawing\n");
   glDrawArrays(GL_POINTS, 0, 1);
   printf("GLPROBE: draw issued\n");
   glFinish();
   printf("GLPROBE: finished\n");

   static GLubyte px[64 * 64 * 4];
   glReadPixels(0, 0, 64, 64, GL_RGBA, GL_UNSIGNED_BYTE, px);
   GLenum err = glGetError();
   int green = 0;
   for (int i = 0; i < 64 * 64; i++)
      if (px[i * 4] == 0 && px[i * 4 + 1] == 255 && px[i * 4 + 2] == 0)
         green++;
   printf("GLPROBE: glGetError=0x%x center=(%u %u %u %u) green=%d/4096\n", err,
          px[(32 * 64 + 32) * 4], px[(32 * 64 + 32) * 4 + 1],
          px[(32 * 64 + 32) * 4 + 2], px[(32 * 64 + 32) * 4 + 3], green);
   if (err == 0 && green == 64 * 64) {
      printf("GLPROBE: PASS\n");
      return 0;
   }
   printf("GLPROBE: FAIL\n");
   return 1;
}
