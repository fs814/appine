#!/usr/bin/env python3
"""Build one of Apple's Metal sample projects as a loadable bundle for appine.

    build_sample.py SAMPLE_DIR OUT_DIR [--id ID] [--verbose]

The sample's own Xcode project is the source of truth: its macOS app target
gives the source files, resources, frameworks and build settings. Nothing in
the sample is edited. What makes the result loadable inside Emacs, next to
every other sample:

- Objective-C class names are global in a process, and most samples define
  the same ones (AAPLRenderer, AAPLViewController, ...). Every class the
  sample defines is renamed per sample with a -D macro from a generated
  prefix header; the storyboards are compiled from a copy whose customClass
  attributes are renamed to match.
- [NSBundle mainBundle] and -[MTLDevice newDefaultLibrary] would look inside
  Emacs.app. Both selectors are renamed the same way, to methods that answer
  with the sample's own bundle (generated appine_glue.m).
- A command-line sample's main() becomes appine_sample_main(), which the host
  calls with stdout captured.

Output: OUT_DIR/<ID>.bundle, plus OUT_DIR/<ID>.log with every command run.
"""
import argparse
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import sys

SDK = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"],
                     capture_output=True, text=True, check=True).stdout.strip()
ARCH = os.uname().machine
MIN_MACOS = "14.0"


class BuildError(Exception):
    pass


def link_or_copy(src, dst):
    """Resources can be hundreds of megabytes: hard-link when possible."""
    if os.path.exists(dst):
        os.remove(dst)
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)
    return dst


# ---------------------------------------------------------------- project ---

def load_project(sample_dir):
    projects = []
    for root, dirs, _ in os.walk(sample_dir):
        for d in dirs:
            if d.endswith(".xcodeproj"):
                projects.append(os.path.join(root, d))
        dirs[:] = [d for d in dirs if not d.endswith((".xcodeproj", ".xcassets", ".git"))]
    if not projects:
        raise BuildError("no .xcodeproj in the sample")
    projects.sort(key=len)
    pbx = os.path.join(projects[0], "project.pbxproj")
    data = json.loads(subprocess.run(["plutil", "-convert", "json", "-o", "-", pbx],
                                     capture_output=True, text=True, check=True).stdout)
    return os.path.dirname(projects[0]), data


