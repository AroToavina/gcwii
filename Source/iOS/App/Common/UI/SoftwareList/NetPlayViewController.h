// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <UIKit/UIKit.h>

@class EmulationBootParameter;
@class NetPlayViewController;

@protocol NetPlayViewControllerDelegate <NSObject>
- (void)netPlayViewController:(NetPlayViewController*)controller
        didRequestGameLaunch:(EmulationBootParameter*)bootParameter;
- (void)netPlayViewControllerDidRequestSessionScreen:(NetPlayViewController*)controller;
@end

@interface NetPlayViewController : UIViewController <UITextFieldDelegate>

@property (nonatomic, weak) id<NetPlayViewControllerDelegate> delegate;

- (instancetype)initWithDelegate:(id<NetPlayViewControllerDelegate>)delegate;

// Returns the controller for the currently active NetPlay session, if any.
+ (nullable instancetype)activeSessionController;

// Presents this controller over another view controller. Used to reopen the
// session screen while a NetPlay game is running.
- (void)presentFromViewController:(UIViewController*)viewController;

@end
