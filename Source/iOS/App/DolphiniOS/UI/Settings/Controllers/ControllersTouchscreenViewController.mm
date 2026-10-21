// Copyright 2024 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "ControllersTouchscreenViewController.h"

#import "Core/Config/iOSSettings.h"

#import "Swift.h"

@interface ControllersTouchscreenViewController ()

@end

@implementation ControllersTouchscreenViewController

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  
  self.opacitySlider.value = Config::Get(Config::MAIN_TOUCH_PAD_OPACITY);
  
  TCWiiTouchIRMode irMode = (TCWiiTouchIRMode)Config::Get(Config::MAIN_TOUCH_PAD_IR_MODE);
  NSString* irModeString;
  
  if (irMode == TCWiiTouchIRModeNone) {
    irModeString = @"Disabled";
  } else if (irMode == TCWiiTouchIRModeFollow) {
    irModeString = @"Follow";
  } else {
    irModeString = @"Drag";
  }
  
  self.irModeLabel.text = irModeString;
}

- (IBAction)opacitySliderChanged:(id)sender {
  Config::SetBaseOrCurrent(Config::MAIN_TOUCH_PAD_OPACITY, self.opacitySlider.value);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  if (section == 0) {
    return [super tableView:tableView numberOfRowsInSection:0];
  }
  return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  if (section == 1) {
    return @"Touch Controller Layout";
  }
  return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section == 1) {
    return 44.0;
  }
  return [super tableView:tableView heightForRowAtIndexPath:indexPath];
}

- (NSInteger)tableView:(UITableView *)tableView indentationLevelForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section == 1) {
    return 0;
  }
  return [super tableView:tableView indentationLevelForRowAtIndexPath:indexPath];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section == 0) {
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
  }
  
  UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"CustomLayoutCell"];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"CustomLayoutCell"];
  }
  if (indexPath.row == 0) {
    cell.textLabel.text = @"Customize Layout";
    cell.textLabel.textColor = self.view.tintColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  } else {
    cell.textLabel.text = @"Reset Layout to Defaults";
    cell.textLabel.textColor = [UIColor systemRedColor];
    cell.accessoryType = UITableViewCellAccessoryNone;
  }
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section == 1) {
    [tableView deselectRowAtIndexPath:indexPath animated:true];
    if (indexPath.row == 0) {
      [TCEditLayoutViewController presentFrom:self];
    } else {
      [self promptResetLayout];
    }
    return;
  }
  [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (void)promptResetLayout {
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Reset Layout"
                                                                 message:@"Are you sure you want to reset all touch controller buttons to their default positions?"
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction*) {
    [TCView resetAllLayouts];
  }]];
  [self presentViewController:alert animated:true completion:nil];
}

@end
