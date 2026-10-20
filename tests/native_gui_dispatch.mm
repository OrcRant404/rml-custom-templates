#ifndef CTPL_GUI_DISPATCH_HEADER
#define CTPL_GUI_DISPATCH_HEADER "../native/NativeGuiDispatch.hpp"
#endif
#include CTPL_GUI_DISPATCH_HEADER

#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <memory>
#include <pthread.h>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

static std::atomic<unsigned> completions{0}, released{0};
static std::weak_ptr<std::string> lifetime;
static std::vector<int> order;

__attribute__((noinline)) static void schedule_owned_task() {
    auto owner = std::shared_ptr<std::string>(new std::string(4096, 'Q'), [](std::string *value) {
        assert(pthread_main_np());
        ++released;
        delete value;
    });
    lifetime = owner;
    std::function<void()> task = [owner, calls = 0]() mutable {
        assert(pthread_main_np());
        assert(owner->size() == 4096 && owner->front() == 'Q' && owner->back() == 'Q');
        assert(++calls == 1);
        ++completions;
    };
    ctpl::dispatch_gui(task);
    task = {};
}

static void pump_until(unsigned expected) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (completions < expected && std::chrono::steady_clock::now() < deadline)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    assert(completions == expected);
    for (unsigned index = 0; index < 4; ++index)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
}

int main() {
    @autoreleasepool {
        schedule_owned_task();
#ifdef CTPL_EXPECT_BROKEN
        assert(completions == 0);
#else
        assert(completions == 0 && released == 0 && !lifetime.expired());
#endif
        pump_until(1);
#ifdef CTPL_EXPECT_BROKEN
        return 0;
#endif
        assert(lifetime.expired() && released == 1);
        std::puts("PASS: main-thread dispatch is deferred and owns expired caller arguments");

        std::thread producer([] { schedule_owned_task(); });
        producer.join();
        assert(completions == 1 && released == 1 && !lifetime.expired());
        pump_until(2);
        assert(lifetime.expired() && released == 2);
        std::puts("PASS: background caller dispatches once on main and releases its closure on main");

        ctpl::dispatch_gui([] {
            order.push_back(1);
            ctpl::dispatch_gui([] { order.push_back(3); ++completions; });
            order.push_back(2);
        });
        pump_until(3);
        assert((order == std::vector<int>{1, 2, 3}));
        std::puts("PASS: follow-up work runs after the current GUI task returns");

        ctpl::dispatch_gui([] { throw std::runtime_error("intentional C++ regression test"); });
        ctpl::dispatch_gui([] {
            @throw [NSException exceptionWithName:@"CTPLTest"
                                            reason:@"intentional Objective-C regression test"
                                          userInfo:nil];
        });
        ctpl::dispatch_gui({});
        ctpl::dispatch_gui([] { assert(pthread_main_np()); ++completions; });
        pump_until(4);
        std::puts("PASS: C++/Objective-C exceptions stay within the task and later tasks still run");
    }
}
