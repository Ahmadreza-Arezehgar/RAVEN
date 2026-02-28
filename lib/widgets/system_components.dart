import 'package:flutter/material.dart';
import '../theme/mobile_theme.dart';
import '../services/toast_service.dart';

/// System component widgets for mobile app

/// Skeleton loading widget - better than spinners for content
class SkeletonLoader extends StatefulWidget {
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  
  const SkeletonLoader({
    super.key,
    this.width,
    this.height = 16,
    this.borderRadius,
  });
  
  const SkeletonLoader.card({
    super.key,
    this.width = double.infinity,
    this.height = 120,
  }) : borderRadius = null;
  
  const SkeletonLoader.circle({
    super.key,
    required double size,
  }) : width = size,
       height = size,
       borderRadius = null;

  @override
  State<SkeletonLoader> createState() => _SkeletonLoaderState();
}

class _SkeletonLoaderState extends State<SkeletonLoader> 
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
    
    _animation = Tween<double>(begin: -1, end: 2).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark ? MobileTheme.darkSurface : MobileTheme.lightDivider;
    final highlightColor = isDark 
        ? MobileTheme.darkDivider 
        : Colors.white;
    
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius ?? 
                (widget.width == widget.height 
                    ? BorderRadius.circular(MobileTheme.radiusFull)
                    : BorderRadius.circular(MobileTheme.radiusSmall)),
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              stops: [
                _animation.value - 1,
                _animation.value,
                _animation.value + 1,
              ],
              colors: [
                baseColor,
                highlightColor,
                baseColor,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Empty state component
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;
  
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MobileTheme.spacing32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 64,
              color: MobileTheme.textTertiary(isDark),
            ),
            const SizedBox(height: MobileTheme.spacing16),
            Text(
              title,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                color: MobileTheme.textSecondary(isDark),
              ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: MobileTheme.spacing8),
              Text(
                subtitle!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: MobileTheme.textTertiary(isDark),
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: MobileTheme.spacing24),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Error state component
class ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  
  const ErrorState({
    super.key,
    required this.message,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MobileTheme.spacing32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: MobileTheme.error,
            ),
            const SizedBox(height: MobileTheme.spacing16),
            Text(
              'Something went wrong',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                color: MobileTheme.error,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: MobileTheme.spacing8),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: MobileTheme.textSecondary(
                  Theme.of(context).brightness == Brightness.dark,
                ),
              ),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: MobileTheme.spacing24),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Toast notification - delegates to ToastService
class ToastNotification {
  static void show(
    BuildContext context, {
    required String message,
    ToastType type = ToastType.info,
    Duration duration = const Duration(seconds: 3),
  }) {
    // Delegate to ToastService for unified Liquid Glass toasts
    switch (type) {
      case ToastType.success:
        ToastService.showSuccess(message);
        break;
      case ToastType.error:
        ToastService.showError(message);
        break;
      case ToastType.warning:
        ToastService.showWarning(message);
        break;
      case ToastType.info:
        ToastService.showInfo(message);
        break;
    }
  }
}

enum ToastType { success, error, warning, info }

/// Post/Comment list skeleton
class FeedSkeleton extends StatelessWidget {
  final int itemCount;
  
  const FeedSkeleton({super.key, this.itemCount = 3});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: MobileTheme.cardMargin,
      itemCount: itemCount,
      itemBuilder: (context, index) {
        return Card(
          margin: MobileTheme.cardMargin,
          child: Padding(
            padding: MobileTheme.cardPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Author header
                Row(
                  children: [
                    const SkeletonLoader.circle(size: 40),
                    const SizedBox(width: MobileTheme.spacing12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        SkeletonLoader(width: 120, height: 14),
                        SizedBox(height: MobileTheme.spacing4),
                        SkeletonLoader(width: 60, height: 12),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: MobileTheme.spacing12),
                // Content
                const SkeletonLoader(width: double.infinity, height: 16),
                const SizedBox(height: MobileTheme.spacing8),
                const SkeletonLoader(width: 200, height: 16),
                const SizedBox(height: MobileTheme.spacing12),
                // Actions
                Row(
                  children: const [
                    SkeletonLoader(width: 60, height: 14),
                    SizedBox(width: MobileTheme.spacing16),
                    SkeletonLoader(width: 60, height: 14),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
