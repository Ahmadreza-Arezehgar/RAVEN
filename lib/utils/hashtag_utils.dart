import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Regex for hashtag extraction (English + Persian + Arabic + numbers)
final _hashtagRegex = RegExp(
  r'(?<!\w)#([A-Za-z0-9_\u0600-\u06FF\u0750-\u077F]+)',
  unicode: true,
);

/// Regex for mention extraction
final _mentionRegex = RegExp(
  r'(?<!\w)@([A-Za-z0-9_]+)',
  unicode: true,
);

/// Extract all hashtags from text (lowercase, unique)
List<String> extractHashtags(String text) {
  final matches = _hashtagRegex.allMatches(text);
  final tags = <String>{};
  for (final m in matches) {
    final raw = m.group(1);
    if (raw != null && raw.isNotEmpty) {
      tags.add(raw.toLowerCase());
    }
  }
  return tags.toList();
}

/// Extract all mentions from text (lowercase, unique)
List<String> extractMentions(String text) {
  final matches = _mentionRegex.allMatches(text);
  final mentions = <String>{};
  for (final m in matches) {
    final raw = m.group(1);
    if (raw != null && raw.isNotEmpty) {
      mentions.add(raw.toLowerCase());
    }
  }
  return mentions.toList();
}

/// Build RichText with clickable hashtags and mentions
/// 
/// Example:
/// ```dart
/// buildHashtagRichText(
///   'Hello #world @user',
///   onHashtagTap: (tag) => print('Tapped #$tag'),
///   onMentionTap: (user) => print('Tapped @$user'),
/// )
/// ```
Widget buildHashtagRichText({
  required String text,
  required TextStyle baseStyle,
  Color hashtagColor = const Color(0xFF0A84FF),
  Color mentionColor = const Color(0xFF34C759),
  void Function(String tag)? onHashtagTap,
  void Function(String username)? onMentionTap,
  int? maxLines,
  TextOverflow overflow = TextOverflow.clip,
}) {
  final spans = <InlineSpan>[];
  int currentIndex = 0;

  // Combined regex for both hashtags and mentions
  final combinedRegex = RegExp(
    r'(?<!\w)(#[A-Za-z0-9_\u0600-\u06FF\u0750-\u077F]+|@[A-Za-z0-9_]+)',
    unicode: true,
  );

  for (final match in combinedRegex.allMatches(text)) {
    // Add text before the match
    if (match.start > currentIndex) {
      spans.add(TextSpan(
        text: text.substring(currentIndex, match.start),
        style: baseStyle,
      ));
    }

    final matchedText = match.group(0)!;
    final isHashtag = matchedText.startsWith('#');
    final value = matchedText.substring(1); // Remove # or @

    spans.add(TextSpan(
      text: matchedText,
      style: baseStyle.copyWith(
        color: isHashtag ? hashtagColor : mentionColor,
        fontWeight: FontWeight.w600,
        decoration: TextDecoration.none,
      ),
      recognizer: TapGestureRecognizer()
        ..onTap = () {
          if (isHashtag) {
            onHashtagTap?.call(value);
          } else {
            onMentionTap?.call(value);
          }
        },
    ));

    currentIndex = match.end;
  }

  // Add remaining text
  if (currentIndex < text.length) {
    spans.add(TextSpan(
      text: text.substring(currentIndex),
      style: baseStyle,
    ));
  }

  return RichText(
    text: TextSpan(children: spans),
    maxLines: maxLines,
    overflow: overflow,
  );
}

/// Simple hashtag chip widget
class HashtagChip extends StatelessWidget {
  final String tag;
  final VoidCallback? onTap;
  final bool selected;

  const HashtagChip({
    super.key,
    required this.tag,
    this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected 
              ? const Color(0xFF0A84FF)
              : const Color(0xFF0A84FF).withOpacity(0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFF0A84FF).withOpacity(0.3),
            width: 0.5,
          ),
        ),
        child: Text(
          '#$tag',
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xFF0A84FF),
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
