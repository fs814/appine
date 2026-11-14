/*
 * Filename: appine_vulkan_samples.h
 * Project: Appine (App in Emacs)
 * Description: C interface of appine-vulkan-samples.dylib, the Khronos
 *              Vulkan-Samples built for appine (see ../README.md). The main
 *              appine module loads it with dlopen, so appine itself builds
 *              and runs without it.
 *
 * One sample runs at a time: the framework keeps global state.
 * Call everything from the main thread.
 */
#ifndef APPINE_VULKAN_SAMPLES_H
#define APPINE_VULKAN_SAMPLES_H

#include <stddef.h>
#include <stdint.h>

/* The library hides everything except these functions. */
#define APPINE_VKS_API __attribute__((visibility("default")))

#ifdef __cplusplus
extern "C" {
#endif

/* Start SAMPLE_ID (e.g. "hello_triangle") drawing into METAL_LAYER (a
 * CAMetalLayer *, WIDTH x HEIGHT pixels, SCALE pixels per point). ROOT is the Vulkan-Samples folder
 * holding assets/ and shaders/. Returns 0, or nonzero with a message in ERR. */
APPINE_VKS_API int appine_vks_start(void *metal_layer, const char *sample_id, const char *root,
                     uint32_t width, uint32_t height, float scale, char *err, size_t err_len);

/* Render one frame. Returns 0 to continue; nonzero when the sample ended or
 * failed, with the reason in ERR. After that only appine_vks_stop is valid. */
APPINE_VKS_API int appine_vks_frame(char *err, size_t err_len);

/* The layer's drawable size changed. */
APPINE_VKS_API void appine_vks_resize(uint32_t width, uint32_t height);

/* Left mouse button. ACTION: 0 down, 1 up, 2 move. Pixels, origin top-left. */
APPINE_VKS_API void appine_vks_mouse(int action, float x, float y);

/* Stop the running sample and release Vulkan. Safe when nothing runs. */
APPINE_VKS_API void appine_vks_stop(void);

/* 1 while a sample is running. */
APPINE_VKS_API int appine_vks_running(void);

#ifdef __cplusplus
}
#endif

#endif
