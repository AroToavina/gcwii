// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

#import <memory>

#import "DiscIO/Enums.h"

#import "EmulationBootType.h"

class BootParameters;

NS_ASSUME_NONNULL_BEGIN

@interface EmulationBootParameter : NSObject

@property (nonatomic) EmulationBootType bootType;
@property (nonatomic) NSString* path;
@property (nonatomic) NSString* secondPath;
@property (nonatomic) bool isNKit;
@property (nonatomic) DiscIO::Region iplRegion;
// Optional BootSessionData provided by the NetPlay client. Ownership is transferred
// to generateDolphinBootParameter when the boot parameters are created.
@property (nonatomic) void* netplayBootSessionData;

- (std::unique_ptr<BootParameters>) generateDolphinBootParameter;

@end

NS_ASSUME_NONNULL_END
