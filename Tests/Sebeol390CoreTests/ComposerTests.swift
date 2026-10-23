import Testing
@testable import Sebeol390Core

@Test func commonWordsCompose() {
    expect("mfskgw", "한글")
    expect("jfsheamfncj4", "안녕하세요")
    expect("nc;twndx", "세벌식")
    expect("mr2ng3hduf", "했습니다")
    expect("lv1jfj4", "좋아요")
    expect("jd2uf", "있다")
    expect("mr2hgsuc", "했는데")
    expect("mrnt", "해서")
}

@Test func compoundsCompose() {
    expect("kvf", "과")
    expect("j8", "의")
    expect("jgd", "의")
    expect("kkf", "까")
    expect("kf3q", "값")
    expect("kfX", "값")
    expect("kfxq", "갃")
    expect("kfF", "갂")
    expect("hfwq", "낤")
    expect("hfW", "낱")
}

@Test func vowelOrderIsNotReversed() {
    let text = compose("fk")
    #expect(text != "과")
    #expect(text.contains("ㅏ"))
}

@Test func symbolBreaksSyllable() {
    #expect(compose("kf.") == "가.")
}

@Test func shorterPrefixDropsLastJamo() {
    #expect(compose(String("kkf".dropLast())) == "ㄲ")
    #expect(compose(String("kf".dropLast())) == "ㄱ")
}

private func expect(_ keys: String, _ word: String) {
    #expect(compose(keys) == word, "\(keys)")
}

private func compose(_ keys: String) -> String {
    Composer.compose(keys.map { Layout390.atom(for: $0) }).text
}