class Project:
    def __init__(self, sample_dir):
        self.root, data = load_project(sample_dir)
        self.objects = data["objects"]
        self.main = self.objects[data["rootObject"]]
        self.parent = {}
        for key, obj in self.objects.items():
            for child in obj.get("children", []):
                self.parent[child] = key
        self.root = os.path.join(self.root, self.main.get("projectDirPath", ""))

    def path_of(self, ref):
        """Absolute path of a file or group reference."""
        obj = self.objects[ref]
        tree = obj.get("sourceTree", "<group>")
        path = obj.get("path", "")
        if tree == "<group>":
            parent = self.parent.get(ref)
            base = self.path_of(parent) if parent else self.root
            return os.path.normpath(os.path.join(base, path))
        if tree == "SOURCE_ROOT":
            return os.path.normpath(os.path.join(self.root, path))
        if tree == "SDKROOT":
            return os.path.join(SDK, path)
        return path  # BUILT_PRODUCTS_DIR, absolute, ...

    def settings(self, config_list_ref, config="Release"):
        configs = self.objects[config_list_ref]["buildConfigurations"]
        for ref in configs:
            if self.objects[ref].get("name") == config:
                return self.objects[ref].get("buildSettings", {})
        return self.objects[configs[0]].get("buildSettings", {})

    def macos_target(self):
        targets = [self.objects[t] for t in self.main["targets"]]
        apps = []
        for t in targets:
            if t.get("isa") != "PBXNativeTarget":
                continue
            s = self.settings(t["buildConfigurationList"])
            sdk = s.get("SDKROOT", self.settings(self.main["buildConfigurationList"]).get("SDKROOT", ""))
            kind = t.get("productType", "")
            if not kind.endswith(("application", "tool")):
                continue
            score = 0
            if sdk == "macosx" or "macos" in t["name"].lower() or "mac" in t["name"].lower().split("-"):
                score += 2
            if "ios" in t["name"].lower() or "tvos" in t["name"].lower() or sdk in ("iphoneos", "appletvos"):
                score -= 3
            if s.get("SUPPORTS_MACCATALYST") == "YES" or "SUPPORTED_PLATFORMS" in s and "macosx" in s["SUPPORTED_PLATFORMS"]:
                score += 1
            apps.append((score, t))
        if not apps:
            raise BuildError("no application or tool target")
        apps.sort(key=lambda x: -x[0])
        if apps[0][0] < 0:
            raise BuildError("no macOS target")
        return apps[0][1]

    def synced_files(self, target):
        """Files of folder-synchronised groups (Xcode 16) in TARGET.

        An exception set inverts membership for its target: in a folder the
        target syncs, the listed files are left out; in a folder it does not
        sync, the listed files are the only ones it gets."""
        out = []
        tkey = self.key_of(target)
        synced = set(target.get("fileSystemSynchronizedGroups", []))
        for gref, group in self.objects.items():
            if group.get("isa") != "PBXFileSystemSynchronizedRootGroup":
                continue
            listed = set()
            for eref in group.get("exceptions", []):
                exc = self.objects[eref]
                if exc.get("target") == tkey:
                    listed.update(exc.get("membershipExceptions", []))
            folder = self.path_of(gref)
            if gref not in synced:
                out += [os.path.join(folder, rel) for rel in sorted(listed)]
                continue
            for root, dirs, files in os.walk(folder):
                rel_root = os.path.relpath(root, folder)
                keep = []
                for d in dirs:
                    rel = os.path.normpath(os.path.join(rel_root, d))
                    if rel in listed:
                        continue
                    if d.endswith((".xcassets", ".storyboard", ".mtlpackage", ".mlpackage", ".bundle")):
                        out.append(os.path.join(root, d))  # a resource folder, copied whole
                        continue
                    keep.append(d)
                dirs[:] = keep
                for f in files:
                    rel = os.path.normpath(os.path.join(rel_root, f))
                    if rel not in listed and f != ".DS_Store":
                        out.append(os.path.join(root, f))
        return out

    def key_of(self, target):
        for k, v in self.objects.items():
            if v is target:
                return k
        return None

    def file_flags(self, target):
        """Per-file COMPILER_FLAGS from the target's sources phase."""
        flags = {}
        for ph in target.get("buildPhases", []):
            phase = self.objects[ph]
            if phase["isa"] != "PBXSourcesBuildPhase":
                continue
            for bf in phase.get("files", []):
                f = self.objects[bf]
                extra = f.get("settings", {}).get("COMPILER_FLAGS")
                if extra and f.get("fileRef"):
                    flags[self.path_of(f["fileRef"])] = shlex.split(extra)
        return flags

    def phase_files(self, target, isa):
        out = []
        for ph in target.get("buildPhases", []):
            phase = self.objects[ph]
            if phase["isa"] != isa:
                continue
            for bf in phase.get("files", []):
                ref = self.objects[bf].get("fileRef")
                if not ref:
                    continue
                obj = self.objects[ref]
                if obj["isa"] == "PBXVariantGroup":  # localized: Base.lproj/Main.storyboard
                    for child in obj.get("children", []):
                        out.append(self.path_of(child))
                else:
                    out.append(self.path_of(ref))
        return out


# --------------------------------------------------------------- settings ---

def expand(value, ctx):
    """$(VAR) / ${VAR} expansion, the subset Xcode samples use."""
    def sub(m):
        name = m.group(1) or m.group(2)
        return ctx.get(name.split(":")[0], "")
    return re.sub(r"\$\(([^)]+)\)|\$\{([^}]+)\}", sub, value)


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return [v for v in value if v != "$(inherited)"]
    return [v for v in shlex.split(value) if v != "$(inherited)"]


def merged_settings(project, target):
    s = dict(project.settings(project.main["buildConfigurationList"]))
    s.update(project.settings(target["buildConfigurationList"]))
    return s


# ------------------------------------------------------------------ build ---

