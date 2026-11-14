/*
 * Filename: appine_vulkan_samples.cpp
 * Project: Appine (App in Emacs)
 * Description: Runs Khronos Vulkan-Samples inside an appine tab. This is the
 *              "appine platform" for the samples' framework, modelled on its
 *              iOS platform (framework/platform/ios): the window is a
 *              CAMetalLayer that appine owns, and appine calls for one frame
 *              per display tick instead of the framework owning a main loop.
 *
 * SPDX-License-Identifier: Apache-2.0  (uses the Vulkan-Samples framework)
 */
#include "appine_vulkan_samples.h"

#include "apps.h"
#include "platform/input_events.h"
#include "platform/platform.h"
#include "platform/window.h"
#include "plugins/plugins.h"

#include <core/platform/context.hpp>
#include <filesystem/filesystem.hpp>

// Plain C++ on purpose: Vulkan's C++ headers do not compile as Objective-C++.
// The CAMetalLayer is an opaque pointer here, as in <vulkan/vulkan_metal.h>.

#include <cstdio>
#include <cstdlib>
#include <memory>

namespace
{
// What main() would pass: the arguments, and where assets/ and shaders/ are.
class AppineContext final : public vkb::PlatformContext
{
  public:
	AppineContext(std::vector<std::string> arguments, const std::string &root)
	{
		_arguments                  = std::move(arguments);
		_external_storage_directory = root;
		const char *tmp             = std::getenv("TMPDIR");
		_temp_directory             = tmp ? std::string(tmp) + "/" : "/tmp/";
	}
};

class AppineWindow final : public vkb::Window
{
  public:
	AppineWindow(const Window::Properties &properties, const CAMetalLayer *layer, float scale) :
	    Window(properties), layer(layer), scale(scale)
	{}

	VkSurfaceKHR create_surface(vkb::core::InstanceC &instance) override
	{
		return create_surface(instance.get_handle(), VK_NULL_HANDLE);
	}

	VkSurfaceKHR create_surface(VkInstance instance, VkPhysicalDevice) override
	{
		if (instance == VK_NULL_HANDLE)
		{
			return VK_NULL_HANDLE;
		}
		VkSurfaceKHR                surface{};
		VkMetalSurfaceCreateInfoEXT info{VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT};
		info.pLayer = layer;
		VK_CHECK(vkCreateMetalSurfaceEXT(instance, &info, nullptr, &surface));
		return surface;
	}

	bool should_close() override
	{
		return closed;
	}

	void close() override
	{
		closed = true;
	}

	float get_dpi_factor() const override
	{
		return 1.0f;
	}

	float get_content_scale_factor() const override
	{
		return scale;
	}

	std::vector<const char *> get_required_surface_extensions() const override
	{
		return {VK_EXT_METAL_SURFACE_EXTENSION_NAME};
	}

  private:
	const CAMetalLayer *layer;
	float               scale;
	bool                closed{false};
};

class AppinePlatform final : public vkb::Platform
{
  public:
	AppinePlatform(const vkb::PlatformContext &context, const CAMetalLayer *layer, float scale, uint32_t width, uint32_t height) :
	    Platform{context}, layer(layer), scale(scale), extent{width, height}
	{}

  protected:
	void create_window(const vkb::Window::Properties &properties) override
	{
		// The tab, not a command-line option, decides the size.
		auto sized   = properties;
		sized.extent = extent;
		window       = std::make_unique<AppineWindow>(sized, layer, scale);
	}

  private:
	const CAMetalLayer *layer;
	float               scale;
	vkb::Window::Extent extent;
};

std::unique_ptr<AppineContext>  g_context;
std::unique_ptr<AppinePlatform> g_platform;

void set_error(char *err, size_t len, const std::string &message)
{
	if (err && len)
	{
		std::snprintf(err, len, "%s", message.c_str());
	}
}

// The Vulkan loader finds its driver (MoltenVK) through these variables. A
// shell gets them from the SDK's setup-env.sh; Emacs started from the Dock
// does not, so they default to the SDK this library was built against.
void use_sdk_driver_if_unset()
{
#ifdef APPINE_VULKAN_SDK
	const std::string icd = std::string(APPINE_VULKAN_SDK) + "/share/vulkan/icd.d/MoltenVK_icd.json";
	setenv("VK_ICD_FILENAMES", icd.c_str(), 0);
	setenv("VK_DRIVER_FILES", icd.c_str(), 0);
#endif
}
}        // namespace

int appine_vks_running(void)
{
	return g_platform ? 1 : 0;
}

int appine_vks_start(void *metal_layer, const char *sample_id, const char *root,
                     uint32_t width, uint32_t height, float scale, char *err, size_t err_len)
{
	if (g_platform)
	{
		set_error(err, err_len, "Another Vulkan sample is already running; close its tab first.");
		return 1;
	}
	if (!apps::get_sample(sample_id))
	{
		set_error(err, err_len, std::string("Unknown Vulkan sample: ") + sample_id);
		return 1;
	}
	try
	{
		use_sdk_driver_if_unset();
		g_context = std::make_unique<AppineContext>(std::vector<std::string>{"sample", sample_id}, root);
		vkb::filesystem::init_with_context(*g_context);
		g_platform = std::make_unique<AppinePlatform>(*g_context, static_cast<const CAMetalLayer *>(metal_layer), scale, width, height);

		auto code = g_platform->initialize(plugins::get_all());
		if (code != vkb::ExitCode::Success)
		{
			std::string reason = g_platform->get_last_error();
			appine_vks_stop();
			set_error(err, err_len, reason.empty() ? "The sample could not be started." : reason);
			return 1;
		}
	}
	catch (const std::exception &e)
	{
		std::string reason = e.what();
		appine_vks_stop();
		set_error(err, err_len, reason);
		return 1;
	}
	return 0;
}

int appine_vks_frame(char *err, size_t err_len)
{
	if (!g_platform)
	{
		set_error(err, err_len, "No Vulkan sample is running.");
		return 1;
	}
	vkb::ExitCode code = vkb::ExitCode::FatalError;
	std::string   reason;
	try
	{
		code   = g_platform->main_loop_frame();
		reason = g_platform->get_last_error();
	}
	catch (const std::exception &e)
	{
		reason = e.what();
	}
	catch (...)
	{
		reason = "Unknown error in the sample.";
	}
	if (code == vkb::ExitCode::Success)
	{
		return 0;
	}
	if (reason.empty())
	{
		reason = code == vkb::ExitCode::Close ? "The sample finished." : "The sample stopped (see the log).";
	}
	set_error(err, err_len, reason);
	return 1;
}

void appine_vks_resize(uint32_t width, uint32_t height)
{
	if (g_platform)
	{
		try
		{
			g_platform->resize(width, height);
		}
		catch (...)
		{}
	}
}

void appine_vks_mouse(int action, float x, float y)
{
	if (!g_platform)
	{
		return;
	}
	const vkb::MouseAction actions[] = {vkb::MouseAction::Down, vkb::MouseAction::Up, vkb::MouseAction::Move};
	if (action < 0 || action > 2)
	{
		return;
	}
	try
	{
		g_platform->input_event(vkb::MouseButtonInputEvent{vkb::MouseButton::Left, actions[action], x, y});
	}
	catch (...)
	{}
}

void appine_vks_stop(void)
{
	if (g_platform)
	{
		try
		{
			g_platform->terminate(vkb::ExitCode::Success);
		}
		catch (...)
		{}
	}
	g_platform.reset();
	g_context.reset();
}
