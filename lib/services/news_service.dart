import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/news_article.dart';

/// News Service - Fetch news from NewsAPI.org
class NewsService {
  // TODO: Replace with actual API key from https://newsapi.org/
  static const String _apiKey = 'YOUR_API_KEY_HERE';
  static const String _baseUrl = 'https://newsapi.org/v2';
  static const Duration _cacheDuration = Duration(hours: 1);

  /// Fetch top headlines based on country and interests
  static Future<List<NewsArticle>> fetchNews({
    String country = 'us',
    List<String> interests = const [],
    int pageSize = 20,
    bool forceRefresh = false,
  }) async {
    try {
      // Check cache first
      if (!forceRefresh) {
        final cached = await _getCachedNews(country, interests);
        if (cached != null) {
          print('✅ Returning cached news (${cached.length} articles)');
          return cached;
        }
      }

      // Build sources list (BBC, Bloomberg, CNN, Fox News)
      final sources = <String>[];
      
      // Add major news sources
      sources.addAll([
        'bbc-news',
        'bloomberg',
        'cnn',
        'fox-news',
      ]);

      // Build URL
      String url;
      if (interests.isNotEmpty && interests.first != 'general') {
        // Category-based search
        url = '$_baseUrl/top-headlines?'
            'country=$country&'
            'category=${interests.first.toLowerCase()}&'
            'pageSize=$pageSize&'
            'apiKey=$_apiKey';
      } else {
        // Source-based search
        url = '$_baseUrl/top-headlines?'
            'sources=${sources.join(',')}&'
            'pageSize=$pageSize&'
            'apiKey=$_apiKey';
      }

      print('📰 Fetching news: $url');

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final articles = (data['articles'] as List)
            .map((article) => NewsArticle.fromJson(article))
            .toList();

        print('✅ Fetched ${articles.length} news articles');
        
        // Cache the results
        await _cacheNews(country, interests, articles);
        
        return articles;
      } else if (response.statusCode == 401) {
        print('❌ Invalid API key - using mock data');
        return _getMockNews();
      } else {
        print('❌ Error fetching news: ${response.statusCode}');
        return _getMockNews();
      }
    } catch (e) {
      print('❌ Exception fetching news: $e');
      return _getMockNews();
    }
  }

  /// Get cached news if available and not expired
  static Future<List<NewsArticle>?> _getCachedNews(
    String country,
    List<String> interests,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = _getCacheKey(country, interests);
      
      // Check if cache exists
      final cachedJson = prefs.getString('news_cache_$cacheKey');
      final cachedTime = prefs.getInt('news_cache_time_$cacheKey');
      
      if (cachedJson == null || cachedTime == null) {
        return null;
      }

      // Check if cache expired
      final cacheAge = DateTime.now().millisecondsSinceEpoch - cachedTime;
      if (cacheAge > _cacheDuration.inMilliseconds) {
        print('⏰ Cache expired');
        return null;
      }

      // Parse cached data
      final List<dynamic> jsonList = json.decode(cachedJson);
      final articles = jsonList
          .map((json) => NewsArticle.fromJson(json))
          .toList();
      
      return articles;
    } catch (e) {
      print('Error reading cache: $e');
      return null;
    }
  }

  /// Cache news data
  static Future<void> _cacheNews(
    String country,
    List<String> interests,
    List<NewsArticle> articles,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheKey = _getCacheKey(country, interests);
      
      // Convert articles to JSON
      final jsonList = articles.map((a) => a.toJson()).toList();
      final jsonString = json.encode(jsonList);
      
      // Save to cache
      await prefs.setString('news_cache_$cacheKey', jsonString);
      await prefs.setInt('news_cache_time_$cacheKey', 
          DateTime.now().millisecondsSinceEpoch);
      
      print('💾 Cached ${articles.length} articles');
    } catch (e) {
      print('Error caching news: $e');
    }
  }

  /// Generate cache key
  static String _getCacheKey(String country, List<String> interests) {
    return '${country}_${interests.join('_')}';
  }

  /// Mock news for development/testing
  static List<NewsArticle> _getMockNews() {
    final now = DateTime.now();
    return [
      NewsArticle(
        title: 'AI Breakthrough: New Language Model Achieves Human-Level Understanding',
        description: 'Researchers announce major advancement in artificial intelligence capabilities.',
        source: 'BBC News',
        sourceId: 'bbc-news',
        url: 'https://bbc.com/news/technology',
        imageUrl: 'https://picsum.photos/seed/ai-tech/400/300',
        publishedAt: now.subtract(const Duration(hours: 2)),
        author: 'Tech Reporter',
      ),
      NewsArticle(
        title: 'Global Markets React to Economic Data',
        description: 'Stock markets show volatility amid economic uncertainty.',
        source: 'Bloomberg',
        sourceId: 'bloomberg',
        url: 'https://bloomberg.com/markets',
        imageUrl: 'https://picsum.photos/seed/markets/400/300',
        publishedAt: now.subtract(const Duration(hours: 5)),
        author: 'Finance Team',
      ),
      NewsArticle(
        title: 'Scientists Discover New Earth-Like Planet',
        description: 'Astronomers find potentially habitable exoplanet.',
        source: 'BBC News',
        sourceId: 'bbc-news',
        url: 'https://bbc.com/science',
        imageUrl: 'https://picsum.photos/seed/planet/400/300',
        publishedAt: now.subtract(const Duration(hours: 8)),
        author: 'Science Editor',
      ),
      NewsArticle(
        title: 'Championship Game Breaks Viewership Records',
        description: 'Historic match draws millions of viewers worldwide.',
        source: 'Fox News',
        sourceId: 'fox-news',
        url: 'https://foxnews.com/sports',
        imageUrl: 'https://picsum.photos/seed/sports/400/300',
        publishedAt: now.subtract(const Duration(hours: 12)),
        author: 'Sports Desk',
      ),
      NewsArticle(
        title: 'New Study Links Exercise to Improved Mental Health',
        description: 'Research shows significant benefits for wellbeing.',
        source: 'CNN',
        sourceId: 'cnn',
        url: 'https://cnn.com/health',
        imageUrl: 'https://picsum.photos/seed/health/400/300',
        publishedAt: now.subtract(const Duration(hours: 20)),
        author: 'Health Writer',
      ),
    ];
  }

  /// Available news categories
  static const List<String> categories = [
    'general',
    'business',
    'technology',
    'science',
    'health',
    'sports',
    'entertainment',
  ];
}
