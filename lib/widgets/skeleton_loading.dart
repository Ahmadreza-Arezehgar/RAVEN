import 'package:flutter/material.dart';
import '../theme/ios_design_system.dart';

/// Skeleton Loading for Post Cards
/// Shows shimmer animation while loading content
class SkeletonPostCard extends StatefulWidget {
  const SkeletonPostCard({super.key});

  @override
  State<SkeletonPostCard> createState() => _SkeletonPostCardState();
}

class _SkeletonPostCardState extends State<SkeletonPostCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;
  late Animation<double> _shimmerAnimation;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
    
    _shimmerAnimation = Tween<double>(
      begin: -2,
      end: 2,
    ).animate(CurvedAnimation(
      parent: _shimmerController,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: iOSDesignSystem.spacing16,
        vertical: iOSDesignSystem.spacing8,
      ),
      decoration: BoxDecoration(
        color: iOSDesignSystem.surfaceCard,
        borderRadius: BorderRadius.circular(iOSDesignSystem.radiusCard),
      ),
      padding: const EdgeInsets.all(iOSDesignSystem.spacing16),
      child: AnimatedBuilder(
        animation: _shimmerAnimation,
        builder: (context, child) {
          return ShaderMask(
            shaderCallback: (bounds) {
              return LinearGradient(
                colors: [
                  Colors.white.withOpacity(0.05),
                  Colors.white.withOpacity(0.15),
                  Colors.white.withOpacity(0.05),
                ],
                stops: const [0.0, 0.5, 1.0],
                begin: Alignment(_shimmerAnimation.value, 0),
                end: Alignment(_shimmerAnimation.value + 1, 0),
              ).createShader(bounds);
            },
            child: child!,
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header (avatar + name + time)
            Row(
              children: [
                _SkeletonBox(
                  width: 40,
                  height: 40,
                  borderRadius: 20,
                ),
                const SizedBox(width: iOSDesignSystem.spacing12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _SkeletonBox(
                        width: 120,
                        height: 16,
                        borderRadius: 4,
                      ),
                      const SizedBox(height: 6),
                      _SkeletonBox(
                        width: 80,
                        height: 12,
                        borderRadius: 4,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: iOSDesignSystem.spacing16),
            
            // Content lines
            _SkeletonBox(
              width: double.infinity,
              height: 16,
              borderRadius: 4,
            ),
            const SizedBox(height: 8),
            _SkeletonBox(
              width: double.infinity,
              height: 16,
              borderRadius: 4,
            ),
            const SizedBox(height: 8),
            _SkeletonBox(
              width: 200,
              height: 16,
              borderRadius: 4,
            ),
            
            const SizedBox(height: iOSDesignSystem.spacing16),
            
            // Actions
            Row(
              children: [
                _SkeletonBox(width: 60, height: 32, borderRadius: 16),
                const SizedBox(width: 16),
                _SkeletonBox(width: 60, height: 32, borderRadius: 16),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Skeleton Box - Basic building block
class _SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double borderRadius;

  const _SkeletonBox({
    this.width,
    required this.height,
    required this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

/// Skeleton List - Shows multiple skeleton cards
class SkeletonPostList extends StatelessWidget {
  final int count;

  const SkeletonPostList({
    super.key,
    this.count = 3,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: count,
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemBuilder: (context, index) => const SkeletonPostCard(),
    );
  }
}
