// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "JitManager+Debugger.h"

#import <math.h>
#import <sys/utsname.h>
#import <unistd.h>

#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000

extern int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

@implementation JitManager (Debugger)

- (bool)checkIfProcessIsDebugged {
  int flags;
  if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags) != 0)) {
    return false;
  }

  return flags & CS_DEBUGGED;
}

// The following TXM detection is adapted from StikDebug.
// https://github.com/StephenDev0/StikDebug/blob/ef5e962b381edc3348d34f219ef9352cec49ec26/StikDebug/Support/ProcessInfo%2BTXM.swift

- (nullable NSNumber*)deviceVersionFromIdentifier:(NSString*)identifier
                                          pattern:(NSString*)pattern {
  NSError* error = nil;
  NSRegularExpression* regex =
      [NSRegularExpression regularExpressionWithPattern:pattern
                                                options:0
                                                  error:&error];
  if (!regex) {
    return nil;
  }

  NSTextCheckingResult* match =
      [regex firstMatchInString:identifier
                        options:0
                          range:NSMakeRange(0, identifier.length)];
  if (!match || match.numberOfRanges < 3) {
    return nil;
  }

  NSRange majorRange = [match rangeAtIndex:1];
  NSRange minorRange = [match rangeAtIndex:2];
  if (majorRange.location == NSNotFound || minorRange.location == NSNotFound) {
    return nil;
  }

  NSString* majorString = [identifier substringWithRange:majorRange];
  NSString* minorString = [identifier substringWithRange:minorRange];
  double divisor = pow(10.0, minorString.length);

  return @(majorString.doubleValue + (minorString.doubleValue / divisor));
}

- (nullable NSNumber*)deviceVersionFromIdentifier:(NSString*)identifier {
  NSNumber* iPhoneVersion =
      [self deviceVersionFromIdentifier:identifier
                                pattern:@"iPhone(\\d+),(\\d+)"];
  if (iPhoneVersion) {
    return iPhoneVersion;
  }

  return [self deviceVersionFromIdentifier:identifier
                                   pattern:@"iPad(\\d+),(\\d+)"];
}

- (NSString*)hardwareIdentifier {
  struct utsname systemInfo;
  uname(&systemInfo);

  return [NSString stringWithCString:systemInfo.machine
                            encoding:NSUTF8StringEncoding] ?: @"";
}

- (bool)checkIfDeviceUsesTXM {
  NSString* identifier = [self hardwareIdentifier];

  if (@available(iOS 27.0, *)) {
    return ![identifier isEqualToString:@"iPad8,11"] &&
           ![identifier isEqualToString:@"iPad8,12"];
  }

  if (@available(iOS 26.0, *)) {
    const double firstTXMDeviceVersion = 14.2;
    const double firstIPadTXMDeviceVersion = 14.5;

    NSNumber* deviceVersion =
        [self deviceVersionFromIdentifier:identifier];

    if (!deviceVersion) {
      return false;
    }

    if ([identifier hasPrefix:@"iPad"]) {
      return deviceVersion.doubleValue >= firstIPadTXMDeviceVersion;
    }

    return deviceVersion.doubleValue >= firstTXMDeviceVersion;
  }

  return false;
}

@end
