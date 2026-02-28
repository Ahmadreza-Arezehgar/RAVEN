/// News Article Model
class NewsArticle {
  final String title;
  final String description;
  final String source;
  final String sourceId;
  final String url;
  final String? imageUrl;
  final DateTime publishedAt;
  final String? author;

  NewsArticle({
    required this.title,
    required this.description,
    required this.source,
    required this.sourceId,
    required this.url,
    this.imageUrl,
    required this.publishedAt,
    this.author,
  });

  factory NewsArticle.fromJson(Map<String, dynamic> json) {
    return NewsArticle(
      title: json['title'] ?? 'No title',
      description: json['description'] ?? '',
      source: json['source']?['name'] ?? 'Unknown',
      sourceId: json['source']?['id'] ?? '',
      url: json['url'] ?? '',
      imageUrl: json['urlToImage'],
      publishedAt: json['publishedAt'] != null
          ? DateTime.parse(json['publishedAt'])
          : DateTime.now(),
      author: json['author'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'description': description,
      'source': {'name': source, 'id': sourceId},
      'url': url,
      'urlToImage': imageUrl,
      'publishedAt': publishedAt.toIso8601String(),
      'author': author,
    };
  }
}