class Builder:
    def __init__(self, sample_dir, out_dir, sample_id, verbose):
        self.sample_dir = os.path.abspath(sample_dir)
        self.id = sample_id
        self.prefix = "AMS_" + re.sub(r"[^A-Za-z0-9]", "", sample_id) + "_"
        self.out_dir = os.path.abspath(out_dir)
        self.work = os.path.join(self.out_dir, "obj", sample_id)
        self.bundle = os.path.join(self.out_dir, sample_id + ".bundle")
        self.verbose = verbose
        os.makedirs(self.work, exist_ok=True)
        self.log = open(os.path.join(self.out_dir, sample_id + ".log"), "w")

    def run(self, cmd, cwd=None):
        self.log.write("$ " + " ".join(shlex.quote(c) for c in cmd) + "\n")
        if self.verbose:
            print(" ".join(shlex.quote(c) for c in cmd))
        p = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
        self.log.write(p.stdout + p.stderr)
        self.log.flush()
        if p.returncode != 0:
            raise BuildError(f"{os.path.basename(cmd[0])} failed:\n" + (p.stderr or p.stdout)[-3000:])
        return p.stdout

    def build(self):
        project = Project(self.sample_dir)
        target = project.macos_target()
        s = merged_settings(project, target)
        ctx = {"SRCROOT": project.root, "PROJECT_DIR": project.root, "SDKROOT": SDK,
               "PROJECT_NAME": target["name"], "TARGET_NAME": target["name"],
               "PRODUCT_NAME": target["name"], "PLATFORM_NAME": "macosx"}

        sources = project.phase_files(target, "PBXSourcesBuildPhase")
        resources = project.phase_files(target, "PBXResourcesBuildPhase")
        for f in project.synced_files(target):
            if f.endswith((".m", ".mm", ".c", ".cpp", ".cc", ".metal", ".swift")):
                sources.append(f)
            elif not f.endswith((".h", ".hpp", ".md", ".entitlements", ".plist", ".xcconfig")):
                resources.append(f)
        frameworks = project.phase_files(target, "PBXFrameworksBuildPhase")
        is_tool = target.get("productType", "").endswith("tool")

        code = [f for f in sources if f.endswith((".m", ".mm", ".c", ".cpp", ".cc"))]
        metals = [f for f in sources if f.endswith(".metal")]
        swift = [f for f in sources if f.endswith(".swift")]
        self.swift_module = None
        if swift:
            # Swift classes are namespaced by module: a module name unique to
            # the sample avoids collisions without renaming anything.
            self.swift_module = self.prefix.rstrip("_")
        if not code and not swift:
            raise BuildError("no C/Objective-C sources in the macOS target")

        objc_files = [f for f in code if f.endswith((".m", ".mm"))]
        headers = []
        for root, _, files in os.walk(self.sample_dir):
            headers += [os.path.join(root, f) for f in files if f.endswith((".h", ".hpp"))]
        classes = self.find_classes(objc_files + headers)
        self.uses_metal_cpp = any(os.path.basename(h) == "Metal.hpp" for h in headers)

        # Is main() the app's (NSApplicationMain) or a command-line tool's?
        mains = [f for f in code if re.search(r"\bint\s+main\s*\(", open(f, errors="ignore").read())]
        app_main = [f for f in mains if "NSApplicationMain" in open(f, errors="ignore").read()]
        cli = is_tool or (mains and not app_main)
        code = [f for f in code if f not in app_main]

        info = self.info_plist(project, s, ctx)
        prefix_h = self.write_prefix(classes, s, project, ctx)
        glue_m = self.write_glue(classes)

        res_dir = os.path.join(self.bundle, "Contents", "Resources")
        exe_dir = os.path.join(self.bundle, "Contents", "MacOS")
        if os.path.exists(self.bundle):
            shutil.rmtree(self.bundle)
        os.makedirs(res_dir)
        os.makedirs(exe_dir)

        self.per_file_flags = project.file_flags(target)
        objects = self.compile(code, glue_m, prefix_h, s, project, ctx, cli)
        exe = os.path.join(exe_dir, self.id)
        if swift:
            self.compile_swift(swift, objects, s, project, ctx, exe, frameworks)
            objects = None
        fw = {"Cocoa", "Foundation", "Metal", "MetalKit", "QuartzCore", "ModelIO",
              "GameController", "CoreVideo", "Accelerate"}
        for f in frameworks:
            name = os.path.basename(f)
            if name.endswith(".framework"):
                fw.add(name[:-len(".framework")])
        link = ["clang++", "-bundle", "-arch", ARCH, "-isysroot", SDK,
                f"-mmacosx-version-min={self.min_macos(s)}", "-fobjc-arc", "-o", exe] + (objects or [])
        for name in sorted(fw):
            if os.path.isdir(os.path.join(SDK, "System/Library/Frameworks", name + ".framework")):
                link += ["-framework", name]
        for f in frameworks:
            if f.endswith((".tbd", ".dylib")):
                link.append("-l" + re.sub(r"^lib|\.(tbd|dylib)$", "", os.path.basename(f)))
        if objects is not None:
            self.run(link)

        if metals:
            self.metallib(metals, s, project, ctx, res_dir)
        storyboard = self.resources(resources, classes, res_dir, s)
        self.metal_library_dependencies(project, target, ctx)
        self.scripts(project, target, s, ctx)
        info.update({"CFBundleIdentifier": "appine.metal-sample." + self.id,
                     "CFBundleExecutable": self.id, "CFBundleName": self.id,
                     "CFBundlePackageType": "BNDL", "AppineSampleCLI": bool(cli)})
        info.pop("NSPrincipalClass", None)
        if storyboard:
            info["NSMainStoryboardFile"] = storyboard
        info["AppineSampleClassPrefix"] = self.prefix
        with open(os.path.join(self.bundle, "Contents", "Info.plist"), "wb") as fh:
            plistlib.dump(info, fh)
        return self.bundle

    def info_plist(self, project, s, ctx):
        """The target's Info.plist (for NSMainStoryboardFile), or {}."""
        path = s.get("INFOPLIST_FILE")
        if not path:
            return {}
        path = os.path.join(project.root, expand(path, ctx))
        try:
            with open(path, "rb") as fh:
                return plistlib.load(fh)
        except (OSError, plistlib.InvalidFileException):
            return {}

    def min_macos(self, s):
        v = s.get("MACOSX_DEPLOYMENT_TARGET", MIN_MACOS)
        return v if v >= MIN_MACOS else MIN_MACOS

    # -- naming
    def find_classes(self, files):
        names = set()
        for f in files:
            text = open(f, errors="ignore").read()
            for m in re.finditer(r"@(?:interface|implementation)\s+([A-Za-z_]\w*)\b(?!\s*\()", text):
                names.add(m.group(1))
        return sorted(names)

    def write_prefix(self, classes, s, project, ctx):
        # metal-cpp redeclares Foundation names in C++, so with it the system
        # headers are not pre-imported, and mainBundle / newDefaultLibrary
        # (also metal-cpp method names) are left to the host's runtime
        # redirects (backend_metal_samples.m) instead of macros.
        lines = ["// Generated by build_sample.py: per-sample names, see its docstring.",
                 "#ifdef __OBJC__"]
        if not self.uses_metal_cpp:
            lines += ["#import <Cocoa/Cocoa.h>",
                      "#import <Metal/Metal.h>",
                      "#import <MetalKit/MetalKit.h>",
                      "#import <ModelIO/ModelIO.h>"]
        pch = s.get("GCC_PREFIX_HEADER")
        if pch:
            lines.append(f'#import "{os.path.join(project.root, expand(pch, ctx))}"')
        if not self.uses_metal_cpp:
            lines += [f"@interface NSBundle ({self.prefix}Bundle)",
                      f"+ (NSBundle *){self.prefix}mainBundle;",
                      "@end"]
        for c in classes:
            lines.append(f"#define {c} {self.prefix}{c}")
        if not self.uses_metal_cpp:
            lines += [f"#define mainBundle {self.prefix}mainBundle",
                      # [device newDefaultLibrary] -> the same call on the sample's bundle
                      f"#define newDefaultLibrary newDefaultLibraryWithBundle:[NSBundle {self.prefix}mainBundle] error:nil"]
        lines.append("#endif")
        path = os.path.join(self.work, "appine_prefix.h")
        open(path, "w").write("\n".join(lines) + "\n")
        return path

    def write_glue(self, classes):
        p = self.prefix
        names = "".join(f'        @"{c}",\n' for c in classes)
        text = f"""// Generated by build_sample.py: the sample's bundle stands in for the main one.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>

@interface {p}Anchor : NSObject
@end
@implementation {p}Anchor
@end

@implementation NSBundle ({p}Bundle)
+ (NSBundle *){p}mainBundle {{
    return [NSBundle bundleForClass:[{p}Anchor class]];
}}
@end

// Called by appine each time this sample is opened. Keyed archives the sample
// ships (scenes, meshes) name its classes as written in its source; map those
// names to this bundle's renamed classes.
__attribute__((visibility("default"))) void appine_sample_activate(void) {{
    NSArray<NSString *> *names = @[
{names}    ];
    for (NSString *name in names) {{
        Class cls = NSClassFromString([@"{p}" stringByAppendingString:name]);
        if (!cls) continue;
        [NSKeyedUnarchiver setClass:cls forClassName:name];
        [NSKeyedArchiver setClassName:name forClass:cls];
    }}
}}
"""
        path = os.path.join(self.work, "appine_glue.m")
        open(path, "w").write(text)
        return path

    # -- compile
    def include_flags(self, s, project, ctx):
        flags = []
        for key in ("HEADER_SEARCH_PATHS", "USER_HEADER_SEARCH_PATHS"):
            for p in as_list(s.get(key)):
                p = expand(p, ctx).rstrip("/*").rstrip("*")
                if p:
                    flags.append("-I" + (p if os.path.isabs(p) else os.path.join(project.root, p)))
        # Samples include their own headers by bare name across folders.
        seen = set()
        for root, _, files in os.walk(self.sample_dir):
            if any(f.endswith((".h", ".hpp")) for f in files) and root not in seen:
                seen.add(root)
                flags.append("-iquote" + root)
        for d in as_list(s.get("GCC_PREPROCESSOR_DEFINITIONS")):
            flags.append("-D" + expand(d, ctx))
        return flags

    def compile(self, code, glue_m, prefix_h, s, project, ctx, cli):
        base = ["-arch", ARCH, "-isysroot", SDK, f"-mmacosx-version-min={self.min_macos(s)}",
                "-O2", "-g0", "-fvisibility=hidden", "-Wno-everything", "-fmodules",
                "-DTARGET_MACOS=1"] + self.include_flags(s, project, ctx)
        if cli:
            base.append("-Dmain=appine_sample_main_impl")
        arc = s.get("CLANG_ENABLE_OBJC_ARC", "NO") == "YES"  # Xcode's default is off
        std_cxx = s.get("CLANG_CXX_LANGUAGE_STANDARD", "gnu++17")
        objects = []
        for f in code + [glue_m]:
            obj = os.path.join(self.work, re.sub(r"[^A-Za-z0-9_.]", "_", os.path.relpath(f, "/")) + ".o")
            cmd = ["clang++" if f.endswith((".mm", ".cpp", ".cc")) else "clang"] + base
            if f.endswith((".mm", ".cpp", ".cc")):
                cmd.append("-std=" + std_cxx)
            if f.endswith((".m", ".mm")):
                cmd += ["-fobjc-arc" if arc else "-fno-objc-arc"]
                if f != glue_m:
                    cmd += ["-include", prefix_h]
            cmd += self.per_file_flags.get(f, [])
            cmd += ["-c", f, "-o", obj]
            self.run(cmd)
            objects.append(obj)
        if cli:
            # The host finds the tool's main by this exported name.
            entry = os.path.join(self.work, "appine_entry.c")
            open(entry, "w").write(
                "int appine_sample_main_impl(int, char **);\n"
                "__attribute__((visibility(\"default\"))) int appine_sample_main(int argc, char **argv)"
                " { return appine_sample_main_impl(argc, argv); }\n")
            obj = os.path.join(self.work, "appine_entry.o")
            self.run(["clang", "-arch", ARCH, "-isysroot", SDK, "-c", entry, "-o", obj])
            objects.append(obj)
        return objects

    def compile_swift(self, swift, objects, s, project, ctx, exe, frameworks):
        """Compile and link a Swift sample (plus the C/ObjC objects) in one go."""
        cmd = ["xcrun", "swiftc", "-emit-library", "-parse-as-library", "-O", "-wmo",
               "-module-name", self.swift_module, "-sdk", SDK,
               "-target", f"{ARCH}-apple-macos{self.min_macos(s)}", "-o", exe]
        bridge = s.get("SWIFT_OBJC_BRIDGING_HEADER")
        if bridge:
            cmd += ["-import-objc-header", os.path.join(project.root, expand(bridge, ctx))]
        for flag in self.include_flags(s, project, ctx):
            cmd += ["-Xcc", flag]
        for d in as_list(s.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS")):
            cmd += ["-D", d]
        fw = {"Cocoa", "Metal", "MetalKit", "ModelIO", "QuartzCore", "GameController"}
        fw |= {os.path.basename(f)[:-len(".framework")] for f in frameworks if f.endswith(".framework")}
        for name in sorted(fw):
            cmd += ["-framework", name]
        self.run(cmd + swift + objects)

    def metallib(self, metals, s, project, ctx, res_dir, name="default.metallib"):
        flags = ["-sdk", "macosx", "metal", f"-mmacosx-version-min={self.min_macos(s)}"]
        std = s.get("MTL_LANGUAGE_REVISION")
        if std and std.startswith("Metal") and std[len("Metal"):].isdigit():
            v = std[len("Metal"):]
            major, minor = v[0], v[1:] or "0"
            # Before Metal 3 the macOS dialects are named macos-metalX.Y.
            flags.append(f"-std=metal{major}.{minor}" if int(major) >= 3 else f"-std=macos-metal{major}.{minor}")
        for p in as_list(s.get("MTL_HEADER_SEARCH_PATHS")) + as_list(s.get("HEADER_SEARCH_PATHS")):
            p = expand(p, ctx).rstrip("/*").rstrip("*")
            if p:
                flags.append("-I" + (p if os.path.isabs(p) else os.path.join(project.root, p)))
        seen = set()
        for root, _, files in os.walk(self.sample_dir):
            if any(f.endswith((".h", ".metal")) for f in files) and root not in seen:
                seen.add(root)
                flags.append("-I" + root)
        for d in as_list(s.get("MTL_PREPROCESSOR_DEFINITIONS")):
            flags.append("-D" + expand(d, ctx))
        airs = []
        for m in metals:
            air = os.path.join(self.work, name + "-" + os.path.basename(m) + ".air")
            self.run(["xcrun"] + flags + ["-c", m, "-o", air])
            airs.append(air)
        self.run(["xcrun", "-sdk", "macosx", "metallib"] + airs +
                 ["-o", os.path.join(res_dir, name)])

    # -- metal-library targets this one depends on
    def metal_library_dependencies(self, project, target, ctx):
        """Build dependency targets of type metal-library into
        OUT_DIR/<product>.metallib, where the app's scripts copy them from."""
        for dref in target.get("dependencies", []):
            tref = project.objects[dref].get("target")
            dep = project.objects.get(tref) if tref else None
            if not dep or dep.get("productType") != "com.apple.product-type.metal-library":
                continue
            ds = merged_settings(project, dep)
            metals = [f for f in project.phase_files(dep, "PBXSourcesBuildPhase") if f.endswith(".metal")]
            metals += [f for f in project.synced_files(dep) if f.endswith(".metal")]
            product = expand(ds.get("PRODUCT_NAME", dep["name"]), dict(ctx, TARGET_NAME=dep["name"]))
            if metals:
                self.metallib(metals, ds, project, ctx, self.out_dir, product + ".metallib")

    # -- shell-script phases
    def scripts(self, project, target, s, ctx):
        """Run the target's shell-script phases (some samples build extra
        .metallib files there) with the build variables Xcode would set."""
        env = dict(os.environ)
        # Project settings, as Xcode exports them; unexpanded or tool-steering
        # ones (TOOLCHAINS, SDKROOT=macosx, ...) would mislead xcrun's shims.
        env.update({k: v for k, v in s.items()
                    if isinstance(v, str) and "$" not in v
                    and k not in ("TOOLCHAINS", "SDKROOT", "PATH", "DEVELOPER_DIR")})
        temp = os.path.join(self.work, "script-temp")
        os.makedirs(temp, exist_ok=True)
        developer = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True).stdout.strip()
        env.update({
            "SRCROOT": project.root, "PROJECT_DIR": project.root, "SOURCE_ROOT": project.root,
            "TARGET_NAME": target["name"], "PROJECT_NAME": target["name"], "PRODUCT_NAME": self.id,
            "TARGET_BUILD_DIR": self.out_dir, "BUILT_PRODUCTS_DIR": self.out_dir,
            "UNLOCALIZED_RESOURCES_FOLDER_PATH": os.path.join(self.id + ".bundle", "Contents", "Resources"),
            "CONTENTS_FOLDER_PATH": os.path.join(self.id + ".bundle", "Contents"),
            "TARGET_TEMP_DIR": temp, "TEMP_DIR": temp, "DERIVED_FILE_DIR": temp, "DERIVED_FILES_DIR": temp,
            "OBJECT_FILE_DIR": temp, "PROJECT_TEMP_DIR": temp, "CONFIGURATION": "Release",
            "PLATFORM_NAME": "macosx", "EFFECTIVE_PLATFORM_NAME": "", "SDKROOT": SDK, "SDK_NAME": "macosx",
            "ARCHS": ARCH, "NATIVE_ARCH": ARCH, "CURRENT_ARCH": ARCH, "ACTION": "build",
            "MACOSX_DEPLOYMENT_TARGET": self.min_macos(s), "DEVELOPER_DIR": developer,
        })
        # Scripts call `metal` and `metallib` by name, as Xcode's PATH allows.
        # The Metal toolchain must come first: Xcode's default toolchain has
        # a placeholder `metal` that only says the toolchain is missing.
        tools = []
        for t in ("metal", "metallib", "clang"):
            d = os.path.dirname(subprocess.run(["xcrun", "-sdk", "macosx", "-f", t],
                                               capture_output=True, text=True).stdout.strip())
            if d and d not in tools:
                tools.append(d)
        env["PATH"] = os.pathsep.join(tools + [env.get("PATH", "")])
        for ph in target.get("buildPhases", []):
            phase = project.objects[ph]
            if phase["isa"] != "PBXShellScriptBuildPhase":
                continue
            script = phase.get("shellScript", "")
            shell = phase.get("shellPath", "/bin/sh")
            for kind in ("INPUT", "OUTPUT"):
                paths = [expand(x, env) for x in phase.get(kind.lower() + "Paths", [])]
                env[f"SCRIPT_{kind}_FILE_COUNT"] = str(len(paths))
                for i, x in enumerate(paths):
                    env[f"SCRIPT_{kind}_FILE_{i}"] = x
                    if kind == "OUTPUT":
                        os.makedirs(os.path.dirname(x), exist_ok=True)
            self.log.write(f"# script phase: {phase.get('name', '')}\n{script}\n")
            p = subprocess.run([shell, "-c", script], env=env, cwd=project.root, capture_output=True, text=True)
            self.log.write(p.stdout + p.stderr)
            if p.returncode != 0:
                raise BuildError(f"script phase '{phase.get('name', '')}' failed:\n" + (p.stderr or p.stdout)[-2000:])

    # -- resources
    def resources(self, resources, classes, res_dir, s):
        storyboard = None
        catalogs = []
        for r in resources:
            name = os.path.basename(r)
            if name.endswith(".storyboard"):
                lower = r.lower()
                if "ios" in lower or "tvos" in lower or "launch" in lower:
                    continue
                storyboard = self.storyboard(r, classes, res_dir) or storyboard
            elif name.endswith(".xcassets"):
                catalogs.append(r)
            elif name.endswith((".xib", ".plist", ".entitlements")):
                continue
            elif os.path.isdir(r):
                shutil.copytree(r, os.path.join(res_dir, name), dirs_exist_ok=True, copy_function=link_or_copy)
            elif os.path.exists(r):
                link_or_copy(r, os.path.join(res_dir, name))
            else:
                self.log.write(f"missing resource: {r}\n")
        if catalogs:
            partial = os.path.join(self.work, "assets-info.plist")
            self.run(["xcrun", "actool", "--compile", res_dir, "--platform", "macosx",
                      "--minimum-deployment-target", self.min_macos(s),
                      "--output-partial-info-plist", partial, "--warnings",
                      "--app-icon", "AppIcon"] + catalogs)
        return storyboard

    def storyboard(self, path, classes, res_dir):
        text = open(path, encoding="utf-8").read()
        known = set(classes)
        text = re.sub(r'customClass="([A-Za-z_]\w*)"',
                      lambda m: f'customClass="{self.prefix}{m.group(1)}"' if m.group(1) in known else m.group(0),
                      text)
        if self.swift_module:
            text = re.sub(r'customModule="[^"]*"', f'customModule="{self.swift_module}"', text)
        name = os.path.splitext(os.path.basename(path))[0]
        copy = os.path.join(self.work, os.path.basename(path))
        open(copy, "w", encoding="utf-8").write(text)
        self.run(["xcrun", "ibtool", "--compile", os.path.join(res_dir, name + ".storyboardc"),
                  "--target-device", "mac", "--minimum-deployment-target", MIN_MACOS, copy])
        return name


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sample_dir")
    ap.add_argument("out_dir")
    ap.add_argument("--id")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    sid = a.id or os.path.basename(os.path.normpath(a.sample_dir))
    try:
        path = Builder(a.sample_dir, a.out_dir, sid, a.verbose).build()
    except BuildError as e:
        print(f"FAILED {sid}: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"OK {sid}: {path}")


if __name__ == "__main__":
    main()
