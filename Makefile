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
         -I"$(GEN_DIR)"

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
          -lsqlite3

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
       $(SRC_METAL_DIR)/common/AppineMetalCommon.m \
       $(TRIANGLE_SRCS) \
       $(RAYTRACING_SRCS)

OBJS = $(patsubst %,$(OBJ_DIR)/%.o,$(SRCS))
HDRS = $(shell find src -name '*.h')

# The sample's Xcode project builds its Metal 3 configuration; the shader
# side gets the same macro at runtime (AppineRayTracingShaders.m).
RAYTRACING_OBJS = $(patsubst %,$(OBJ_DIR)/%.o,$(RAYTRACING_SRCS) $(SRC_BACKEND_DIR)/backend_metal_raytracing.mm)
$(RAYTRACING_OBJS): EXTRA_FLAGS = -DSUPPORTS_METAL_3=1 -Wno-deprecated-declarations

# ---------------------------------------------------------------------------
# 构建规则
# ---------------------------------------------------------------------------
.PHONY: all clean

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
