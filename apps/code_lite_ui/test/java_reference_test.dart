import 'package:code_lite_ui/core/lsp/java_reference.dart';
import 'package:flutter_test/flutter_test.dart';

/// IntelliJ 的「复制引用」(⌥⇧⌘C)格式与反向定位(Search Everywhere 里粘贴引用跳过去)。
void main() {
  const src = '''
package com.bcpoker.game.modules.mtt.service.impl;

import com.bcpoker.game.api.dto.mtt.InfoMttDTO;
import java.util.List;
import java.util.Map;

/** 奖励 "class Fake {" 不算 */
@Service
public class RecMttRewardsServiceImpl extends BaseService implements RecMttRewardsService {
    private static final long LIMIT = 10L;
    private List<String> names = compute();

    public RecMttRewardsServiceImpl(int size) {}

    @Override
    public long rewardMttPrize(InfoMttDTO mtt) {
        if (mtt == null) {
            return 0L;
        }
        long mttId = mtt.getId();
        return mttId;
    }

    public long rewardMttPrize(InfoMttDTO mtt, @Param("x") final Map<String, List<Long>> extra, int[] ids, String... more) {
        return 0;
    }

    static class Inner {
        void run(Inner other, Reward r) {}
    }

    enum Kind { CASH, TICKET(2); Kind() {} Kind(int x) {} }
}
''';

  ({int line, int col}) at(String needle, [int nth = 0]) {
    var i = -1;
    for (var k = 0; k <= nth; k++) {
      i = src.indexOf(needle, i + 1);
    }
    final before = src.substring(0, i);
    final line = '\n'.allMatches(before).length;
    return (line: line, col: i - (before.lastIndexOf('\n') + 1));
  }

  String? refAt(String needle, [int nth = 0, int into = 1]) {
    final p = at(needle, nth);
    return javaReferenceAt(src, p.line, p.col + into);
  }

  group('copy reference', () {
    test('a method declaration: class FQN # name (FQN parameter types)', () {
      expect(refAt('rewardMttPrize'), 'com.bcpoker.game.modules.mtt.service.impl.RecMttRewardsServiceImpl#rewardMttPrize(com.bcpoker.game.api.dto.mtt.InfoMttDTO)');
    });

    test('overload: generics erased, annotations / final dropped, arrays and varargs kept, java.lang qualified', () {
      expect(refAt('rewardMttPrize', 1),
          'com.bcpoker.game.modules.mtt.service.impl.RecMttRewardsServiceImpl#rewardMttPrize(com.bcpoker.game.api.dto.mtt.InfoMttDTO, java.util.Map, int[], java.lang.String...)');
    });

    test('class, nested class, constructor, field, enum constant', () {
      const cls = 'com.bcpoker.game.modules.mtt.service.impl.RecMttRewardsServiceImpl';
      expect(refAt('RecMttRewardsServiceImpl extends'), cls);
      expect(refAt('Inner {'), '$cls.Inner');
      expect(refAt('RecMttRewardsServiceImpl(int'), '$cls#RecMttRewardsServiceImpl(int)');
      expect(refAt('LIMIT'), '$cls#LIMIT');
      expect(refAt('names'), '$cls#names');
      expect(refAt('run('), '$cls.Inner#run($cls.Inner, com.bcpoker.game.modules.mtt.service.impl.Reward)');
      expect(refAt('TICKET'), '$cls.Kind#TICKET');
      expect(refAt('CASH'), '$cls.Kind#CASH');
    });

    test('locals, parameters, call sites, keywords and strings have no reference here', () {
      expect(refAt('mttId ='), isNull);
      expect(refAt('mtt) {'), isNull);
      expect(refAt('getId'), isNull);
      expect(refAt('compute'), isNull);
      expect(refAt('return 0L'), isNull);
      expect(refAt('Fake'), isNull);
    });
  });

  group('parse', () {
    test('references are recognised; plain words and file names are not', () {
      final r = parseCodeReference('game.modules.mtt.service.impl.RecMttRewardsServiceImpl#rewardMttPrize(com.bcpoker.game.api.dto.mtt.InfoMttDTO)')!;
      expect(r.className, 'game.modules.mtt.service.impl.RecMttRewardsServiceImpl');
      expect(r.simpleName, 'RecMttRewardsServiceImpl');
      expect(r.member, 'rewardMttPrize');
      expect(r.params, ['com.bcpoker.game.api.dto.mtt.InfoMttDTO']);
      expect(parseCodeReference('com.foo.Bar')!.member, isNull);
      expect(parseCodeReference('Bar#count')!.params, isNull);
      expect(parseCodeReference('Bar#run()')!.params, isEmpty);
      expect(parseCodeReference('a.B#m(java.util.Map, int[])')!.params, ['java.util.Map', 'int[]']);
      expect(parseCodeReference('reward'), isNull);
      expect(parseCodeReference('app.dart'), isNull);
      expect(parseCodeReference('Foo.java'), isNull);
      expect(parseCodeReference('find usages'), isNull);
    });
  });

  group('find', () {
    test('a copied reference leads back to the right overload', () {
      final one = findJavaMember(src, ['RecMttRewardsServiceImpl'], member: 'rewardMttPrize', params: ['com.bcpoker.game.api.dto.mtt.InfoMttDTO']);
      expect(one, at('rewardMttPrize'));
      final two = findJavaMember(src, ['RecMttRewardsServiceImpl'],
          member: 'rewardMttPrize', params: ['com.bcpoker.game.api.dto.mtt.InfoMttDTO', 'java.util.Map', 'int[]', 'java.lang.String...']);
      expect(two, at('rewardMttPrize', 1));
      expect(findJavaMember(src, ['RecMttRewardsServiceImpl'], member: 'rewardMttPrize'), at('rewardMttPrize'), reason: '没给参数:第一个');
      expect(findJavaMember(src, ['RecMttRewardsServiceImpl']), at('RecMttRewardsServiceImpl extends'));
      expect(findJavaMember(src, ['RecMttRewardsServiceImpl', 'Inner'], member: 'run'), at('run('));
      expect(findJavaMember(src, ['RecMttRewardsServiceImpl'], member: 'LIMIT'), at('LIMIT'));
      expect(findJavaMember(src, ['RecMttRewardsServiceImpl'], member: 'nope'), isNull);
      expect(findJavaMember(src, ['Other']), isNull);
    });

    test('round trip: every reference copied from a declaration finds that declaration', () {
      for (final needle in ['rewardMttPrize', 'LIMIT', 'names', 'run(', 'TICKET']) {
        final p = at(needle);
        final ref = parseCodeReference(javaReferenceAt(src, p.line, p.col + 1)!)!;
        final found = findJavaMember(src, ref.className.split('.').skipWhile((s) => s[0].toLowerCase() == s[0]).toList(),
            member: ref.member, params: ref.params);
        expect(found, p, reason: needle);
      }
    });
  });
}
