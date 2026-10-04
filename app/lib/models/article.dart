class Article {
  const Article({
    required this.dictionaryName,
    required this.mdxPath,
    required this.headword,
    required this.html,
  });

  final String dictionaryName;
  final String mdxPath;
  final String headword;
  final String html;
}
