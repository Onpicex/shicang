import Foundation
import Testing
@testable import ShicangCore

/// 公众号「短文」/图片消息：没有 #js_content，正文和元数据都在页面脚本里（下面全是假数据）
@Suite struct WeChatPostTests {
    static let html = #"""
    <html><head><meta property="og:title" content="og 标题"><meta property="og:description" content=""></head><body>
    <script>
    var appmsg = {
      user_name: 'gh_000000000000',
      nick_name: '测试号',
      title: '对象里的标题',
      desc: '',
      content_noencode: '前面那份，不该用',
      author: '',
      sn: 'not-hex',
    };
    var item = {
      item_show_type: '10' * 1,
      picture_page_info_list: [
        { cdn_url: 'https://mmbiz.qpic.cn/sz_mmbiz_jpg/FAKE1/640?wx_fmt=jpeg', width: '1080' * 1 },
        { cdn_url: 'http://mmbiz.qpic.cn/sz_mmbiz_jpg/FAKE2/0?wx_fmt=jpeg', note: 'a ] b' },
      ],
      text_page_info: {
        content: '双重转义 \x26amp;lt;不该用\x26amp;gt;',
        content_noencode: '第一段：今天测试短文解析，看看能不能完整存下来。\x0a\x0a第二段有 \x26lt;名字\x26gt; 和 \x26amp; 符号，\'单引号\' 和反斜杠 \\ 。\x0a第二行 中文 😀',
      },
    };
    window.biz = '' || 'MzAwFAKE==';
    window.item_show_type = '10' || '';
    window.mid = '' || '' || '2650000099';
    window.idx = '' || '' || '2';
    window.sn = '' || '' || '0123456789abcdef0123456789abcdef';
    window.ct = '1700000000' || '';
    window.msg_title = window.title = '短文 \x26lt;标题\x26gt;' || '';
    if (window.nickname === '') { window.x = 1; }
    </script></body></html>
    """#

    @Test func parsesShortPost() throws {
        let t = try Capture.classify("https://mp.weixin.qq.com/s/FakeShortPost1")
        let art = try WeChatExtractor().parse(html: Self.html, raw: Data(Self.html.utf8), target: t).article
        #expect(art.title == "短文 <标题>")
        #expect(art.author == "测试号" && art.authorHandle == "gh_000000000000")
        #expect(art.canonicalId == "wechat:MzAwFAKE==:2650000099:2")
        #expect(art.aliases == ["wechat:s/FakeShortPost1"])
        #expect(art.url.contains("sn=0123456789abcdef0123456789abcdef"))
        #expect(art.publishedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(art.summary == nil)

        let paras = art.blocks.filter { $0.type == .paragraph }.map(\.plainText)
        #expect(paras.count == 2)
        #expect(paras.first == "第一段：今天测试短文解析，看看能不能完整存下来。")
        #expect(paras.last == "第二段有 <名字> 和 & 符号，'单引号' 和反斜杠 \\ 。\n第二行 中文 😀")
        #expect(!art.blocks.contains { $0.plainText.contains("不该用") })
        #expect(art.blocks.compactMap(\.image).map(\.url) == [
            "https://mmbiz.qpic.cn/sz_mmbiz_jpg/FAKE1/0?wx_fmt=jpeg",
            "https://mmbiz.qpic.cn/sz_mmbiz_jpg/FAKE2/0?wx_fmt=jpeg",
        ])
        #expect(art.stats.images == 2)
    }

    @Test func videoPostGetsClearReason() throws {
        let html = Self.html.replacingOccurrences(of: "window.item_show_type = '10'", with: "window.item_show_type = '5'")
        let t = try Capture.classify("https://mp.weixin.qq.com/s/FakeShortPost2")
        #expect { try WeChatExtractor().parse(html: html, raw: Data(), target: t) } throws: { e in
            "\(e)".contains("视频消息") && "\(e)".contains("item_show_type=5")
        }
    }

    @Test func noBodyStillReportsGate() throws {
        let t = try Capture.classify("https://mp.weixin.qq.com/s/FakeShortPost3")
        let deleted = "<html><body><p>该内容已被发布者删除</p></body></html>"
        #expect { try WeChatExtractor().parse(html: deleted, raw: Data(), target: t) } throws: { "\($0)".contains("原文已被发布者删除") }
        let empty = "<html><body><script>window.item_show_type = '8' || '';</script></body></html>"
        #expect { try WeChatExtractor().parse(html: empty, raw: Data(), target: t) } throws: { "\($0)".contains("图片消息") }
    }

    @Test func decoders() {
        #expect(WeChatExtractor.entityDecode("&amp;lt;b&amp;gt; &#39;x&#x27; &lt;&unknown;") == "&lt;b&gt; 'x' <&unknown;")
        #expect(WeChatExtractor.jsUnescape(#"a\x26b\'c\\d\u{1F600}\ne"#) == "a&b'c\\d😀\ne")
        #expect(WeChatExtractor.htmlDecode(#"\x26lt;x\x26gt;"#) == "<x>")
        #expect(WeChatExtractor.windowVar("window.a = '' || \"v\\\"q\";", "a") == "v\"q")
        #expect(WeChatExtractor.windowVar("window.a === 'x'; window.a = '' || '';", "a") == nil)
        #expect(WeChatExtractor.objField("x = c ? 1 : 2; author: '', author: 'b'", "author") == nil)
    }
}
