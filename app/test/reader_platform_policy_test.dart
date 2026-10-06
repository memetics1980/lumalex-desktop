import 'package:flutter_test/flutter_test.dart';
import 'package:local_dictionary/platform/reader_platform_policy.dart';

void main() {
  test('Android reader policy favors fast return to recent dictionaries', () {
    final policy = ReaderPlatformPolicy.forOperatingSystem('android');

    expect(policy.maximumRetainedReaders, 3);
    expect(policy.resourceCacheByteLimit, 64 * 1024 * 1024);
    expect(policy.singleCachedResourceByteLimit, 8 * 1024 * 1024);
    expect(policy.revealArticleAfterSetup, isTrue);
    expect(policy.recoverReaderAfterForeground, isFalse);
    expect(policy.keepArticlePlatformViewAlive, isTrue);
    expect(policy.aggregateDictionaryResults, isTrue);
    expect(policy.reuseRetainedReaderSlots, isFalse);
    expect(policy.preloadAdjacentDictionaryReader, isTrue);
    expect(policy.showWideDictionaryJumpRail, isFalse);
    expect(policy.supportsDictionaryGroups, isTrue);
    expect(policy.adaptiveReaderRetention, isTrue);
    expect(policy.memoryPressureRetainedReaders, 1);
    expect(
      policy.retainedReadersForMemory(
        memoryClassMb: 128,
        isLowRamDevice: false,
      ),
      2,
    );
    expect(
      policy.retainedReadersForMemory(
        memoryClassMb: 384,
        isLowRamDevice: false,
      ),
      3,
    );
    expect(
      policy.retainedReadersForMemory(
        memoryClassMb: 512,
        isLowRamDevice: false,
      ),
      5,
    );
    expect(
      policy.retainedReadersForMemory(
        memoryClassMb: 768,
        isLowRamDevice: true,
      ),
      2,
    );
  });

  test('iOS reader policy retains only the explicitly visited recent reader',
      () {
    final policy = ReaderPlatformPolicy.forOperatingSystem('ios');

    expect(policy.maximumRetainedReaders, 2);
    expect(policy.resourceCacheByteLimit, 16 * 1024 * 1024);
    expect(policy.singleCachedResourceByteLimit, 2 * 1024 * 1024);
    expect(policy.revealArticleAfterSetup, isFalse);
    expect(policy.recoverReaderAfterForeground, isTrue);
    expect(policy.keepArticlePlatformViewAlive, isFalse);
    expect(policy.aggregateDictionaryResults, isFalse);
    expect(policy.reuseRetainedReaderSlots, isTrue);
    expect(policy.preloadAdjacentDictionaryReader, isFalse);
    expect(policy.showWideDictionaryJumpRail, isFalse);
    expect(policy.supportsDictionaryGroups, isTrue);
    expect(policy.adaptiveReaderRetention, isFalse);
    expect(policy.memoryPressureRetainedReaders, 1);
    expect(
      policy.retainedReadersForMemory(
        memoryClassMb: 1024,
        isLowRamDevice: false,
      ),
      2,
    );
  });

  test('macOS shares the desktop aggregate reader and navigation', () {
    final policy = ReaderPlatformPolicy.forOperatingSystem('macos');

    expect(policy.maximumRetainedReaders, 3);
    expect(policy.revealArticleAfterSetup, isFalse);
    expect(policy.recoverReaderAfterForeground, isFalse);
    expect(policy.keepArticlePlatformViewAlive, isFalse);
    expect(policy.aggregateDictionaryResults, isTrue);
    expect(policy.reuseRetainedReaderSlots, isFalse);
    expect(policy.preloadAdjacentDictionaryReader, isFalse);
    expect(policy.showWideDictionaryJumpRail, isFalse);
    expect(policy.supportsDictionaryGroups, isTrue);
    expect(policy.adaptiveReaderRetention, isFalse);
  });

  test('Windows enables desktop navigation and dictionary groups', () {
    final policy = ReaderPlatformPolicy.forOperatingSystem('windows');

    expect(policy.resourceCacheByteLimit, 128 * 1024 * 1024);
    expect(policy.singleCachedResourceByteLimit, 16 * 1024 * 1024);
    expect(policy.aggregateDictionaryResults, isTrue);
    expect(policy.preloadAdjacentDictionaryReader, isFalse);
    expect(policy.showWideDictionaryJumpRail, isFalse);
    expect(policy.supportsDictionaryGroups, isTrue);
    expect(policy.revealArticleAfterSetup, isFalse);
    expect(policy.recoverReaderAfterForeground, isFalse);
  });
}
