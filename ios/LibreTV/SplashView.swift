import UIKit

/// 启动页：图标 + 进度 + 出错提示
final class SplashView: UIView {
    var onRetry: (() -> Void)?

    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private let retryButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0x0b / 255, green: 0x10 / 255, blue: 0x1a / 255, alpha: 1)

        icon.image = UIImage(named: "SplashIcon")
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 22
        icon.clipsToBounds = true

        spinner.color = .lightGray
        spinner.startAnimating()

        label.textColor = UIColor(white: 0.75, alpha: 1)
        label.font = .systemFont(ofSize: 14)
        label.numberOfLines = 0
        label.textAlignment = .center

        retryButton.setTitle("重试", for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, spinner, label, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setStatus(_ text: String) {
        label.text = text
    }

    func showError(_ text: String, retry: Bool = true) {
        spinner.stopAnimating()
        label.text = text
        retryButton.isHidden = !retry
    }

    func resetToLoading() {
        retryButton.isHidden = true
        spinner.startAnimating()
        label.text = "正在连接本地服务…"
    }

    @objc private func retryTapped() { onRetry?() }
}
