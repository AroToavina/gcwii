// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

@objc public class TCEditLayoutViewController: UIViewController {
  private let segmentedControl = UISegmentedControl(items: ["GameCube", "Wii", "Classic", "Sideways"])
  private var currentPadView: TCView?
  private let containerView = UIView()
  private let hintLabel = UILabel()
  private var lastPadSize = CGSize.zero

  @objc public static func present(from presenter: UIViewController) {
    let vc = TCEditLayoutViewController()
    let nav = UINavigationController(rootViewController: vc)
    nav.modalPresentationStyle = .fullScreen
    presenter.present(nav, animated: true, completion: nil)
  }

  public override func viewDidLoad() {
    super.viewDidLoad()
    title = "Edit Touch Layout"
    view.backgroundColor = .systemBackground

    navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Reset", style: .plain, target: self, action: #selector(resetTapped))

    segmentedControl.selectedSegmentIndex = 0
    segmentedControl.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
    navigationItem.titleView = segmentedControl

    hintLabel.translatesAutoresizingMaskIntoConstraints = false
    hintLabel.text = "Drag controls to reposition. Each controller's layout is saved automatically."
    hintLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    hintLabel.textColor = .secondaryLabel
    hintLabel.textAlignment = .center
    view.addSubview(hintLabel)

    containerView.translatesAutoresizingMaskIntoConstraints = false
    containerView.backgroundColor = UIColor.black.withAlphaComponent(0.05)
    view.addSubview(containerView)

    NSLayoutConstraint.activate([
      hintLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

      containerView.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 8),
      containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      containerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
    ])
  }

  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    // The pads must be created after the container has a real size, otherwise the
    // nib's controls end up laid out in a zero-sized view.
    let size = containerView.bounds.size
    guard size.width > 0, size.height > 0, size != lastPadSize else { return }

    lastPadSize = size
    loadCurrentPad()
  }

  public override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    currentPadView?.setEditModeEnabled(false)
  }

  @objc private func segmentChanged() {
    loadCurrentPad()
  }

  private func loadCurrentPad() {
    currentPadView?.setEditModeEnabled(false)
    currentPadView?.removeFromSuperview()
    currentPadView = nil

    containerView.layoutIfNeeded()
    let frame = containerView.bounds

    let pad: TCView
    switch segmentedControl.selectedSegmentIndex {
    case 0:
      pad = TCGameCubePad(frame: frame)
    case 1:
      pad = TCWiiPad(frame: frame)
    case 2:
      pad = TCClassicWiiPad(frame: frame)
    case 3:
      pad = TCSidewaysWiiPad(frame: frame)
    default:
      pad = TCGameCubePad(frame: frame)
    }

    pad.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    containerView.addSubview(pad)
    pad.setEditModeEnabled(true)
    currentPadView = pad
  }

  @objc private func resetTapped() {
    let alert = UIAlertController(title: "Reset Layout", message: "Reset this controller layout to default positions?", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
    alert.addAction(UIAlertAction(title: "Reset", style: .destructive, handler: { [weak self] _ in
      self?.currentPadView?.resetLayoutToDefaults()
    }))
    present(alert, animated: true, completion: nil)
  }

  @objc private func doneTapped() {
    currentPadView?.setEditModeEnabled(false)
    dismiss(animated: true, completion: nil)
  }
}
