# Adds appine's library to the Vulkan-Samples build without editing it.
# The Makefile passes this file as CMAKE_PROJECT_INCLUDE, which CMake runs
# after every project() call; the target itself is defined once, deferred to
# the end of the top-level CMakeLists so the samples' targets already exist.
if(NOT APPINE_VKS_HOOKED AND CMAKE_CURRENT_SOURCE_DIR STREQUAL CMAKE_SOURCE_DIR)
    set(APPINE_VKS_HOOKED ON)
    set(APPINE_VKS_DIR "${CMAKE_CURRENT_LIST_DIR}")
    cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL appine_vks_add_library)
endif()

function(appine_vks_add_library)
    add_library(appine_vulkan_samples SHARED "${APPINE_VKS_DIR}/appine_vulkan_samples.cpp")
    # app/: where upstream's main.cpp finds "plugins/plugins.h".
    target_include_directories(appine_vulkan_samples PRIVATE "${APPINE_VKS_DIR}" "${CMAKE_SOURCE_DIR}/app")
    # Same libraries as the vulkan_samples executable (app/CMakeLists.txt).
    target_link_libraries(appine_vulkan_samples PRIVATE vkb__core vkb__filesystem apps plugins framework
)
    if(DEFINED ENV{VULKAN_SDK})
        target_compile_definitions(appine_vulkan_samples PRIVATE APPINE_VULKAN_SDK="$ENV{VULKAN_SDK}")
        # The framework's loader (volk) opens libvulkan by bare name; inside
        # Emacs no search path has it, so the SDK's lib folder is an rpath.
        set_target_properties(appine_vulkan_samples PROPERTIES BUILD_RPATH "$ENV{VULKAN_SDK}/lib")
    endif()
    set_target_properties(appine_vulkan_samples PROPERTIES
        PREFIX "" OUTPUT_NAME "appine-vulkan-samples"
        LIBRARY_OUTPUT_DIRECTORY "${APPINE_VKS_OUTPUT_DIR}"
        CXX_VISIBILITY_PRESET hidden)
    # Export only the C interface. This is required, not tidiness: the main
    # appine module carries its own SPIRV-Cross (for Shadertoy), a different
    # version from the one in here, and dyld merges same-named exported C++
    # symbols across libraries. Merged, the two versions corrupt the heap.
    target_link_options(appine_vulkan_samples PRIVATE
        "-Wl,-exported_symbols_list,${APPINE_VKS_DIR}/exports.txt")
endfunction()
