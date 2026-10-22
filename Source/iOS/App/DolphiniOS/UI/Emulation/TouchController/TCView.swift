// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

@objc class TCView: UIView
{
  @objc var real_view: UIView?
  
  @objc static var isEditMode: Bool = false
  
  private var panRecognizers: [UIView: UIPanGestureRecognizer] = [:]
  private var panStartOffsets: [UIView: CGPoint] = [:]
  
  private var _port: Int = 0
  @objc var port: Int
  {
    get
    {
      return _port
    }
    set
    {
      _port = newValue
      if let real = real_view
      {
        SetPort(newValue, view: real)
      }
    }
  }
  
  override init(frame: CGRect)
  {
    super.init(frame: frame)
    loadNib()
  }
  
  required init?(coder: NSCoder)
  {
    super.init(coder: coder)
    loadNib()
  }
  
  private func loadNib()
  {
    // Load ourselves from the nib
    let name = String(describing: type(of: self))
    guard let nibViews = Bundle(for: type(of: self)).loadNibNamed(name, owner: self, options: nil),
          let view = nibViews.first as? UIView else
    {
      return
    }
    view.frame = self.bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    self.addSubview(view)
    
    real_view = view
    applySavedLayout()
  }
  
  override func layoutSubviews()
  {
    super.layoutSubviews()
    if let real = real_view
    {
      real.frame = self.bounds
    }
    applySavedLayout()
  }
  
  func SetPort(_ port: Int, view: UIView)
  {
    for subview in view.subviews
    {
      switch subview
      {
      case let button as TCButton:
        button.port = port
      case let joystick as TCJoystick:
        joystick.port = port
      case let dpad as TCDirectionalPad:
        dpad.port = port
      default:
        SetPort(port, view: subview)
      }
    }
  }
  
  // MARK: - Movable controls & layout customization
  
  func findMovableControls(in view: UIView) -> [UIView]
  {
    var result: [UIView] = []
    for subview in view.subviews
    {
      if subview is TCButton || subview is TCJoystick || subview is TCDirectionalPad
      {
        result.append(subview)
      }
      else
      {
        result.append(contentsOf: findMovableControls(in: subview))
      }
    }
    return result
  }
  
  // The joystick handle and D-pad image install their own gesture recognizers.
  // While editing they would win over the drag recognizer on the control, so
  // disable them for the duration of layout editing.
  private func setSubcontrolGesturesEnabled(_ enabled: Bool, in view: UIView)
  {
    for subview in view.subviews
    {
      for recognizer in subview.gestureRecognizers ?? []
      {
        recognizer.isEnabled = enabled
      }
      setSubcontrolGesturesEnabled(enabled, in: subview)
    }
  }
  
  func getControlIdentifier(for control: UIView) -> String?
  {
    if let btn = control as? TCButton
    {
      return "btn_\(btn.controllerButton)"
    }
    else if let joy = control as? TCJoystick
    {
      return "joy_\(joy.joystickType)"
    }
    else if let dpad = control as? TCDirectionalPad
    {
      return "dpad_\(dpad.directionalPadType)"
    }
    return nil
  }
  
  func saveOffset(for control: UIView, offset: CGPoint)
  {
    guard let id = getControlIdentifier(for: control) else { return }
    let padName = String(describing: type(of: self))
    let key = "TCPos_\(padName)_\(id)"
    UserDefaults.standard.set([Double(offset.x), Double(offset.y)], forKey: key)
  }
  
  func loadOffset(for control: UIView) -> CGPoint?
  {
    guard let id = getControlIdentifier(for: control) else { return nil }
    let padName = String(describing: type(of: self))
    let key = "TCPos_\(padName)_\(id)"
    if let arr = UserDefaults.standard.array(forKey: key) as? [Double], arr.count == 2
    {
      return CGPoint(x: arr[0], y: arr[1])
    }
    return nil
  }
  
  @objc func applySavedLayout()
  {
    guard let real = real_view else { return }
    let controls = findMovableControls(in: real)
    for control in controls
    {
      if let offset = loadOffset(for: control)
      {
        control.transform = CGAffineTransform(translationX: offset.x, y: offset.y)
      }
      else
      {
        control.transform = .identity
      }
    }
  }
  
