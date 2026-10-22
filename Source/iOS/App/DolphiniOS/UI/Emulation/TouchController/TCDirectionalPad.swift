// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

class TCDirectionalPad: UIView
{
  let hapticGenerator = UIImpactFeedbackGenerator(style: .medium)

  var dpadNoPressed: UIImage? = nil
  var dpadOnePressed: UIImage? = nil
  var dpadTwoPressed: UIImage? = nil
  
  @IBInspectable var directionalPadType: Int = 6 // default: GC D-Pad
  
  var port: Int = 0
  var isPressed: Bool = false
  
  private var isInitialized = false

  override init(frame: CGRect)
  {
    super.init(frame: frame)
    sharedInit()
  }
  
  required init?(coder: NSCoder)
  {
    super.init(coder: coder)
  }
  
  override func awakeFromNib()
  {
    super.awakeFromNib()
    sharedInit()
  }
  
  func sharedInit()
  {
    if isInitialized { return }
    isInitialized = true
    // Load image
    dpadNoPressed = getImage(imageName: "gcwii_dpad")
    dpadOnePressed = getImage(imageName: "gcwii_dpad_pressed_one_direction")
    dpadTwoPressed = getImage(imageName: "gcwii_dpad_pressed_two_directions")
    
    // Create the image view
    let imageView = UIImageView(frame: CGRect(x: 0, y: 0, width: self.frame.width, height: self.frame.height))
    imageView.image = dpadNoPressed
    imageView.center = self.convert(self.center, from: self.superview)
    imageView.isUserInteractionEnabled = true
      
    let pressHandler = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
    pressHandler.minimumPressDuration = 0
    imageView.addGestureRecognizer(pressHandler)
    
    self.addSubview(imageView)
    
    // Set background color to transparent
    self.backgroundColor = UIColor.clear
  }
  
  func getImage(imageName: String) -> UIImage
  {
    // In Interface Builder, the default bundle is not Dolphin's, so we must specify
    // the bundle for the image to load correctly
    return UIImage(named: imageName, in: Bundle(for: type(of: self)), compatibleWith: nil)!
  }
  
  @objc func handleLongPress(gesture: UILongPressGestureRecognizer)
  {
    if (TCView.isEditMode)
    {
      return
    }
    guard let imageView = gesture.view as? UIImageView else { return }
    let point = gesture.location(in: self)
    var buttonPresses: [Bool] = [ false, false, false, false ]
    
    if (gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed)
    {
      imageView.image = dpadNoPressed
      imageView.transform = .identity
      self.isPressed = false
    }
    else
    {
      if (!self.isPressed)
      {
        hapticGenerator.impactOccurred()
        self.isPressed = true
      }
      
      // Get button boundary
      let buttonBounds = gesture.view!.frame.width / 3
      
      // Up
      if (point.y <= buttonBounds)
      {
        buttonPresses[0] = true;
      }
      else if (point.y >= buttonBounds * 2) // Down
      {
        buttonPresses[1] = true;
      }
      
      // Left
      if (point.x <= buttonBounds)
      {
        buttonPresses[2] = true;
      }
      else if (point.x >= buttonBounds * 2) // Right
      {
        buttonPresses[3] = true;
      }
      
      var rotation: CGFloat = 0
      
      // TODO: is there a better way to structure this?
      // Left and Up
      if (buttonPresses[2] && buttonPresses[0])
      {
        imageView.image = dpadTwoPressed
        rotation = 0
      }
      else if (buttonPresses[0] && buttonPresses[3]) // Up and Right
      {
        imageView.image = dpadTwoPressed
        rotation = 90
      }
      else if (buttonPresses[3] && buttonPresses[1]) // Right and Down
      {
        imageView.image = dpadTwoPressed
        rotation = 180
      }
      else if (buttonPresses[1] && buttonPresses[2]) // Down and Left
      {
        imageView.image = dpadTwoPressed
        rotation = 270
      }
      else if (buttonPresses[0]) // Up
      {
        imageView.image = dpadOnePressed
        rotation = 0
      }
      else if (buttonPresses[1]) // Down
      {
        imageView.image = dpadOnePressed
        rotation = 180
      }
      else if (buttonPresses[2]) // Left
      {
        imageView.image = dpadOnePressed
        rotation = 270
      }
      else if (buttonPresses[3]) // Right
      {
        imageView.image = dpadOnePressed
        rotation = 90
      }
      else
      {
        imageView.image = dpadNoPressed
      }
      
      let radians = rotation * (CGFloat.pi / 180)
      imageView.transform = CGAffineTransform.identity.rotated(by: radians)
    }
    
    // Send button values
    for (i, press) in buttonPresses.enumerated()
    {
      TCManagerInterface.setButtonStateFor(directionalPadType + i, controller: port, state: press)
    }
  }
  
  // Releases every direction, e.g. when the pads are hidden or the app is backgrounded
  // in the middle of a press.
  @objc func releaseAllButtons()
  {
    isPressed = false
    if let imageView = subviews.compactMap({ $0 as? UIImageView }).first
    {
      imageView.image = dpadNoPressed
      imageView.transform = .identity
    }
    for i in 0..<4
    {
      TCManagerInterface.setButtonStateFor(directionalPadType + i, controller: port, state: false)
    }
  }
}
