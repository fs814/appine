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
    target_include_directories(appine_vulkan_samples PRIVATE "${APPINE_VKS_DIR}")
    # Same libraries as the vulkan_samples executable (app/CMakeLists.txt).
    target_link_libraries(appine_vulkan_samples PRIVATE vkb__core vkb__filesystem apps plugins framework
)
    if(DEFINED ENV{VULKAN_SDK})
        target_compile_definitions(appine_vulkan_samples PRIVATE APPINE_VULKAN_SDK="$ENV{VULKAN_SDK}")
    endif()
    set_target_properties(appine_vulkan_samples PROPERTIES
        PREFIX "" OUTPUT_NAME "appine-vulkan-samples"
        LIBRARY_OUTPUT_DIRECTORY "${APPINE_VKS_OUTPUT_DIR}"
        # Only the C interface is exported; the framework stays private.
        CXX_VISIBILITY_PRESET hidden)
endfunction()
