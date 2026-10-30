/// Language metadata is normalized, never guessed from a title or artist.
const songLanguages = <String>[
  'Hindi',
  'English',
  'Punjabi',
  'Tamil',
  'Telugu',
  'Bengali',
  'Marathi',
  'Gujarati',
  'Kannada',
  'Malayalam',
  'Bhojpuri',
  'Urdu',
  'Haryanvi',
  'Rajasthani',
  'Odia',
  'Assamese',
  'Sanskrit',
  'Korean',
  'Japanese',
  'Spanish',
  'French',
  'Arabic',
  'Portuguese',
  'German',
  'Italian',
];

String normalizeSongLanguage(String value) {
  final key = value.trim().toLowerCase();
  if (key.isEmpty ||
      RegExp(r'[,;/&]').hasMatch(key) ||
      {
        'unknown',
        'und',
        'undefined',
        'null',
        'n/a',
        'any',
        'instrumental',
        'zxx',
        'mul',
        'multiple',
        'multilingual',
      }.contains(key)) {
    return '';
  }
  const aliases = {
    'hi': 'Hindi',
    'hin': 'Hindi',
    'en': 'English',
    'eng': 'English',
    'pa': 'Punjabi',
    'pan': 'Punjabi',
    'punjabi': 'Punjabi',
    'ta': 'Tamil',
    'tam': 'Tamil',
    'te': 'Telugu',
    'tel': 'Telugu',
    'bn': 'Bengali',
    'ben': 'Bengali',
    'bangla': 'Bengali',
    'mr': 'Marathi',
    'mar': 'Marathi',
    'gu': 'Gujarati',
    'guj': 'Gujarati',
    'kn': 'Kannada',
    'kan': 'Kannada',
    'ml': 'Malayalam',
    'mal': 'Malayalam',
    'bho': 'Bhojpuri',
    'ur': 'Urdu',
    'urd': 'Urdu',
    'bgc': 'Haryanvi',
    'raj': 'Rajasthani',
    'or': 'Odia',
    'ori': 'Odia',
    'oriya': 'Odia',
    'as': 'Assamese',
    'asm': 'Assamese',
    'sa': 'Sanskrit',
    'san': 'Sanskrit',
    'ko': 'Korean',
    'kor': 'Korean',
    'ja': 'Japanese',
    'jpn': 'Japanese',
    'es': 'Spanish',
    'spa': 'Spanish',
    'fr': 'French',
    'fra': 'French',
    'ar': 'Arabic',
    'ara': 'Arabic',
    'pt': 'Portuguese',
    'por': 'Portuguese',
    'de': 'German',
    'deu': 'German',
    'it': 'Italian',
    'ita': 'Italian',
  };
  if (aliases.containsKey(key)) return aliases[key]!;
  for (final language in songLanguages) {
    if (language.toLowerCase() == key) return language;
  }
  // Regional codes such as en-US and hi_IN have the same song language.
  final base = key.split(RegExp('[-_]')).first;
  if (aliases.containsKey(base)) return aliases[base]!;
  return '${key[0].toUpperCase()}${key.substring(1)}';
}
