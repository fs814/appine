CC = clang

# ---------------------------------------------------------------------------
# 路径配置
# ---------------------------------------------------------------------------
SRC_CORE_DIR    = src/core
SRC_BACKEND_DIR = src/backends

# ---------------------------------------------------------------------------
# EMACS_INCLUDE_DIR setup
# ---------------------------------------------------------------------------
# 候选搜索路径（按优先级排列）
EMACS_HEADER_SEARCH_PATHS = \
    /Applications/Emacs.app/Contents/Resources/include \
    /usr/local/include

# 判断用户是否显式传入了 EMACS_INCLUDE_DIR
ifdef EMACS_INCLUDE_DIR
  # 用户传入了路径，验证头文件是否真实存在
  ifeq ($(wildcard $(EMACS_INCLUDE_DIR)/emacs-module.h),)
    $(error emacs-module.h not found in specified EMACS_INCLUDE_DIR="$(EMACS_INCLUDE_DIR)". \
Please make sure the path is correct. \
Usage example: make EMACS_INCLUDE_DIR=/Applications/Emacs.app/Contents/Resources/include)
  endif
else
  # 用户未传入，自动在候选路径中搜索
  EMACS_INCLUDE_DIR := $(firstword \
      $(foreach p,$(EMACS_HEADER_SEARCH_PATHS),\
          $(if $(wildcard $(p)/emacs-module.h),$(p),)))

  ifeq ($(EMACS_INCLUDE_DIR),)
    $(error emacs-module.h was not found in any of the default search paths: \
[$(EMACS_HEADER_SEARCH_PATHS)]. \
Please locate emacs-module.h manually and pass its directory via EMACS_INCLUDE_DIR. \
Usage example: make EMACS_INCLUDE_DIR=/path/to/your/emacs/include)
  endif
endif


# ---------------------------------------------------------------------------
# 编译选项
# ---------------------------------------------------------------------------
# Metal sample demos (src/backends/metal/README.md): Apple's triangle and ray
# tracing samples, each in its own directory, plus common/ for what they
# share. Their shaders are embedded in the dylib as source and compiled at
# runtime, so no Metal toolchain is needed here.
SRC_METAL_DIR = $(SRC_BACKEND_DIR)/metal
GEN_DIR       = build
OBJ_DIR       = $(GEN_DIR)/obj
METAL_DEMOS   = triangle raytracing

# Shadertoy (src/backends/metal/shadertoy): GLSL is translated to Metal with
# shaderc and SPIRV-Cross from the LunarG Vulkan SDK, linked statically so the
# module needs no SDK at runtime. Without the SDK appine still builds, and a
# Shadertoy tab says what is missing. Install: Settings/binmac/init/vulkan-init.sh
VULKAN_SDK ?= $(HOME)/VulkanSDK/current/macOS
ifneq ($(wildcard $(VULKAN_SDK)/lib/libshaderc_combined.a),)
  SHADERC_CFLAGS  = -DAPPINE_HAVE_SHADERC=1 -I"$(VULKAN_SDK)/include"
  SHADERC_LDFLAGS = -L"$(VULKAN_SDK)/lib" -lshaderc_combined \
                    -lspirv-cross-c -lspirv-cross-msl -lspirv-cross-hlsl -lspirv-cross-cpp \
                    -lspirv-cross-reflect -lspirv-cross-util -lspirv-cross-glsl -lspirv-cross-core
else
  $(info Vulkan SDK not found at $(VULKAN_SDK): building without Shadertoy translation)
endif
SHADER_INCS   = $(foreach d,$(METAL_DEMOS),$(GEN_DIR)/appine_$(d)_shaders.inc)

CXX = clang++

# The sample directories are deliberately not on the include path: both have
# a ShaderTypes.h and a Shaders.metal. Their files include siblings with
# quotes, which resolve next to the including file.
WARN_FLAGS = -Wall -Wextra -Wno-unused-parameter
COMMON_FLAGS = -O2 -fPIC -fobjc-arc $(WARN_FLAGS) \
         -I"$(EMACS_INCLUDE_DIR)" \
         -I"$(SRC_CORE_DIR)" \
         -I"$(SRC_BACKEND_DIR)" \
         -I"$(GEN_DIR)" \
         $(SHADERC_CFLAGS)

CFLAGS   = $(COMMON_FLAGS) -std=c11
# Objective-C++ (.mm): the ray tracing sample is written in it.
CXXFLAGS = $(COMMON_FLAGS) -std=gnu++17

LDFLAGS = -dynamiclib \
          -framework Cocoa \
          -framework WebKit \
          -framework Quartz \
          -framework UniformTypeIdentifiers \
          -framework Metal \
          -framework MetalKit \
          -lsqlite3 \
          $(SHADERC_LDFLAGS)

TARGET = appine-module.dylib

# 同时编译 Intel 和 Apple Silicon 架构
ARCH_FLAGS = -arch x86_64 -arch arm64

# ---------------------------------------------------------------------------
# 源文件（按新目录结构）
# ---------------------------------------------------------------------------
TRIANGLE_DIR   = $(SRC_METAL_DIR)/triangle
RAYTRACING_DIR = $(SRC_METAL_DIR)/raytracing

TRIANGLE_SRCS = $(TRIANGLE_DIR)/AppineTriangleShaders.m \
                $(TRIANGLE_DIR)/MetalKitViewDelegate.m \
                $(TRIANGLE_DIR)/TriangleData.c \
                $(TRIANGLE_DIR)/MetalRenderer.m \
                $(TRIANGLE_DIR)/MetalRenderer+Setup.m \
                $(TRIANGLE_DIR)/MetalRenderer+Compilation.m \
                $(TRIANGLE_DIR)/Metal4Renderer.m \
                $(TRIANGLE_DIR)/Metal4Renderer+Setup.m \
                $(TRIANGLE_DIR)/Metal4Renderer+Compilation.m \
                $(TRIANGLE_DIR)/Metal4Renderer+Encoding.m

