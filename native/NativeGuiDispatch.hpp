#pragma once

#include <exception>
#include <functional>
#include <dispatch/dispatch.h>
#import <Foundation/Foundation.h>

namespace ctpl {
// Studio's Cocoa Qt GUI runs on the process main thread. Keep every call
// asynchronous, including calls from main, so nested-dialog deferral still
// resumes in a fresh GUI task. A value parameter is essential: Objective-C
// blocks preserve C++ reference parameters instead of owning their referents.
inline void dispatch_gui(std::function<void()> task) {
    if (!task) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            @try {
                try { task(); }
                catch (const std::exception& error) {
                    NSLog(@"[custom-templates] GUI task failed: %s", error.what());
                } catch (...) {
                    NSLog(@"[custom-templates] GUI task failed with an unknown exception.");
                }
            } @catch (NSException* error) {
                NSLog(@"[custom-templates] GUI task failed: %@", error.reason);
            }
        }
    });
}
} // namespace ctpl
