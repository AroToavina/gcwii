// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

class TCJoystick: UIView
{
  @IBInspectable var joystickType: Int = 10 // default: GC stick
  var port: Int = 0

  private var isInitialized = false
  private var rangeView: UIImageView?
  private var handleView: UIImageView?
  private var panRecognizer: UIPanGestureRecognizer?
  private var lastLoggedAxes = ""

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

    // Create the range
    let rangeImage = createImageView(imageName: "gcwii_joystick_range")
    rangeImage.isUserInteractionEnabled = false
    self.addSubview(rangeImage)
    rangeView = rangeImage

    // Create handle. The handle is only a visual; the pan recognizer lives on the
    // joystick itself so touching anywhere inside the control works, not just the
    // small handle image.
    let handle = createImageView(imageName: TCButtonType(rawValue: joystickType)!.getImageName())
    handle.isUserInteractionEnabled = false
    self.addSubview(handle)
    handleView = handle

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
    pan.maximumNumberOfTouches = 1
    pan.cancelsTouchesInView = true
    addGestureRecognizer(pan)
    panRecognizer = pan

    // Set background color to transparent
    self.backgroundColor = UIColor.clear
    self.isUserInteractionEnabled = true

    DOLDebugLog.logTag("TOUCH", message: "joystick type=\(joystickType) port=\(port) created")
    layoutImages()
  }

  func createImageView(imageName: String) -> UIImageView
  {
    // In Interface Builder, the default bundle is not Dolphin's, so we must specify
    // the bundle for the image to load correctly
    let image = UIImage(named: imageName, in: Bundle(for: type(of: self)), compatibleWith: nil)
    return UIImageView(image: image)
  }

  override func layoutSubviews()
  {
    super.layoutSubviews()
    layoutImages()
  }

  private func layoutImages()
  {
    let shortestSide = min(bounds.width, bounds.height)
    let dimension = shortestSide > 0 ? shortestSide - (shortestSide / 3) : 1
    let center = CGPoint(x: bounds.midX, y: bounds.midY)

    rangeView?.bounds = CGRect(x: 0, y: 0, width: dimension, height: dimension)
    rangeView?.center = center
    handleView?.bounds = CGRect(x: 0, y: 0, width: dimension, height: dimension)

    let state = panRecognizer?.state ?? UIGestureRecognizer.State.possible
    if state != .changed && state != .began
    {
      handleView?.center = center
    }
  }

  private var travelLimit: CGFloat
  {
    let shortestSide = min(bounds.width, bounds.height)
    return max(shortestSide / 3, 1)
  }

  @objc func handlePan(gesture: UIPanGestureRecognizer)
  {
    if (TCView.isEditMode)
    {
      return
    }

    switch gesture.state
    {
    case .began, .changed:
      updateAxesForPoint(gesture.location(in: self))
    case .ended, .cancelled, .failed:
      DOLDebugLog.logTag("TOUCH", message: "joystick \(joystickType) released")
      resetAxes()
    default:
      break
    }
  }

  private func updateAxesForPoint(_ point: CGPoint)
  {
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let limit = travelLimit

    var xDiff = point.x - center.x
    var yDiff = point.y - center.y

    let distance = sqrt(pow(xDiff, 2) + pow(yDiff, 2))
    if distance > limit && distance > 0
    {
      xDiff = xDiff / distance * limit
      yDiff = yDiff / distance * limit
    }

    handleView?.center = CGPoint(x: center.x + xDiff, y: center.y + yDiff)

    let x = Float(max(min(xDiff / limit, 1), -1))
    let y = Float(max(min(yDiff / limit, 1), -1))

    // Up/left are sent as negative values; the input layer negates them. Using max()
    // for the positive halves keeps the opposite direction at zero instead of sending
    // a negative value for both, which used to make the stick lose half its range.
    let axes = [min(y, 0), max(y, 0), min(x, 0), max(x, 0)]
    sendAxes(axes)

    let description = String(format: "x=%.2f y=%.2f", x, y)
    if description != lastLoggedAxes
    {
      lastLoggedAxes = description
      DOLDebugLog.logTag("TOUCH", message: "joystick \(joystickType) port \(port) \(description)")
    }
  }

  private func sendAxes(_ axes: [Float])
  {
    let axisStartIdx = joystickType
    for (i, axis) in axes.enumerated()
    {
      TCManagerInterface.setAxisValueFor(axisStartIdx + i + 1, controller: port, value: axis)
    }
  }

  // Called when the touch ends, when edit mode starts and when the app leaves the
  // foreground: an analog stick that keeps its last value would keep the character
  // walking forever.
  @objc func resetAxes()
  {
    sendAxes([0, 0, 0, 0])
    handleView?.center = CGPoint(x: bounds.midX, y: bounds.midY)
    lastLoggedAxes = ""
  }

  @objc func setInputEnabled(_ enabled: Bool)
  {
    panRecognizer?.isEnabled = enabled
    if !enabled
    {
      resetAxes()
    }
  }
}
