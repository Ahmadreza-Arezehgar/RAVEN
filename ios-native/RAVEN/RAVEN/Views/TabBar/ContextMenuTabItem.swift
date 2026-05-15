import SwiftUI
import UIKit

// MARK: - Context Menu Tab Item (UIKit Bridge for Native iOS Haptic Touch)
/// Uses UIContextMenuInteraction for authentic iOS behavior:
/// - Drag-while-holding selection
/// - Menu appears from icon position (upward)
/// - Icon stays fixed (no scale)
/// - Native haptic feedback
struct ContextMenuTabItem: UIViewRepresentable {
    let tab: AppTab
    let isSelected: Bool
    let badgeCount: Int
    let actions: [TabAction]
    let onTap: () -> Void
    
    func makeUIView(context: Context) -> ContextMenuTabUIView {
        let view = ContextMenuTabUIView()
        view.configure(
            tab: tab,
            isSelected: isSelected,
            badgeCount: badgeCount,
            actions: actions,
            onTap: onTap
        )
        return view
    }
    
    func updateUIView(_ uiView: ContextMenuTabUIView, context: Context) {
        uiView.configure(
            tab: tab,
            isSelected: isSelected,
            badgeCount: badgeCount,
            actions: actions,
            onTap: onTap
        )
    }
}

// MARK: - UIKit View with Context Menu
final class ContextMenuTabUIView: UIView {
    private var tab: AppTab = .messages
    private var isSelected: Bool = false
    private var badgeCount: Int = 0
    private var actions: [TabAction] = []
    private var onTap: (() -> Void)?
    
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let badgeLabel = UILabel()
    private let stackView = UIStackView()
    
    // IMPORTANT: Store badge width constraint reference to avoid accumulation
    private var badgeWidthConstraint: NSLayoutConstraint?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        setupGestures()
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }
    
    private func setupUI() {
        // Icon
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        
        // Title
        titleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        
        // Badge
        badgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = .systemRed
        badgeLabel.textAlignment = .center
        badgeLabel.layer.cornerRadius = 8
        badgeLabel.clipsToBounds = true
        badgeLabel.isHidden = true
        
        // Stack
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 4
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(titleLabel)
        
        addSubview(stackView)
        addSubview(badgeLabel)
        
        stackView.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        
        // Create and store badge width constraint
        badgeWidthConstraint = badgeLabel.widthAnchor.constraint(equalToConstant: 16)
        
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            
            badgeLabel.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -6),
            badgeLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: -8),
            badgeLabel.heightAnchor.constraint(equalToConstant: 16),
            badgeWidthConstraint!
        ])
        
        // Context Menu Interaction
        let interaction = UIContextMenuInteraction(delegate: self)
        addInteraction(interaction)
    }
    
    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }
    
    @objc private func handleTap() {
        // Dismiss keyboard to prevent navigation bar crashes during tab transitions
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        // Haptic
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
        
        // Delay navigation to allow keyboard dismissal animation to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.onTap?()
        }
    }
    
    func configure(tab: AppTab, isSelected: Bool, badgeCount: Int, actions: [TabAction], onTap: @escaping () -> Void) {
        self.tab = tab
        self.isSelected = isSelected
        self.badgeCount = badgeCount
        self.actions = actions
        self.onTap = onTap
        
        // Update icon
        let iconName = isSelected ? tab.selectedIcon : tab.icon
        let config = UIImage.SymbolConfiguration(weight: isSelected ? .semibold : .regular)
        iconView.image = UIImage(systemName: iconName, withConfiguration: config)
        iconView.tintColor = isSelected ? .label : .secondaryLabel
        
        // Update title
        titleLabel.text = tab.title
        titleLabel.font = .systemFont(ofSize: 10, weight: isSelected ? .semibold : .regular)
        titleLabel.textColor = isSelected ? .label : .secondaryLabel
        
        // Update badge - FIX: Update existing constraint instead of creating new one
        if badgeCount > 0 {
            badgeLabel.isHidden = false
            badgeLabel.text = badgeCount > 99 ? "99+" : "\(badgeCount)"
            let width = max(16, badgeLabel.intrinsicContentSize.width + 8)
            badgeWidthConstraint?.constant = width // Update existing constraint!
        } else {
            badgeLabel.isHidden = true
        }
    }
}

// MARK: - UIContextMenuInteractionDelegate
extension ContextMenuTabUIView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        
        return UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: nil
        ) { [weak self] _ in
            guard let self = self else { return nil }
            
            let menuActions = self.actions.map { action in
                UIAction(
                    title: action.title,
                    image: UIImage(systemName: action.systemImage)
                ) { _ in
                    // Light haptic on selection
                    let lightGenerator = UIImpactFeedbackGenerator(style: .light)
                    lightGenerator.impactOccurred()
                    
                    // Dispatch to next runloop to allow context menu to dismiss properly
                    DispatchQueue.main.async {
                        action.handler()
                    }
                }
            }
            
            return UIMenu(title: "", options: [.displayInline], children: menuActions)
        }
    }
    
    // Optional: Custom preview (capsule with icon)
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        // Return nil for no preview (just menu), or create custom preview
        // For now, no preview - just the menu appears
        return nil
    }
}
