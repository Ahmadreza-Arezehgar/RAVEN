# Empty State Animations Guide

This directory should contain Lottie animation files (`.json`) for empty state illustrations.

## Required Animation Files

### 1. `empty_feed_skeleton.json`
**Used in:** Home feed (Local/Friends tabs) when no posts are available

**Animation Description:**
- A skeleton character sitting on a park bench in a park setting
- A newspaper is placed on top of its head
- Wind is blowing continuously (loop animation)
- The newspaper flutters and moves with the wind
- Background elements like trees/leaves may sway gently

**Animation Requirements:**
- Duration: 2-4 seconds (will loop forever)
- Frame rate: 30fps recommended
- Canvas size: 400x300 or similar aspect ratio
- Export as Lottie JSON using After Effects + Bodymovin or Rive

---

### 2. `empty_messages_skeleton_pipe.json`
**Used in:** Messages/Inbox when no conversations exist

**Animation Description:**
- A skeleton character sitting behind a desk in a **relaxed "chill" pose**
- One leg is casually propped up on the desk
- The skeleton is holding a pipe in one hand
- **Primary animation**: Smoke rises from the pipe in soft, looping wisps
- The smoke uses low opacity and smooth movement (no sudden jumps)
- Body/character should be mostly **static** or with minimal subtle movement
- Overall vibe: calm, quiet, unique (matches RAVEN aesthetic)

**Animation Requirements:**
- **Duration**: 4-6 seconds (loop forever)
- **Frame rate**: 30fps
- **Canvas size**: 400x350 or similar aspect ratio
- **Transparent background**
- **Smoke animation**: Soft opacity transitions, gentle upward drift
- Export as Lottie JSON using After Effects + Bodymovin

**Color Palette:**
| Element | Color |
|---------|-------|
| Skeleton | `#A3A3A3` (neutral gray, works in dark/light mode) |
| Desk | `#73523A` → `#59381F` (wood gradient) |
| Pipe bowl | `#804020` → `#4D2610` (dark wood) |
| Smoke | `#808080` at 30-50% opacity |

---

## How to Add Animations

### Option 1: Lottie (Recommended)

1. **Create animations** using:
   - Adobe After Effects + Bodymovin plugin
   - Rive (export to Lottie format)
   - LottieFiles.com (browse/customize existing animations)

2. **Export as JSON** with the exact filenames above

3. **Add to Xcode project:**
   - Drag `.json` files into this folder
   - Ensure "Copy items if needed" is checked
   - Add to the RAVEN target

4. **Install Lottie SDK:**
   ```
   // In Package.swift or Xcode > Add Package
   https://github.com/airbnb/lottie-ios
   ```

### Option 2: Use SwiftUI Fallback

If Lottie files are not available, the app will automatically use SwiftUI-based animated illustrations. These provide:
- Animated smoke particles (opacity + position)
- Skeleton figure at desk with pipe
- Dark mode support
- Respects "Reduce Motion" accessibility setting

---

## Animation Best Practices

1. **Keep file sizes small** (<100KB per animation)
2. **Use simple shapes** - avoid complex gradients
3. **Test on actual devices** for performance
4. **Respect Reduce Motion** - animations pause when accessibility setting is on
5. **Loop seamlessly** - ensure first and last frames match
6. **Dark mode support** - use neutral colors that work in both modes

---

## Testing

To test the animations in isolation:

```swift
#Preview {
    AnimatedEmptyFeedView(feedType: .local)
}

#Preview {
    AnimatedEmptyMessagesView(onNewChat: {})
}
```

Open Xcode previews to see the SwiftUI fallback animations in action.
