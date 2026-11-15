/*
 * Filename: backend_metal_mlpass.m
 * Project: Appine (App in Emacs)
 * Description: Apple's "Running a machine learning model on the GPU timeline"
 *              sample (src/backends/metal/mlpass/, see the README there) in an
 *              appine tab. The sample is a command-line tool: it multiplies
 *              two random matrices with a Metal 4 machine learning pass and
 *              checks the product against the CPU. This tab does the same
 *              steps as its main.m and shows what it would print, with a
 *              button to run again on new matrices.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#import <QuartzCore/QuartzCore.h>
#import "appine_backend.h"
#import "metal/common/AppineMetalCommon.h"
#import "metal/mlpass/MLMatrixMultiplier.h"
#import "metal/mlpass/Matrix.h"

// The sample's matrix keeps its elements behind this undeclared accessor.
@interface AppineMLMatrix (AppineData)
- (NSData *)data;
@end

NSURL *appine_mlpass_package_url(NSString *name) {
    Dl_info info;
    if (!dladdr((const void *)&appine_mlpass_package_url, &info) || !info.dli_fname) return nil;
    NSString *root = [[@(info.dli_fname) stringByResolvingSymlinksInPath] stringByDeletingLastPathComponent];
    NSString *path = [NSString stringWithFormat:@"%@/src/backends/metal/mlpass/Packages/%@.mtlpackage", root, name];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? [NSURL fileURLWithPath:path] : nil;
}

// The sample's printWithName:, as text.
static NSString *appine_mlpass_format(AppineMLMatrix *m, NSString *name) {
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@ (%ld x %ld):\n", name, (long)m.rows, (long)m.columns];
    const float *v = (const float *)m.data.bytes;
    for (NSInteger r = 0; r < m.rows; r++) {
        for (NSInteger c = 0; c < m.columns; c++) [s appendFormat:@"%8.3f ", v[r * m.columns + c]];
        [s appendString:@"\n"];
    }
    [s appendString:@"\n"];
    return s;
}

@interface AppineMetalMLPassBackend : NSObject <AppineBackend>
@property (nonatomic, strong) NSView *view;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSTextView *textView;
@property (nonatomic, strong) NSTextField *rowsField, *innerField, *colsField;
@end

@implementation AppineMetalMLPassBackend

- (AppineBackendKind)kind {
    return AppineBackendKindMetal;
}

static NSTextField *appine_mlpass_size_field(NSInteger value) {
    NSTextField *f = [NSTextField textFieldWithString:[@(value) stringValue]];
    f.alignment = NSTextAlignmentRight;
    [f.widthAnchor constraintEqualToConstant:44].active = YES;
    return f;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _title = @"Metal ML Pass";
    _view = [[NSView alloc] initWithFrame:NSZeroRect];
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device || ![device supportsFamily:MTLGPUFamilyMetal4]) {
        NSView *message = appine_metal_message_view(
            @"Machine learning passes need Metal 4 (Apple silicon on macOS 26 or later).");
        message.frame = _view.bounds;
        [_view addSubview:message];
        return self;
    }

    // The sample's sizes: (3 x 4) * (4 x 2). Editable here.
    _rowsField = appine_mlpass_size_field(3);
    _innerField = appine_mlpass_size_field(4);
    _colsField = appine_mlpass_size_field(2);
    NSButton *run = [NSButton buttonWithTitle:@"Run again" target:self action:@selector(run:)];
    NSStackView *bar = [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:@"A:"], _rowsField, [NSTextField labelWithString:@"x"], _innerField,
        [NSTextField labelWithString:@"   B:"], [NSTextField labelWithString:@"(same) x"], _colsField, run]];
    bar.edgeInsets = NSEdgeInsetsMake(8, 12, 8, 12);
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    NSScrollView *scroll = [NSTextView scrollableTextView];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _textView = scroll.documentView;
    _textView.editable = NO;
    _textView.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    _textView.textContainerInset = NSMakeSize(12, 8);

    [_view addSubview:bar];
    [_view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:_view.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor],
    ]];
    [self run:nil];
    return self;
}

// The sample's main(): random matrices, CPU product, GPU product, compare.
- (void)run:(id)sender {
    NSInteger rows = MAX(1, MIN(_rowsField.integerValue, 512));
    NSInteger inner = MAX(1, MIN(_innerField.integerValue, 512));
    NSInteger cols = MAX(1, MIN(_colsField.integerValue, 512));
    BOOL small = rows * inner <= 64 && inner * cols <= 64 && rows * cols <= 64;
    srand(arc4random());  // the sample fills its matrices with rand()

    NSMutableString *out = [NSMutableString string];
    AppineMLMatrix *a = [AppineMLMatrix matrixWithRandomRows:rows columns:inner];
    AppineMLMatrix *b = [AppineMLMatrix matrixWithRandomRows:inner columns:cols];
    if (small) {
        [out appendString:appine_mlpass_format(a, @"Matrix 1")];
        [out appendString:appine_mlpass_format(b, @"Matrix 2")];
    }

    CFTimeInterval t0 = CACurrentMediaTime();
    AppineMLMatrix *cpu = [a multiplyWithMatrix:b];
    CFTimeInterval t1 = CACurrentMediaTime();

    AppineMLMatrixMultiplier *multiplier = [AppineMLMatrixMultiplier new];
    AppineMLMatrix *gpu = nil;
    CFTimeInterval t2 = 0, t3 = 0, t4 = 0;
    if (!multiplier) {
        [out appendString:@"Can't create the matrix multiplier (see the log for why).\n"];
    } else if (![multiplier configureWithMatrix1:a matrix2:b]) {
        [out appendString:@"Can't configure the machine learning pipeline (see the log).\n"];
    } else {
        t2 = CACurrentMediaTime();
        [multiplier encodeAndRunModelInference];
        t3 = CACurrentMediaTime();
        gpu = [[AppineMLMatrix alloc] initFromTensor:[multiplier productTensor]];
        t4 = t3;
    }

    if (cpu && gpu) {
        if (small) {
            [out appendString:appine_mlpass_format(cpu, @"CPU Product")];
            [out appendString:appine_mlpass_format(gpu, @"GPU Product")];
        } else {
            [out appendFormat:@"(%ld x %ld) * (%ld x %ld): matrices too large to list.\n\n",
                              (long)rows, (long)inner, (long)inner, (long)cols];
        }
        BOOL match = [gpu isEqualToMatrix:cpu];
        [out appendFormat:@"%@\n\n", match ? @"✅ GPU == CPU" : @"❌ GPU != CPU (the log has the first mismatch)"];
        [out appendFormat:@"CPU multiply:      %8.3f ms\nGPU ML pass:       %8.3f ms (encode, run, wait)\n",
                          (t1 - t0) * 1000, (t3 - t2) * 1000];
        (void)t4;
    }
    self.textView.string = out;
}

@end

// C API export
id<AppineBackend> appine_create_metal_mlpass_backend(void) {
    return [[AppineMetalMLPassBackend alloc] init];
}