RAYTRACING_SRCS = $(RAYTRACING_DIR)/AppineRayTracingShaders.m \
                  $(RAYTRACING_DIR)/Renderer.mm \
                  $(RAYTRACING_DIR)/Scene.mm \
                  $(RAYTRACING_DIR)/Transforms.mm

SRCS = $(SRC_CORE_DIR)/module.c \
       $(SRC_CORE_DIR)/appine_core.m \
       $(SRC_BACKEND_DIR)/backend_web.m \
       $(SRC_BACKEND_DIR)/backend_web_utils.m \
       $(SRC_BACKEND_DIR)/backend_pdf.m \
       $(SRC_BACKEND_DIR)/backend_rss.m \
       $(SRC_BACKEND_DIR)/backend_quicklook.m \
       $(SRC_BACKEND_DIR)/backend_metal_triangle.m \
       $(SRC_BACKEND_DIR)/backend_metal_raytracing.mm \
       $(SRC_BACKEND_DIR)/backend_metal_shadertoy.m \
       $(SRC_BACKEND_DIR)/backend_vulkan_samples.m \
       $(SRC_METAL_DIR)/shadertoy/AppineShadertoyTranslator.m \
       $(SRC_METAL_DIR)/shadertoy/AppineShadertoyRenderer.m \
       $(SRC_METAL_DIR)/common/AppineMetalCommon.m \
       $(TRIANGLE_SRCS) \
       $(RAYTRACING_SRCS)

OBJS = $(patsubst %,$(OBJ_DIR)/%.o,$(SRCS))
HDRS = $(shell find src -name '*.h' -not -path '*/Vulkan-Samples/*')

# The sample's Xcode project builds its Metal 3 configuration; the shader
# side gets the same macro at runtime (AppineRayTracingShaders.m).
RAYTRACING_OBJS = $(patsubst %,$(OBJ_DIR)/%.o,$(RAYTRACING_SRCS) $(SRC_BACKEND_DIR)/backend_metal_raytracing.mm)
$(RAYTRACING_OBJS): EXTRA_FLAGS = -DSUPPORTS_METAL_3=1 -Wno-deprecated-declarations

# ---------------------------------------------------------------------------
# 构建规则
# ---------------------------------------------------------------------------
.PHONY: all clean vulkan-samples
.DEFAULT_GOAL := all

# Khronos Vulkan-Samples (src/backends/vulkan/README.md): an optional, separate
# library, because it is a large CMake project (about 1300 build steps). Not
# part of `all`. Needs cmake, the Vulkan SDK, and fetch_deps.sh run once.
VKS_DIR   = $(SRC_BACKEND_DIR)/vulkan
VKS_BUILD = $(GEN_DIR)/vulkan-samples
vulkan-samples:
	@test -f $(VKS_DIR)/Vulkan-Samples/third_party/volk/volk.h || \
	  { echo "Dependencies missing: run $(VKS_DIR)/fetch_deps.sh first."; exit 1; }
	@test -d "$(VULKAN_SDK)" || { echo "Vulkan SDK not found at $(VULKAN_SDK)."; exit 1; }
	VULKAN_SDK="$(VULKAN_SDK)" PATH="$(VULKAN_SDK)/bin:$$PATH" cmake $(if $(shell command -v ninja),-G Ninja,) \
	  -S $(VKS_DIR)/Vulkan-Samples -B $(VKS_BUILD) \
	  -DCMAKE_BUILD_TYPE=Release -DVKB_BUILD_TESTS=OFF \
	  -DCMAKE_PROJECT_INCLUDE="$(abspath $(VKS_DIR)/appine/appine.cmake)" \
	  -DAPPINE_VKS_OUTPUT_DIR="$(abspath .)"
	cmake --build $(VKS_BUILD) --target appine_vulkan_samples

all: $(TARGET)

# Linked with clang++ for the C++ runtime the .mm files need.
$(TARGET): $(OBJS)
	$(CXX) $(ARCH_FLAGS) $(LDFLAGS) -o $@ $(OBJS)

# Every object depends on all headers and the embedded shaders: coarse, but a
# full rebuild takes seconds and never leaves a stale object behind.
$(OBJ_DIR)/%.c.o: %.c $(HDRS) $(SHADER_INCS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(EXTRA_FLAGS) $(ARCH_FLAGS) -c -o $@ $<

$(OBJ_DIR)/%.m.o: %.m $(HDRS) $(SHADER_INCS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(EXTRA_FLAGS) $(ARCH_FLAGS) -c -o $@ $<

$(OBJ_DIR)/%.mm.o: %.mm $(HDRS) $(SHADER_INCS)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(EXTRA_FLAGS) $(ARCH_FLAGS) -c -o $@ $<

# Each demo's ShaderTypes.h + Shaders.metal (minus its #include of
# ShaderTypes.h) as a C byte array:
# appine_<demo>_shader_source / appine_<demo>_shader_source_len.
$(GEN_DIR)/appine_%_shaders.inc: $(SRC_METAL_DIR)/%/ShaderTypes.h $(SRC_METAL_DIR)/%/Shaders.metal
	@mkdir -p $(GEN_DIR)
	{ cat $(SRC_METAL_DIR)/$*/ShaderTypes.h; \
	  sed '/#include "ShaderTypes.h"/d' $(SRC_METAL_DIR)/$*/Shaders.metal; } \
	  | xxd -i -n appine_$*_shader_source > $@

clean:
	rm -rf $(TARGET) $(GEN_DIR)
