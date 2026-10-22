// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

// libdolphin is built with -fvisibility=hidden, so everything the app calls has to be
// exported explicitly (same as the NetPlay C API).
#define DOL_LOG_EXPORT extern __attribute__((visibility("default")))

NS_ASSUME_NONNULL_BEGIN

// events.log is written next to the game files in the app's Documents folder, so it
// can be pulled off the device through the Files app or Finder. It is truncated
// every time the app boots.
DOL_LOG_EXPORT NSString* DOLLogFilePath(void);

// Truncates events.log and writes a header describing this launch.
DOL_LOG_EXPORT void DOLLogStartSession(void);

// Appends uncaught exceptions and fatal signals (with a backtrace) to events.log
// before the process dies, so a crash still leaves something readable behind.
DOL_LOG_EXPORT void DOLLogInstallCrashHandlers(void);

// Mirrors Dolphin's own logging (NetPlay, core, boot, input) into events.log.
DOL_LOG_EXPORT void DOLLogEnableCoreLogging(void);

DOL_LOG_EXPORT void DOLLogWrite(const char* _Nullable tag, NSString* _Nullable message);
DOL_LOG_EXPORT void DOLLogWriteF(const char* _Nullable tag, NSString* _Nullable format, ...)
    NS_FORMAT_FUNCTION(2, 3);

// Convenience wrapper so Swift sources can log as well. The class needs the explicit
// visibility attribute for the same reason as the functions above.
__attribute__((visibility("default")))
@interface DOLDebugLog : NSObject

+ (void)logTag:(NSString*)tag message:(NSString*)message NS_SWIFT_NAME(logTag(_:message:));
+ (NSString*)filePath;

@end

NS_ASSUME_NONNULL_END