  @objc func setEditModeEnabled(_ enabled: Bool)
  {
    // Controls check this flag to avoid sending input while their positions are
    // being edited. It also drives the "Done Editing Layout" menu title.
    TCView.isEditMode = enabled

    guard let real = real_view else { return }
    let controls = findMovableControls(in: real)
    for control in controls
    {
      if enabled
      {
        // UIColor.systemCyan requires iOS 15, but the app targets iOS 14.
        control.layer.borderColor = UIColor.cyan.cgColor
        control.layer.borderWidth = 2.0
        control.layer.cornerRadius = 8.0
        control.isUserInteractionEnabled = true
        
        if let joystick = control as? TCJoystick
        {
          // The stick's pan recognizer now sits on the control itself, so it has to be
          // switched off explicitly while the layout editor is dragging the control.
          joystick.setInputEnabled(false)
        }
        else if control is TCDirectionalPad
        {
          setSubcontrolGesturesEnabled(false, in: control)
        }
        
        if panRecognizers[control] == nil
        {
          let pan = UIPanGestureRecognizer(target: self, action: #selector(handleControlDrag(_:)))
          pan.cancelsTouchesInView = true
          control.addGestureRecognizer(pan)
          panRecognizers[control] = pan
        }
      }
      else
      {
        control.layer.borderWidth = 0.0
        if let joystick = control as? TCJoystick
        {
          joystick.setInputEnabled(true)
        }
        else if control is TCDirectionalPad
        {
          setSubcontrolGesturesEnabled(true, in: control)
        }
        if let pan = panRecognizers[control]
        {
          control.removeGestureRecognizer(pan)
          panRecognizers.removeValue(forKey: control)
        }
      }
    }
  }
  
  @objc func handleControlDrag(_ gesture: UIPanGestureRecognizer)
  {
    guard let control = gesture.view else { return }
    let translation = gesture.translation(in: self)
    
    if gesture.state == .began
    {
      let currentOffset = loadOffset(for: control) ?? .zero
      panStartOffsets[control] = currentOffset
    }
    
    let startOffset = panStartOffsets[control] ?? .zero
    let newX = startOffset.x + translation.x
    let newY = startOffset.y + translation.y
    control.transform = CGAffineTransform(translationX: newX, y: newY)
    
    if gesture.state == .ended || gesture.state == .cancelled
    {
      saveOffset(for: control, offset: CGPoint(x: newX, y: newY))
      panStartOffsets[control] = CGPoint(x: newX, y: newY)
    }
  }
  
  // Releases every touch control: used when the pads are hidden or the app is
  // backgrounded, so no stick keeps a value or a button stays pressed.
  @objc func releaseAllInputs()
  {
    guard let real = real_view else { return }
    for control in findMovableControls(in: real)
    {
      if let joystick = control as? TCJoystick
      {
        joystick.resetAxes()
      }
      else if let dpad = control as? TCDirectionalPad
      {
        dpad.releaseAllButtons()
      }
    }
    releaseButtons(in: real)
  }
  
  private func releaseButtons(in view: UIView)
  {
    for subview in view.subviews
    {
      if let button = subview as? TCButton
      {
        button.buttonReleased()
      }
      releaseButtons(in: subview)
    }
  }
  
  @objc func resetLayoutToDefaults()
  {
    let padName = String(describing: type(of: self))
    TCView.resetLayout(for: padName)
    guard let real = real_view else { return }
    let controls = findMovableControls(in: real)
    for control in controls
    {
      control.transform = .identity
      panStartOffsets.removeValue(forKey: control)
    }
  }
  
  @objc static func resetLayout(for padClassName: String)
  {
    let defaults = UserDefaults.standard
    let prefix = "TCPos_\(padClassName)_"
    for key in defaults.dictionaryRepresentation().keys
    {
      if key.hasPrefix(prefix)
      {
        defaults.removeObject(forKey: key)
      }
    }
  }
  
  @objc static func resetAllLayouts()
  {
    let defaults = UserDefaults.standard
    for key in defaults.dictionaryRepresentation().keys
    {
      if key.hasPrefix("TCPos_")
      {
        defaults.removeObject(forKey: key)
      }
    }
  }
}
